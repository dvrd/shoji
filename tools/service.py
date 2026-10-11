"""Manage the per-user Shoji launchd service; all changes require an explicit command."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LABEL = "tech.shoji.window-manager"


def configuration(binary, log_directory, config=None):
    binary = Path(binary).resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"not an executable: {binary}")
    arguments = [str(binary)]
    if config is not None:
        config = Path(config).resolve(strict=True)
        if not config.is_file():
            raise ValueError(f"not a configuration file: {config}")
        arguments.extend(["-c", str(config)])
    logs = Path(log_directory).resolve()
    return {
        "Label": LABEL,
        "ProgramArguments": arguments,
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "shoji.out.log"),
        "StandardErrorPath": str(logs / "shoji.err.log"),
    }


class Service:
    def __init__(self, home, uid, runner=subprocess.run):
        self.home = Path(home)
        self.plist = self.home / "Library/LaunchAgents" / f"{LABEL}.plist"
        self.logs = self.home / "Library/Logs/shoji"
        self.domain = f"gui/{uid}"
        self.target = f"{self.domain}/{LABEL}"
        self.runner = runner

    def launchctl(self, *args, check=True):
        return self.runner(["/bin/launchctl", *args], check=check,
                           capture_output=True, text=True)

    def loaded(self):
        return self.launchctl("print", self.target, check=False).returncode == 0

    def install(self, binary, config=None):
        data = plistlib.dumps(configuration(binary, self.logs, config))
        if self.loaded():
            raise ValueError("stop the loaded service before replacing its configuration")
        if self.plist.is_symlink():
            raise ValueError(f"refusing to replace symlink: {self.plist}")
        if self.plist.exists():
            existing = plistlib.loads(self.plist.read_bytes())
            if existing.get("Label") != LABEL:
                raise ValueError("existing plist belongs to another service")
        self.plist.parent.mkdir(parents=True, exist_ok=True)
        self.logs.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=self.plist.parent, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
                temporary.chmod(0o600)
                os.replace(temporary, self.plist)
            finally:
                temporary.unlink(missing_ok=True)

    def start(self):
        if not self.plist.is_file():
            raise ValueError("install the service first")
        if self.plist.is_symlink() or plistlib.loads(self.plist.read_bytes()).get("Label") != LABEL:
            raise ValueError("refusing to start a symlink or another service's plist")
        if not self.loaded():
            self.launchctl("enable", self.target)
            self.launchctl("bootstrap", self.domain, str(self.plist))

    def stop(self):
        if self.loaded():
            self.launchctl("bootout", self.target)

    def restart(self):
        self.start()
        self.launchctl("kickstart", "-k", self.target)

    def uninstall(self):
        if self.plist.is_symlink():
            raise ValueError("refusing to remove a symlink")
        if self.plist.exists() and plistlib.loads(self.plist.read_bytes()).get("Label") != LABEL:
            raise ValueError("existing plist belongs to another service")
        self.stop()
        self.plist.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plist", "install", "start", "stop", "restart", "status", "uninstall"])
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parent.parent / "bin/shoji")
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("run as your desktop user, not root")
    service = Service(Path.home(), os.getuid())
    try:
        if args.command == "plist":
            sys.stdout.buffer.write(plistlib.dumps(configuration(args.binary, service.logs, args.config)))
        elif args.command == "install":
            service.install(args.binary, args.config)
            print(f"Installed {service.plist}; use start to launch it")
        elif args.command == "status":
            result = service.launchctl("print", service.target, check=False)
            print(result.stdout or result.stderr, end="")
            return result.returncode
        else:
            getattr(service, args.command)()
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"shoji service: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
