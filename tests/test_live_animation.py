import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("live_animation", ROOT / "tools/live_animation.py")
live_animation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_animation)


class LiveHelperOutputTests(unittest.TestCase):
    def test_reload_does_not_restart_dock_when_sudo_policy_check_fails(self):
        with mock.patch.object(live_animation.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "sudo")), \
                mock.patch.object(live_animation.os, "kill") as kill:
            with self.assertRaises(subprocess.CalledProcessError):
                live_animation.restart_and_load_payload(Path("/test/shoji"), Path("/test/payload"))
            kill.assert_not_called()

    def test_reload_targets_only_the_current_users_dock_and_waits_for_replacement(self):
        dock = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
        with mock.patch.object(live_animation.os, "getuid", return_value=501), \
                mock.patch.object(live_animation.os, "kill") as kill, \
                mock.patch.object(live_animation.subprocess, "check_output", side_effect=[
                    f"10 501 {dock}\n20 502 {dock}\n", f"11 501 {dock}\n20 502 {dock}\n"]), \
                mock.patch.object(live_animation.subprocess, "run") as run:
            live_animation.restart_and_load_payload(Path("/test/shoji"), Path("/test/payload"))
            kill.assert_not_called()
            self.assertEqual(run.call_args_list[1].args[0],
                             ["/bin/launchctl", "print", "gui/501/com.apple.Dock.agent"])
            self.assertEqual(run.call_args_list[2].args[0],
                             ["/bin/launchctl", "kickstart", "-k", "gui/501/com.apple.Dock.agent"])
            self.assertEqual(run.call_args_list[3].args[0],
                             ["sudo", "-n", "/test/shoji", "--load-sa", "/test/payload"])
            self.assertEqual(run.call_args_list[4].args[0], ["/test/shoji", "--check-sa"])

    def test_reload_refuses_to_interrupt_dock_without_access_to_its_launchd_job(self):
        with mock.patch.object(live_animation.os, "getuid", return_value=501), \
                mock.patch.object(live_animation.os, "kill") as kill, \
                mock.patch.object(live_animation.subprocess, "run", side_effect=[
                    None, subprocess.CalledProcessError(1, "launchctl")]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                live_animation.restart_and_load_payload(Path("/test/shoji"), Path("/test/payload"))
            kill.assert_not_called()
            self.assertEqual(run.call_count, 2)

    def test_restart_timeout_requests_dock_recovery_without_loading_the_payload(self):
        dock = '/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock'
        with mock.patch.object(live_animation.os, 'getuid', return_value=501), \
                mock.patch.object(live_animation.subprocess, 'check_output', return_value=f'10 501 {dock}\n'), \
                mock.patch.object(live_animation.subprocess, 'run') as run, \
                mock.patch.object(live_animation.time, 'monotonic', side_effect=[0, 16]):
            with self.assertRaisesRegex(RuntimeError, 'Dock restart was not observed'):
                live_animation.restart_and_load_payload(Path('/test/shoji'), Path('/test/payload'))
            self.assertEqual(run.call_args_list[-1].args[0],
                             ['/bin/launchctl', 'kickstart', 'gui/501/com.apple.Dock.agent'])
            self.assertFalse(any(call.args[0][:3] == ['sudo', '-n', '/test/shoji'] for call in run.call_args_list))

    def test_malformed_alpha_is_reported_with_the_original_output(self):
        for output in ("", "%!(MISSING CLOSE BRACE)", "[]", '{"window":123}',
                       '{"window":124,"query_alpha":1}', '{"window":123,"query_alpha":true}',
                       '{"window":123,"query_alpha":NaN}', '{"window":123,"query_alpha":2}'):
            with self.subTest(output=output), self.assertRaises(RuntimeError) as error:
                live_animation.parse_alpha_output(output, 123)
            self.assertIn(repr(output), str(error.exception))
        self.assertEqual(live_animation.parse_alpha_output('{"window":123,"query_alpha":0.5}', 123), .5)

    @unittest.skipUnless(shutil.which("odin") or (ROOT / ".toolchain/Odin/odin").is_file(),
                         "Odin is required to compile the live helper")
    def test_alpha_output_is_json_without_a_desktop_connection(self):
        environment = os.environ.copy()
        pinned_compiler = ROOT / ".toolchain/Odin/odin"
        compiler = os.environ.get("ODIN") or (str(pinned_compiler) if pinned_compiler.is_file() else "odin")
        if (ROOT / ".toolchain/Odin/core").is_dir():
            environment["ODIN_ROOT"] = str(ROOT / ".toolchain/Odin")
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "helper"
            build = subprocess.run([compiler, "build", str(ROOT / "tools/live-animation"),
                                    f"-out:{helper}", "-extra-linker-flags:-F/System/Library/PrivateFrameworks"],
                                   env=environment, text=True, capture_output=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(helper), "--self-test-output"], check=True,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(json.loads(result.stdout), {"window": 123, "alpha": 1, "query_alpha": .5})


if __name__ == "__main__":
    unittest.main()
