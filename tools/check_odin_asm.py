"""Check ARM64 call diagnostics with the actual Odin compiler."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CASES = {
    'conditional_call': ('''package probe
invoke :: asm(f: rawptr) [f = %x19, #clobber %x30, #volatile] {
 cbz f, .done;
 blr f;
.done:
 nop;
}
''', None),
    'sequential_calls': ('''package probe
invoke :: asm(f: rawptr) [f = %x19, #clobber %x30, #volatile] {
 blr f;
 blr f;
}
''', None),
    'output_after_call': ('''package probe
invoke :: asm(f: rawptr) -> (r: u64) [f = %x19, #clobber %x30, #volatile] {
 blr f;
 mov r, 1;
}
''', None),
    'authenticated_calls': ('''package probe
@(enable_target_feature="pauth")
invoke :: asm(f: rawptr) [f = %x19, #clobber %x30, #volatile] {
 blraaz f;
 blrabz f;
}
''', None),
    'direct_call': ('''package probe
invoke :: asm() [#clobber %x30, #volatile] {
 bl .callee;
 b .done;
.callee:
 ret;
.done:
 nop;
}
''', None),
    'dead_write_after_call': ('''package probe
invoke :: asm(f: rawptr, n: u64) [f = %x19, n = %x20, #clobber %x30, #volatile] {
 blr f;
 mov %x30, n;
 mov %x30, n;
}
''', 'never read before being overwritten'),
    'dead_link_write': ('''package probe
unused :: asm(n: u64) [n = %x0, #clobber %x30] {
 mov %x30, n;
 mov %x30, n;
}
''', 'never read before being overwritten'),
    'tail_branch_does_not_return': ('''package probe
jump :: asm(f: rawptr) [f = %x19, #volatile] {
 br f;
}
''', 'no reachable path'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, required=True)
    parser.add_argument('--library-root', type=Path, required=True)
    parser.add_argument('--target', default='darwin_arm64')
    args = parser.parse_args()
    environment = os.environ.copy()
    environment['ODIN_ROOT'] = str(args.library_root.resolve())
    failures = []
    with tempfile.TemporaryDirectory(prefix='shoji-asm-check-') as directory:
        for name, (source, diagnostic) in CASES.items():
            path = Path(directory) / name
            path.mkdir()
            (path / 'probe.odin').write_text(source)
            result = subprocess.run([str(args.compiler.resolve()), 'check', str(path),
                                     '-no-entry-point', '-warnings-as-errors',
                                     '-target:' + args.target],
                                    env=environment, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            passed = result.returncode == 0 if diagnostic is None else result.returncode != 0 and diagnostic in output
            if not passed:
                failures.append(name)
                print(f'FAIL {name}:\n{output}')
            else:
                print('PASS', name)
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
