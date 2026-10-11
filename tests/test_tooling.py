import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, PROJECT / "tools" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


service = load("service")
release = load("package_release")


class ToolingTests(unittest.TestCase):
    def test_launchd_lifecycle_and_literal_arguments(self):
        calls = []
        loaded = False

        def runner(arguments, **kwargs):
            nonlocal loaded
            calls.append(arguments)
            if arguments[1] == "print":
                return subprocess.CompletedProcess(arguments, 0 if loaded else 1, "", "")
            if arguments[1] == "bootstrap":
                loaded = True
            if arguments[1] == "bootout":
                loaded = False
            return subprocess.CompletedProcess(arguments, 0, "", "")

        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "shoji $(touch never)"
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            manager = service.Service(directory, 501, runner)
            manager.install(binary)
            data = plistlib.loads(manager.plist.read_bytes())
            self.assertEqual(data["ProgramArguments"], [str(binary.resolve())])
            self.assertFalse(loaded)
            manager.start()
            with self.assertRaises(ValueError):
                manager.install(binary)
            manager.restart()
            self.assertIn(["/bin/launchctl", "kickstart", "-k", manager.target], calls)
            manager.uninstall()
            self.assertFalse(loaded)
            self.assertFalse(manager.plist.exists())

    def test_service_refuses_foreign_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = service.Service(directory, 501, lambda *a, **k: subprocess.CompletedProcess(a, 1))
            manager.plist.parent.mkdir(parents=True)
            manager.plist.write_bytes(plistlib.dumps({"Label": "somebody-else"}))
            with self.assertRaises(ValueError):
                manager.uninstall()
            with self.assertRaises(ValueError):
                manager.start()
            self.assertTrue(manager.plist.exists())

    def test_invalid_release_inputs_and_service_config_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "shoji"
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            with self.assertRaises(ValueError):
                service.configuration(binary, directory, directory)
            with self.assertRaises(ValueError):
                release.package(PROJECT, directory, directory, "../escape")
            with self.assertRaises(ValueError):
                release.package(PROJECT, directory, directory, "valid")

    def test_release_contains_siblings_and_valid_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / "bin"
            binaries.mkdir()
            for name in ("shoji", "shoji-loader", "shoji-sa.dylib"):
                (binaries / name).write_bytes(name.encode())
                (binaries / name).chmod(0o755)
            archive = release.package(PROJECT, binaries, root / "out", "0.1.0-test")
            with tarfile.open(archive) as stream:
                manifest = stream.extractfile("shoji-0.1.0-test/SHA256SUMS").read().decode()
                for line in manifest.splitlines():
                    digest, relative = line.split("  ", 1)
                    data = stream.extractfile(f"shoji-0.1.0-test/{relative}").read()
                    self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                self.assertTrue(stream.getmember("shoji-0.1.0-test/bin/shoji").mode & 0o111)
            with self.assertRaises(ValueError):
                release.package(PROJECT, binaries, root / "out", "0.1.0-test")


if __name__ == "__main__":
    unittest.main()
