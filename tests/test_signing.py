import importlib.util
import json
import platform
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('signing', ROOT / 'tools/signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
IDENTITY = 'AB' * 20
CONFIG = {'identity': IDENTITY, 'keychain': '/tmp/local.keychain-db'}


class SigningTests(unittest.TestCase):
    def test_different_builds_share_certificate_requirement_and_stable_identifier(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(signing, 'run') as run:
            installed = Path(directory) / 'shoji'
            requirements = []
            for name, data in [('first.new', b'first build'), ('second.new', b'different build')]:
                candidate = Path(directory) / name
                candidate.write_bytes(data)
                signing.sign(candidate, CONFIG, install=installed)
                self.assertEqual(installed.read_bytes(), data)
                self.assertFalse(candidate.exists())
                invocation = run.call_args_list[-3].args[0]
                requirements.append(invocation[invocation.index('--requirements') + 1])
                self.assertEqual(invocation[invocation.index('--identifier') + 1], signing.IDENTIFIER)
            self.assertEqual(requirements[0], requirements[1])
            self.assertIn(f'certificate leaf = H"{IDENTITY}"', requirements[0])
            self.assertNotIn('cdhash', requirements[0])

    @unittest.skipUnless(platform.system() == 'Darwin', 'requires native macOS signing tools')
    def test_inline_requirements_are_accepted_by_native_signing_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'candidate with spaces'
            shutil.copyfile('/usr/bin/true', binary)
            with mock.patch.object(signing, 'run') as run:
                signing.sign(binary, CONFIG)
            arguments = list(run.call_args_list[0].args[0])
            # Isolate requirement parsing from access to a developer's Keychain.
            # Keep the production requirement text verbatim, using an ad-hoc signer.
            arguments[arguments.index('--sign') + 1] = '-'
            keychain_index = arguments.index('--keychain')
            del arguments[keychain_index:keychain_index + 2]
            result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            verification = run.call_args_list[-1].args[0]
            expression = verification[verification.index('--test-requirement') + 1]
            compiled = Path(directory) / 'requirement.bin'
            result = subprocess.run(['/usr/bin/csreq', '-r', expression, '-b', str(compiled)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreater(compiled.stat().st_size, 0)

    def test_failed_verification_keeps_installed_binary_intact(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate, installed = [Path(directory) / name for name in ('shoji.new', 'shoji')]
            candidate.write_bytes(b'new')
            installed.write_bytes(b'working')
            with mock.patch.object(signing, 'run', side_effect=['', ValueError('signature rejected')]):
                with self.assertRaisesRegex(ValueError, 'signature rejected'):
                    signing.sign(candidate, CONFIG, install=installed)
            self.assertEqual(installed.read_bytes(), b'working')
            self.assertTrue(candidate.exists())

    def test_missing_or_unavailable_identity_never_silently_uses_ad_hoc(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(signing.os.environ, {}, clear=True):
            config = Path(directory) / 'signing.json'
            with self.assertRaisesRegex(ValueError, 'signing:setup'):
                signing.load_config(config)
            keychain = Path(directory) / 'local.keychain-db'
            keychain.touch()
            config.write_text(json.dumps({'identity': IDENTITY, 'keychain': str(keychain)}))
            with mock.patch.object(signing, 'run', return_value='0 valid identities found'):
                with self.assertRaisesRegex(ValueError, 'Refusing to fall back'):
                    signing.load_config(config)
            self.assertIsNone(signing.load_config(config, adhoc=True))

    def test_setup_reuses_existing_identity_without_regenerating_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'signing.json'
            keychain = Path(directory) / 'local.keychain-db'
            keychain.touch()
            selected = {'identity': IDENTITY, 'keychain': str(keychain.resolve())}
            config.write_text(json.dumps(selected))
            with mock.patch.object(signing, 'run', return_value=IDENTITY) as run:
                self.assertEqual(signing.setup(config), selected)
                self.assertEqual(len(run.call_args_list), 1)
                self.assertIn('find-identity', run.call_args.args[0])

    def test_atomic_install_rejects_symlinks_and_in_place_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'shoji'
            binary.write_bytes(b'working')
            link = Path(directory) / 'link'
            link.symlink_to(binary)
            with mock.patch.object(signing, 'run') as run:
                for candidate, target in [(link, binary), (binary, link), (binary, binary)]:
                    with self.assertRaises(ValueError):
                        signing.sign(candidate, CONFIG, install=target)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
