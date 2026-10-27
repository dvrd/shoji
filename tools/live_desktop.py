"""Validate Shoji against disposable windows with other window managers stopped."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if os.geteuid() == 0:
        parser.error('run from your desktop terminal as your normal user')
    evidence = Path(tempfile.mkdtemp(prefix='shoji-desktop-'))
    binary = ROOT / 'bin/shoji'
    helper = ROOT / 'bin/shoji-live-animation'
    children = []
    streams = []
    results = []
    token = evidence.name
    outcome = 1
    report = {'status': 'running', 'fixture_pid': None,
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else None,
              'dock_restart': False, 'mouse_event_tap': False}

    def command(arguments, timeout=15):
        result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, timeout=timeout)
        results.append({'command': list(map(str, arguments)), 'exit_code': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode != 0:
            raise RuntimeError(f'command failed: {arguments!r}: {result.stderr or result.stdout}')
        return result.stdout

    def client(*arguments):
        return command([binary, '-m', *map(str, arguments)])

    def wait_for(predicate, description):
        began = time.monotonic()
        while time.monotonic() - began < 8:
            if predicate():
                return
            if children[-1].poll() is not None:
                raise RuntimeError('validation daemon exited; see daemon.stderr')
            time.sleep(.1)
        raise RuntimeError(f'timed out waiting for {description}')

    def windows():
        data = json.loads(client('query', '--windows'))
        if any(window['pid'] != fixture.pid for window in data):
            raise RuntimeError('validation daemon observed an application outside the fixture')
        return {window['id']: window for window in data}

    def frames_match():
        observed = windows()
        for window_id, window in observed.items():
            actual = json.loads(command([helper, 'frame', window_id]))
            if any(abs(actual[key] - window['frame'][key]) > 3 for key in ('x', 'y', 'w', 'h')):
                return False
        return True

    def start(arguments, name, pipe=False):
        out = subprocess.PIPE if pipe else (evidence / f'{name}.stdout').open('w')
        err = (evidence / f'{name}.stderr').open('w')
        streams.append(err)
        if not pipe:
            streams.append(out)
        child = subprocess.Popen(list(map(str, arguments)), stdout=out, stderr=err, text=True)
        children.append(child)
        return child

    try:
        # Refuse to replace an existing Shoji daemon or interfere with its socket.
        existing = subprocess.run([str(binary), '-m', 'query', '--windows'], capture_output=True, timeout=10)
        if existing.returncode == 0:
            raise RuntimeError('a Shoji daemon is already running; stop this validation attempt')
        command([binary, '--inspect'])
        compiler = ROOT / '.toolchain/Odin/odin'
        compiler = os.environ.get('ODIN') or (str(compiler) if compiler.is_file() else 'odin')
        environment = os.environ.copy()
        if (ROOT / '.toolchain/Odin/core').is_dir():
            environment['ODIN_ROOT'] = str(ROOT / '.toolchain/Odin')
        subprocess.run([compiler, 'build', str(ROOT / 'tools/live-animation'), f'-out:{helper}',
                        '-extra-linker-flags:-F/System/Library/PrivateFrameworks'], env=environment, check=True, timeout=120)
        fixture = start([helper, 'desktop', token], 'fixture', pipe=True)
        report['fixture_pid'] = fixture.pid
        if not select.select([fixture.stdout], [], [], 8)[0]:
            raise RuntimeError('fixture startup timed out')
        line = fixture.stdout.readline()
        (evidence / 'fixture.stdout').write_text(line)
        owned = json.loads(line)
        if owned['pid'] != fixture.pid or len(owned['windows']) != 2 or not all(owned['windows']):
            raise RuntimeError('fixture did not identify two owned windows')
        first, second = owned['windows']
        config = evidence / 'shojirc'
        config.write_text('# Empty configuration: all commands are scoped by --validation-pid.\n')
        daemon = start([binary, '-c', config, '--validation-pid', fixture.pid], 'daemon')

        def ready():
            response = subprocess.run([str(binary), '-m', 'query', '--windows'], capture_output=True, text=True, timeout=5)
            return response.returncode == 0 and {window['id'] for window in json.loads(response.stdout)} == {first, second}

        wait_for(ready, 'owned windows to be discovered')
        client('config', 'window_animation_duration', '0')
        client('config', 'mouse_follows_focus', 'off')
        client('config', 'layout', 'bsp')
        wait_for(lambda: all(window['frame']['w'] > 20 and window['frame']['h'] > 20 for window in windows().values()), 'BSP frames')
        wait_for(frames_match, 'WindowServer to confirm BSP frames')
        client('window', first, '--focus')
        wait_for(lambda: windows()[first]['has-focus'], 'owned window focus')
        client('window', first, '--swap', second)
        fixture_space = windows()[first]['space']
        client('space', fixture_space, '--rotate', '90')
        client('space', fixture_space, '--balance')
        client('window', first, '--toggle', 'float', '--grid', '4:4:1:1:2:2')
        wait_for(lambda: windows()[first]['is-floating'], 'chained float/grid')
        wait_for(frames_match, 'WindowServer to confirm float/grid frames')
        client('window', first, '--resize', 'right:20:0')
        client('window', first, '--minimize')
        wait_for(lambda: windows()[first]['is-minimized'], 'minimize observation')
        client('window', first, '--deminimize')
        wait_for(lambda: not windows()[first]['is-minimized'], 'restore observation')
        client('window', first, '--toggle', 'float')
        client('config', 'layout', 'stack')
        client('config', 'layout', 'bsp')
        client('window', second, '--close')
        def closed():
            window = windows().get(second)
            return window is None or (not window['is-visible'] and not window['is-minimized'])
        wait_for(closed, 'closed window to become invisible')
        # AppKit may retain an ordered-out NSWindow after close. Process exit is
        # the unambiguous destruction boundary for this deliberately retained fixture.
        fixture.terminate()
        fixture.wait(timeout=5)
        wait_for(lambda: not windows(), 'fixture destruction to remove all references')
        print('PASS: owned-window tiling, focus, swap, transforms, float/grid, resize, minimize/restore, stack and close', flush=True)
        report['status'] = 'passed'
        outcome = 0
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('Desktop validation did not pass:', error, flush=True)
        report['status'] = 'failed'
        report['error'] = str(error)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()
        (evidence / 'commands.json').write_text(json.dumps(results, indent=2) + '\n')
        (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence:', evidence, flush=True)
    return outcome


if __name__ == '__main__':
    raise SystemExit(main())
