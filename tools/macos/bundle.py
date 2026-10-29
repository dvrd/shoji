#!/usr/bin/env python3
"""Package the existing signed runtime as a macOS background application."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = "tech.shoji.window-manager"


def run(*args):
    subprocess.run(args, check=True)


def main():
    binary = ROOT / "bin/shoji"
    icon = ROOT / "assets/macos/Shoji.icns"
    if not binary.is_file() or not icon.is_file():
        raise SystemExit("Build bin/shoji and generate assets/macos/Shoji.icns first")
    adhoc = os.environ.get("SHOJI_ADHOC_SIGNING") == "1"
    signing = ["--sign", "-"]
    if not adhoc:
        config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        config = json.loads((config_home / "shoji/signing.json").read_text())
        identity = config["identity"]
        signing = ["--sign", identity, "--keychain", config["keychain"],
                   "--requirements", f'=designated => identifier "{IDENTIFIER}" and certificate leaf = H"{identity}"']
    destination = ROOT / "bin/Shoji.app"
    if destination.is_symlink():
        raise SystemExit("Refusing to replace a symlinked app bundle")
    with tempfile.TemporaryDirectory(prefix="shoji-app-", dir=ROOT / "bin") as stage:
        app = Path(stage) / "Shoji.app"
        contents = app / "Contents"
        executable_dir = contents / "MacOS"
        resources = contents / "Resources"
        executable_dir.mkdir(parents=True)
        resources.mkdir()
        for name in ("shoji", "shoji-loader"):
            source = ROOT / "bin" / name
            if source.is_file():
                shutil.copy2(source, executable_dir / name)
        shutil.copy2(icon, resources / "Shoji.icns")
        info = dict(CFBundleIdentifier=IDENTIFIER, CFBundleName="Shoji",
                    CFBundleDisplayName="Shoji", CFBundleExecutable="shoji",
                    CFBundlePackageType="APPL", CFBundleIconFile="Shoji.icns",
                    CFBundleVersion="1", CFBundleShortVersionString="0.1.0",
                    LSMinimumSystemVersion="15.0", LSUIElement=True,
                    NSHighResolutionCapable=True)
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        run("/usr/bin/codesign", "--force", *signing, "--identifier", IDENTIFIER,
            "--timestamp=none", str(app))
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", str(app))
        # Verify the candidate before replacing the previously packaged app.
        if destination.exists():
            shutil.rmtree(destination)
        app.rename(destination)
    run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", str(destination))
    print(destination)


if __name__ == "__main__":
    main()
