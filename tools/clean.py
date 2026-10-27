"""Remove rebuildable outputs while preserving Shoji's installed runtime."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent
KEEP = {"shoji", "shoji-loader", "shoji-sa.dylib", "odin-arm64e"}
PROBES = {"ShojiAlphaProbe.app", "ShojiScrollProbe.app"}
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
         b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def outputs(root=ROOT):
    directory = root / "bin"
    if directory.is_symlink():
        raise ValueError("refusing to clean a symlinked bin directory")
    if not directory.exists():
        return []
    found = []
    for path in sorted(directory.iterdir()):
        if path.name in KEEP:
            continue
        if path.is_symlink():
            continue
        if path.is_dir():
            if path.name.endswith(".dSYM") or path.name in PROBES or path.name == "raven":
                found.append(path)
        elif path.is_file():
            with path.open("rb") as stream:
                header = stream.read(8)
            if (path.name.startswith("shoji-") and header[:4] in MACHO or
                    path.name == "libshoji-raven.a" and header == b"!<arch>\n"):
                found.append(path)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="list outputs without removing them")
    args = parser.parse_args()
    paths = outputs()
    for path in paths:
        print(f'{"Would remove" if args.dry_run else "Removing"}: {path.relative_to(ROOT)}')
        if not args.dry_run:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    print(f'{"Found" if args.dry_run else "Removed"} {len(paths)} rebuildable outputs; installed runtime and artifacts preserved.')


if __name__ == "__main__":
    main()
