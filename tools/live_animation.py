"""Live crash-recovery test using disposable owned windows; never targets user windows."""
import argparse
import json
import math
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def restart_and_load_payload(binary, payload):
    # Check the exact sudo command before interrupting the user's Dock.
    subprocess.run(['sudo', '-n', '-l', '--', str(binary), '--load-sa', str(payload)],
                   check=True, timeout=15)
    target = f'gui/{os.getuid()}/com.apple.Dock.agent'
    subprocess.run(['/bin/launchctl', 'print', target], check=True, capture_output=True, text=True, timeout=10)

    def dock_pids():
        output = subprocess.check_output(['/bin/ps', '-axo', 'pid,uid,comm'], text=True, timeout=10)
        return {int(parts[0]) for line in output.splitlines()
                if len(parts := line.split(None, 2)) == 3 and parts[1].isdigit()
                and int(parts[1]) == os.getuid() and parts[2].endswith('/Dock.app/Contents/MacOS/Dock')}

    before = dock_pids()
    if len(before) != 1:
        raise RuntimeError('cannot identify your unique Dock process')
    # launchd owns the restart. A successful SIGTERM exit does not necessarily
    # satisfy Dock's KeepAlive conditions on the target macOS release.
    try:
        subprocess.run(['/bin/launchctl', 'kickstart', '-k', target], check=True,
                       capture_output=True, text=True, timeout=15)
        began = time.monotonic()
        while time.monotonic() - began < 15:
            current = dock_pids()
            if len(current) == 1 and not current & before:
                break
            time.sleep(.1)
        else:
            raise RuntimeError(f'Dock restart was not observed; recovery: launchctl kickstart {target}')
    except (RuntimeError, subprocess.SubprocessError, OSError):
        # Leave the launchd job requested to run even if validation cannot proceed.
        # Never reload the payload on this failure path.
        try:
            subprocess.run(['/bin/launchctl', 'kickstart', target], check=False,
                           capture_output=True, text=True, timeout=15)
        except (subprocess.SubprocessError, OSError):
            pass
        raise
    subprocess.run(['sudo', '-n', str(binary), '--load-sa', str(payload)], check=True, timeout=30)
    subprocess.run([str(binary), '--check-sa'], check=True, timeout=15)


def parse_alpha_output(output, window):
    try:
        observation = json.loads(output)
        if not isinstance(observation, dict) or observation.get('window') != window:
            raise ValueError('observation does not identify the requested window')
        value = observation['query_alpha']
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
            raise ValueError('query_alpha must be a finite number between 0 and 1')
        return value
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError(f'invalid alpha observation for window {window}: {error}; stdout={output!r}') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reload-payload', action='store_true',
                        help='restart Dock and load the rebuilt payload before creating test windows')
    parser.add_argument('--dock-restart', action='store_true',
                        help='also restart your Dock, reload the payload through sudo, and replay the journal')
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('run as your desktop user, without sudo')
    helper = ROOT / 'bin/shoji-live-animation'
    binary = ROOT / 'bin/shoji'
    payload = ROOT / 'bin/shoji-sa.dylib'
    try:
        if args.reload_payload:
            restart_and_load_payload(binary, payload)
        subprocess.run([str(binary), '--check-sa'], check=True, timeout=15)
        environment = os.environ.copy()
        pinned_compiler = ROOT / '.toolchain/Odin/odin'
        compiler = os.environ.get('ODIN') or (str(pinned_compiler) if pinned_compiler.is_file() else 'odin')
        if (ROOT / '.toolchain/Odin/core').is_dir():
            environment['ODIN_ROOT'] = str(ROOT / '.toolchain/Odin')
        subprocess.run([compiler, 'build', str(ROOT / 'tools/live-animation'),
                        f'-out:{helper}', '-extra-linker-flags:-F/System/Library/PrivateFrameworks'],
                       check=True, env=environment, timeout=120)
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        print('Live test preflight did not pass:', error, flush=True)
        return 1
    evidence = Path(tempfile.mkdtemp(prefix='shoji-live-crash-', dir='/tmp'))
    children = []

    def start(*arguments):
        child = subprocess.Popen([str(helper), *map(str, arguments)], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        children.append(child)
        if not select.select([child.stdout], [], [], 8)[0]:
            raise RuntimeError('fixture startup timed out')
        line = child.stdout.readline().strip()
        (evidence / f'fixture-{child.pid}.stdout').write_text(line + '\n')
        if not line.isdigit() or int(line) == 0:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            diagnostic = child.stderr.read()
            (evidence / f'fixture-{child.pid}.stderr').write_text(diagnostic)
            raise RuntimeError('fixture could not create an owned window: ' + diagnostic)
        return child, int(line)

    def alpha(window):
        result = subprocess.run([str(helper), 'query', str(window)],
                                capture_output=True, text=True, timeout=15)
        sample = evidence / f'query-{window}-{time.monotonic_ns()}'
        sample.with_suffix('.stdout').write_text(result.stdout)
        sample.with_suffix('.stderr').write_text(result.stderr)
        if result.returncode != 0:
            raise RuntimeError(f'alpha query failed ({result.returncode}); stderr={result.stderr!r}; evidence={sample}')
        return parse_alpha_output(result.stdout, window)

    def replay(journal, window):
        subprocess.run([str(helper), 'recover', str(journal)], check=True)
        if alpha(window) < .99 or json.loads(journal.read_text())['entries']:
            raise RuntimeError('journal restoration was not confirmed')

    window = None
    try:
        real, window = start('real')
        if alpha(window) < .99:
            raise RuntimeError('test window baseline alpha is not 1')
        journal = evidence / 'watchdog.json'
        proxy, _ = start('proxy', window, journal)
        if alpha(window) > .01:
            raise RuntimeError('test did not prove that the real window was hidden')
        proxy.kill()
        proxy.wait(timeout=5)
        began = time.monotonic()
        while alpha(window) < .99 and time.monotonic() - began < 5:
            time.sleep(.05)
        if alpha(window) < .99:
            raise RuntimeError('payload watchdog did not restore the real window')
        print(f'PASS: proxy SIGKILL restoration in {time.monotonic() - began:.3f}s', flush=True)
        replay(journal, window)
        journal = evidence / 'replay.json'
        proxy, _ = start('proxy', window, journal)
        if alpha(window) > .01:
            raise RuntimeError('test did not prove the second hide')
        replay(journal, window)
        proxy.terminate()
        proxy.wait(timeout=5)
        print('PASS: fresh-process journal replay against real WindowServer', flush=True)
        if args.dock_restart:
            journal = evidence / 'dock.json'
            proxy, _ = start('proxy', window, journal)
            if alpha(window) > .01:
                raise RuntimeError('test did not prove the Dock-restart hide')

            # This case verifies journal recovery after loss of payload state.
            # It does not certify the daemon's automatic sudo reload policy.
            restart_and_load_payload(binary, payload)
            replay(journal, window)
            print('PASS: journal recovery after real Dock restart and payload reload', flush=True)
        print('Evidence:', evidence, flush=True)
        return 0
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        print('Live test did not pass:', error, flush=True)
        if window is not None:
            try:
                print('Owned real-window alpha after failure:', alpha(window), flush=True)
            except (RuntimeError, subprocess.SubprocessError, OSError) as diagnostic:
                print('Could not observe owned window after failure:', diagnostic, flush=True)
        print('Evidence:', evidence, flush=True)
        return 1
    finally:
        # All child windows are test fixtures. Closing their owning processes
        # removes them even when a hide/restore or permission check failed.
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == '__main__':
    raise SystemExit(main())
