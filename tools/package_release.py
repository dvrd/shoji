"""Create a relocatable Shoji release with a checksum manifest."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import tarfile
import tempfile


def package(project, binaries, output, version):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
        raise ValueError("version must contain only letters, numbers, dots, hyphens, and underscores")
    project, binaries, output = Path(project), Path(binaries), Path(output)
    required = [binaries / name for name in ("shoji", "shoji-loader", "shoji-sa.dylib")]
    required += [project / name for name in ("README.md", "PORTING.md", "VALIDATION.md", "SETUP.md", "LICENSE", "tools/service.py", "tools/signing.py")]
    for source in required:
        if not source.is_file():
            raise ValueError(f"missing release input: {source}")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"shoji-{version}-macos.tar.gz"
    if archive.exists():
        raise ValueError(f"release already exists: {archive}")
    with tempfile.TemporaryDirectory(prefix="shoji-release-") as directory:
        stage = Path(directory) / f"shoji-{version}"
        (stage / "bin").mkdir(parents=True)
        (stage / "tools").mkdir()
        for source in required:
            target = stage / ("bin" if source.parent == binaries else "tools" if source.parent == project / "tools" else "") / source.name
            shutil.copy2(source, target)
        manifest = []
        for source in sorted(stage.rglob("*")):
            if source.is_file():
                manifest.append(f"{hashlib.sha256(source.read_bytes()).hexdigest()}  {source.relative_to(stage)}\n")
        (stage / "SHA256SUMS").write_text("".join(manifest))
        with tarfile.open(archive, "x:gz") as stream:
            stream.add(stage, arcname=stage.name)
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--binaries", type=Path, default=Path("bin/universal"))
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        print(package(Path(__file__).resolve().parent.parent, args.binaries, args.output, args.version))
    except (OSError, ValueError) as error:
        parser.exit(1, f"package: {error}\n")


if __name__ == "__main__":
    main()
