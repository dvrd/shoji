"""Build the loader-only Odin compiler in isolation, preserving the source checkout."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from toolchain import patch_compiler

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Odin source checkout (e.g. odin root)")
args = parser.parse_args()
source = args.source.resolve()
project = Path(__file__).resolve().parent.parent
patch = project / "tools/odin-arm64e.patch"
output = project / "bin/odin-arm64e"

for name in ("src", "base", "core", "vendor", "build_odin.sh"):
    if not (source / name).exists():
        raise SystemExit(f"Missing {source / name}")

with tempfile.TemporaryDirectory(prefix="shoji-odin-arm64e-") as directory:
    build = Path(directory)
    shutil.copytree(source / "src", build / "src")
    shutil.copy2(source / "build_odin.sh", build)
    for name in ("base", "core", "vendor"):
        (build / name).symlink_to(source / name, target_is_directory=True)

    # The local checkout may already contain the target/linker part of the patch.
    # Accept exact prior application, and fail on any other conflicting changes.
    for name in ("build_settings.cpp", "linker.cpp", "llvm_backend_general.cpp", "llvm_backend.cpp"):
        command = ["git", "apply", f"--include=src/{name}"]
        check = subprocess.run(command + ["--check", str(patch)], cwd=build,
                               capture_output=True, text=True)
        if check.returncode == 0:
            subprocess.run(command + [str(patch)], cwd=build, check=True)
        else:
            reverse = subprocess.run(command + ["--reverse", "--check", str(patch)],
                                     cwd=build, capture_output=True, text=True)
            if reverse.returncode != 0:
                raise SystemExit(f"Cannot apply arm64e patch to {name}:\n{check.stderr}")

    patch_compiler(build)
    subprocess.run(["sh", "build_odin.sh", "release"], cwd=build, check=True,
                   env=os.environ.copy())
    output.parent.mkdir(exist_ok=True)
    shutil.copy2(build / "odin", output)

print(f"Built {output}; use ODIN_ROOT={source} when invoking it directly.")
