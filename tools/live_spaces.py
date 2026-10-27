"""Validate payload Space creation/focus/destruction using an explicitly identified disposable Space."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def restore_and_destroy(created, original, protected, command, snapshot):
    if created in protected or created == original or created <= 0:
        raise RuntimeError('refusing to destroy a Space that existed before this test')
    current = {space['id'] for space in snapshot()['spaces']}
    if created not in current:
        return
    if original not in current:
        raise RuntimeError('original Space disappeared; refusing automatic cleanup')
    command('space-focus', original)
    command('space-destroy', created)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--load-payload', action='store_true', help='load the built payload through the existing noninteractive sudo rule; does not restart Dock')
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('run as your desktop user without sudo')
    evidence = Path(tempfile.mkdtemp(prefix='shoji-spaces-'))
    binary, helper = ROOT / 'bin/shoji', ROOT / 'bin/shoji-live-animation'
    commands = []
    report = {'status': 'running', 'dock_restart': False}
    created = None
    original = None
    protected = set()
    outcome = 1

    def run(arguments):
        result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, timeout=30)
        commands.append({'command': list(map(str, arguments)), 'exit_code': result.returncode,
                         'stdout': result.stdout, 'stderr': result.stderr})
        if result.returncode != 0:
            raise RuntimeError(result.stderr or result.stdout or f'command failed: {arguments}')
        return result.stdout.strip()

    def command(*arguments):
        return run([helper, *arguments])

    def snapshot():
        return json.loads(command('spaces'))

    def wait_for(predicate, description):
        began = time.monotonic()
        while time.monotonic() - began < 8:
            current = snapshot()
            if predicate(current):
                return current
            time.sleep(.1)
        raise RuntimeError(f'timed out waiting for {description}')

    try:
        compiler = ROOT / '.toolchain/Odin/odin'
        compiler = os.environ.get('ODIN') or (str(compiler) if compiler.is_file() else 'odin')
        environment = os.environ.copy()
        if (ROOT / '.toolchain/Odin/core').is_dir():
            environment['ODIN_ROOT'] = str(ROOT / '.toolchain/Odin')
        subprocess.run([compiler, 'build', str(ROOT / 'tools/live-animation'), f'-out:{helper}',
                        '-extra-linker-flags:-F/System/Library/PrivateFrameworks'], env=environment, check=True, timeout=120)
        if args.load_payload:
            run(['sudo', '-n', binary, '--load-sa', ROOT / 'bin/shoji-sa.dylib'])
        run([binary, '--check-sa'])
        before = snapshot()
        report['before'] = before
        protected = {space['id'] for space in before['spaces']}
        focused = [space for space in before['spaces'] if space['has-focus']]
        if len(focused) != 1 or focused[0]['is-native-fullscreen']:
            raise RuntimeError('start this test on a regular desktop Space')
        original = focused[0]['id']
        fresh = int(command('space-create-tracked', original))
        if fresh <= 0 or fresh in protected:
            raise RuntimeError('payload did not identify a new disposable Space; refusing to select a cleanup target')
        created = fresh
        report['created_space'] = created
        wait_for(lambda state: created in {space['id'] for space in state['spaces']}, 'the tracked Space to appear')
        command('space-focus', created)
        wait_for(lambda state: any(space['id'] == created and space['is-visible'] for space in state['spaces']), 'the disposable Space to become visible')
        restore_and_destroy(created, original, protected, command, snapshot)
        after = wait_for(lambda state: created not in {space['id'] for space in state['spaces']}, 'disposable Space removal')
        created = None
        report['after'] = after
        if not protected.issubset({space['id'] for space in after['spaces']}):
            raise RuntimeError('a pre-existing Space disappeared during validation')
        if not any(space['id'] == original and space['is-visible'] for space in after['spaces']):
            raise RuntimeError('the original Space was not restored')
        print('PASS: tracked Space creation, focus, return to original Space and disposable Space destruction', flush=True)
        report['status'] = 'passed'
        outcome = 0
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report.update(status='failed', error=str(error))
        print('Space validation did not pass:', error, flush=True)
    finally:
        if created is not None:
            try:
                restore_and_destroy(created, original, protected, command, snapshot)
            except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                report.update(status='cleanup-failed', cleanup_error=str(error))
                print(f'Disposable Space {created} needs cleanup: {error}', flush=True)
                outcome = 1
        (evidence / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence:', evidence, flush=True)
    return outcome


if __name__ == '__main__':
    raise SystemExit(main())
