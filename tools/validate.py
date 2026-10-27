"""Record build/test evidence and desktop prerequisites for the local validation target."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGET = {"version": "15.6", "build": "24G84", "architecture": "arm64"}


def execute(arguments, directory, name, env=None, timeout=300):
    log = directory / f"{name}.log"
    try:
        with log.open("w") as output:
            process = subprocess.run(arguments, cwd=ROOT, env=env, stdout=output,
                                     stderr=subprocess.STDOUT, timeout=timeout)
        code = process.returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        with log.open("a") as output:
            output.write(f"\n{error}\n")
        code = -1
    return {"command": list(map(str, arguments)), "exit_code": code,
            "status": "pass" if code == 0 else "fail", "log": str(log)}


def summarize(checks, desktop, live):
    if any(check["status"] != "pass" for check in checks.values()):
        return "failed"
    if any(check["status"] != "pass" for check in desktop.values()):
        return "desktop-blocked"
    return "selected-live-checks-passed" if live else "automated-checks-passed-live-pending"


def verify_archive(archive):
    with tarfile.open(archive) as stream:
        manifests = [item for item in stream.getmembers() if item.name.endswith("/SHA256SUMS")]
        if len(manifests) != 1:
            raise ValueError("release must contain one checksum manifest")
        manifest = manifests[0]
        prefix = manifest.name.rsplit("/", 1)[0]
        verified = set()
        for line in stream.extractfile(manifest).read().decode().splitlines():
            digest, relative = line.split("  ", 1)
            member = stream.getmember(f"{prefix}/{relative}")
            if not member.isfile():
                raise ValueError(f"release input is not a regular file: {relative}")
            if hashlib.sha256(stream.extractfile(member).read()).hexdigest() != digest:
                raise ValueError(f"checksum mismatch: {relative}")
            if relative.startswith("bin/") and member.mode & 0o111 == 0:
                raise ValueError(f"release binary is not executable: {relative}")
            verified.add(relative)
        required = {"bin/shoji", "bin/shoji-loader", "bin/shoji-sa.dylib", "tools/service.py", "tools/signing.py", "README.md", "PORTING.md", "VALIDATION.md", "SETUP.md", "LICENSE"}
        if not required.issubset(verified):
            raise ValueError("release is missing required files")
        actual = {item.name for item in stream.getmembers() if item.isfile()}
        if actual != {f"{prefix}/{relative}" for relative in verified} | {manifest.name}:
            raise ValueError("release contains files without checksums")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight-only", action="store_true", help="only record desktop prerequisites")
    parser.add_argument("--live-animation", action="store_true", help="test disposable owned windows")
    parser.add_argument("--dock-restart", action="store_true", help="also restart Dock during the owned-window test")
    args = parser.parse_args()
    if args.dock_restart and not args.live_animation:
        parser.error("--dock-restart requires --live-animation")
    if platform.system() != "Darwin":
        parser.error("validation requires macOS")
    evidence = Path(tempfile.mkdtemp(prefix="shoji-validation-"))
    env = os.environ.copy()
    if (ROOT / ".toolchain/Odin/core").is_dir():
        env["ODIN_ROOT"] = str(ROOT / ".toolchain/Odin")
    actual = {"version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
              "build": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
              "architecture": platform.machine()}
    report = {"recorded_at": datetime.now(timezone.utc).isoformat(), "target": TARGET,
              "actual": actual, "matches_target": actual == TARGET,
              "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "working_tree": subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True),
              "checks": {}, "desktop": {}, "artifacts": {},
              "status": "running",
              "scope": "Selected automated checks only; this report does not certify all desktop behavior."}
    path = evidence / "report.json"

    def save():
        path.write_text(json.dumps(report, indent=2) + "\n")

    save()
    tasks = [] if args.preflight_only else ["test:compiler", "check", "test", "test:tooling", "test:amd64", "build:universal"]
    for task in tasks:
        print(f"Running {task}…", flush=True)
        check = execute(["task", task], evidence, task.replace(":", "-"), env)
        report["checks"][task] = check
        save()
        if check["status"] != "pass":
            report["status"] = "failed"
            save()
            print(f"Failed {task}; evidence: {path}", flush=True)
            return 1
    if not args.preflight_only:
        for name, command in [
            ("loader-self-test", [str(ROOT / "bin/shoji-loader"), "--self-test"]),
            ("bootstrap-relocation", ["python3", "tests/check_bootstrap.py", "bin/shoji-amd64", "bin/shoji-loader"]),
        ]:
            print(f"Running {name}…", flush=True)
            report["checks"][name] = execute(command, evidence, name, env)
            save()
        report["checks"]["package"] = execute(
            ["python3", "tools/package_release.py", "--version", "validation", "--output", str(evidence)],
            evidence, "package", env)
        if report["checks"]["package"]["status"] == "pass":
            archive = evidence / "shoji-validation-macos.tar.gz"
            try:
                verify_archive(archive)
                report["checks"]["archive-checksums"] = {"status": "pass", "archive": str(archive)}
            except (ValueError, OSError, KeyError, tarfile.TarError) as error:
                report["checks"]["archive-checksums"] = {"status": "fail", "reason": str(error)}
        save()
    for name in ("shoji", "shoji-loader", "shoji-sa.dylib"):
        binary = ROOT / "bin" / name
        if binary.is_file():
            report["artifacts"][name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    for name, option in [("inspection", "--inspect"), ("payload", "--check-sa")]:
        report["desktop"][name] = execute([str(ROOT / "bin/shoji"), option], evidence, name, env, timeout=15)
    if args.live_animation:
        if all(check["status"] == "pass" for check in report["desktop"].values()):
            command = ["python3", "tools/live_animation.py"]
            if args.dock_restart:
                command.append("--dock-restart")
            report["desktop"]["animation"] = execute(command, evidence, "animation", env)
        else:
            report["desktop"]["animation"] = {"status": "blocked", "reason": "desktop preflight failed"}
    report["status"] = summarize(report["checks"], report["desktop"], args.live_animation)
    if not report["matches_target"]:
        report["status"] = "target-mismatch"
    if args.preflight_only and report["status"] == "automated-checks-passed-live-pending":
        report["status"] = "desktop-preflight-passed"
    save()
    print(f"{report['status']}; evidence: {path}", flush=True)
    return 0 if report["status"] in ("automated-checks-passed-live-pending", "selected-live-checks-passed", "desktop-preflight-passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
