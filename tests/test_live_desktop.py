import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('live_desktop', ROOT / 'tools/live_desktop.py')
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)


class DesktopValidationTests(unittest.TestCase):
    def test_existing_shoji_is_not_replaced_or_terminated(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(desktop.tempfile, 'mkdtemp', return_value=directory), \
                mock.patch.object(desktop.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '[]', '')) as run, \
                mock.patch.object(desktop.subprocess, 'Popen') as start, \
                mock.patch('sys.argv', ['live_desktop']), mock.patch('sys.stdout', new_callable=io.StringIO):
            self.assertEqual(desktop.main(), 1)
            start.assert_not_called()
            self.assertEqual(run.call_count, 1)

    def test_fixture_start_failure_stops_only_its_child(self):
        child = mock.Mock()
        child.pid = 123
        child.stdout = io.StringIO('not valid JSON\n')
        child.poll.return_value = None
        def run(arguments, **kwargs):
            code = 1 if arguments[1:3] == ['-m', 'query'] else 0
            return subprocess.CompletedProcess(arguments, code, '', '')
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(desktop.tempfile, 'mkdtemp', return_value=directory), \
                mock.patch.object(desktop.subprocess, 'run', side_effect=run), \
                mock.patch.object(desktop.subprocess, 'Popen', return_value=child), \
                mock.patch.object(desktop.select, 'select', return_value=([child.stdout], [], [])), \
                mock.patch('sys.argv', ['live_desktop']), \
                mock.patch('sys.stdout', new_callable=io.StringIO):
            self.assertEqual(desktop.main(), 1)
            child.terminate.assert_called_once()
            self.assertEqual(json.loads((Path(directory) / 'report.json').read_text())['status'], 'failed')
            recorded = json.loads((Path(directory) / 'commands.json').read_text())
            self.assertFalse(any('sudo' in item['command'] or '/bin/launchctl' in item['command'] for item in recorded))


if __name__ == '__main__':
    unittest.main()
