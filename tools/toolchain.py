"""Extract the pinned Odin libraries without changing the shared Odin checkout."""
import argparse
import io
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile

REVISION = "37d8ab08f"
ROOT = Path(__file__).resolve().parent.parent


def prepare(source, destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError(f"Refusing to overwrite {destination}")
    archive = subprocess.check_output(["git", "-C", str(source), "archive", REVISION])
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix="odin-") as temporary:
        with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
            stream.extractall(temporary, filter="data")
        Path(temporary).rename(destination)


def patch_compiler(source):
    """Apply the local compiler fix, accepting only an exact prior application."""
    source = Path(source)
    patch = ROOT / 'tools/odin-asm-calls.patch'
    files = ('src/check_asm.cpp', 'src/check_asm_cfg.cpp')
    # git apply interprets paths relative to a containing worktree. Stage just
    # the affected files outside that worktree so ignored toolchains work too.
    with tempfile.TemporaryDirectory(prefix='shoji-odin-patch-') as directory:
        stage = Path(directory)
        (stage / 'src').mkdir()
        for name in files:
            shutil.copy2(source / name, stage / name)
        command = ['git', 'apply']
        check = subprocess.run(command + ['--check', str(patch)], cwd=stage,
                               capture_output=True, text=True)
        if check.returncode:
            reverse = subprocess.run(command + ['--reverse', '--check', str(patch)],
                                     cwd=stage, capture_output=True, text=True)
            if reverse.returncode:
                raise ValueError(f'Cannot apply Odin assembly-call fix: {check.stderr}')
            return
        subprocess.run(command + [str(patch)], cwd=stage, check=True)
        for name in files:
            shutil.copy2(stage / name, source / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="local Odin Git checkout containing the pinned revision")
    parser.add_argument("--build-compiler", action="store_true", help="also build a matching compiler inside the isolated checkout")
    parser.add_argument("--patch-only", action="store_true", help="apply the compiler fix to the existing isolated checkout")
    args = parser.parse_args()
    destination = ROOT / ".toolchain/Odin"
    try:
        if not (args.patch_only or (args.build_compiler and destination.is_dir())):
            source = args.source or Path(subprocess.check_output(["odin", "root"], text=True).strip())
            prepare(source, destination)
        patch_compiler(destination)
        if args.build_compiler:
            import os
            environment = os.environ.copy()
            environment["CPPFLAGS"] = environment.get("CPPFLAGS", "") + f' -DGIT_SHA="{REVISION}"'
            subprocess.run(["sh", "build_odin.sh", "release"], cwd=destination, env=environment, check=True)
    except (ValueError, subprocess.SubprocessError, OSError) as error:
        parser.exit(1, f"{error}\n")
    print(f"Pinned toolchain ready at {destination} ({REVISION})")


if __name__ == "__main__":
    main()
