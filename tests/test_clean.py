import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
MACHO = b"\xcf\xfa\xed\xfe" + b"fixture"


class CleanTests(unittest.TestCase):
    def test_preview_and_cleanup_preserve_runtime_research_and_unknown_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools").mkdir()
            cleaner = root / "tools/clean.py"
            shutil.copyfile(ROOT / "tools/clean.py", cleaner)
            (root / "bin").mkdir()
            keep = ["shoji", "shoji-loader", "shoji-sa.dylib", "odin-arm64e"]
            for name in keep + ["shoji-tests", "shoji-debug.new"]:
                (root / "bin" / name).write_bytes(MACHO)
            for name in ["restore.ipsw", "notes.json", "shoji-notes.txt"]:
                (root / "bin" / name).write_text("keep")
            (root / "artifacts").mkdir()
            (root / "artifacts/report.json").write_text("evidence")
            (root / "bin/shoji-old").symlink_to(root / "artifacts/report.json")
            for name in ["shoji-tests.dSYM", "ShojiScrollProbe.app", "raven"]:
                (root / "bin" / name).mkdir()
                (root / "bin" / name / "generated").write_text("generated")
            preview = subprocess.run([sys.executable, cleaner, "--dry-run"], check=True, capture_output=True, text=True)
            self.assertIn("Would remove: bin/shoji-tests", preview.stdout)
            self.assertTrue((root / "bin/shoji-tests").exists())
            subprocess.run([sys.executable, cleaner], check=True, capture_output=True)
            for name in keep:
                self.assertEqual((root / "bin" / name).read_bytes(), MACHO)
            self.assertFalse((root / "bin/shoji-tests").exists())
            self.assertFalse((root / "bin/shoji-tests.dSYM").exists())
            self.assertTrue((root / "bin/shoji-old").is_symlink())
            for name in ["restore.ipsw", "notes.json", "shoji-notes.txt"]:
                self.assertEqual((root / "bin" / name).read_text(), "keep")
            self.assertEqual((root / "artifacts/report.json").read_text(), "evidence")
            again = subprocess.run([sys.executable, cleaner], check=True, capture_output=True, text=True)
            self.assertIn("Removed 0", again.stdout)

    def test_symlinked_build_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools").mkdir()
            cleaner = root / "tools/clean.py"
            shutil.copyfile(ROOT / "tools/clean.py", cleaner)
            (root / "outside").mkdir()
            binary = root / "outside/shoji-tests"
            binary.write_bytes(MACHO)
            (root / "bin").symlink_to(root / "outside", target_is_directory=True)
            result = subprocess.run([sys.executable, cleaner], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlinked bin", result.stderr)
            self.assertEqual(binary.read_bytes(), MACHO)


if __name__ == "__main__":
    unittest.main()
