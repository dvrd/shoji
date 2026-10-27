import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('live_spaces', ROOT / 'tools/live_spaces.py')
spaces = importlib.util.module_from_spec(spec)
spec.loader.exec_module(spaces)


class OwnedSpaceTests(unittest.TestCase):
    def test_cleanup_never_destroys_a_preexisting_space(self):
        calls = []
        for candidate in (0, 1, 2):
            with self.assertRaises(RuntimeError):
                spaces.restore_and_destroy(candidate, 1, {1, 2}, lambda *args: calls.append(args),
                                           lambda: {'spaces': [{'id': 1}, {'id': 2}]})
        self.assertEqual(calls, [])

    def test_cleanup_restores_original_space_before_destroying_only_the_owned_id(self):
        calls = []
        spaces.restore_and_destroy(3, 1, {1, 2}, lambda *args: calls.append(args),
                                   lambda: {'spaces': [{'id': 1}, {'id': 2}, {'id': 3}, {'id': 4}]})
        self.assertEqual(calls, [('space-focus', 1), ('space-destroy', 3)])

    def test_cleanup_does_not_retry_a_destroyed_id_or_guess_a_replacement(self):
        calls = []
        spaces.restore_and_destroy(3, 1, {1, 2}, lambda *args: calls.append(args),
                                   lambda: {'spaces': [{'id': 1}, {'id': 2}, {'id': 4}]})
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
