"""Keep Shoji's code-signing identity stable across local rebuilds."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

IDENTIFIER = 'tech.shoji.window-manager'
LOCAL_NAME = 'Shoji Local Development'


def config_path():
    return Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'shoji/signing.json'


def run(arguments, input=None):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, input=input)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip() or f'{arguments[0]} failed')
    return result.stdout


def fingerprint(certificate):
    text = run(['/usr/bin/openssl', 'x509', '-in', certificate, '-noout', '-fingerprint', '-sha1'])
    value = text.strip().split('=')[-1].replace(':', '').upper()
    if not re.fullmatch(r'[0-9A-F]{40}', value):
        raise ValueError('invalid code-signing certificate fingerprint')
    return value


def identities(keychain, valid=True):
    arguments = ['/usr/bin/security', 'find-identity']
    if valid:
        arguments.append('-v')
    return run([*arguments, '-p', 'codesigning', keychain])


def check(config):
    identity = config.get('identity', '')
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
        raise ValueError('signing identity must be a certificate SHA-1 fingerprint')
    keychain = Path(config['keychain']).expanduser().resolve(strict=True)
    if identity.upper() not in identities(keychain).upper():
        raise ValueError('configured signing identity is unavailable or untrusted; unlock its keychain '
                         'and run task signing:setup. Refusing to fall back to ad-hoc signing.')
    return {'identity': identity.upper(), 'keychain': str(keychain)}


def load_config(path=None, adhoc=False):
    if adhoc or os.environ.get('SHOJI_ADHOC_SIGNING') == '1':
        return None
    path = Path(path or config_path())
    if not path.is_file():
        raise ValueError('persistent signing is not configured; run task signing:setup first. '
                         'For CI-only ad-hoc builds, set SHOJI_ADHOC_SIGNING=1.')
    return check(json.loads(path.read_text()))


def save_config(path, config):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(config, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
            temporary.chmod(0o600)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def setup(path=None, identity=None, keychain=None):
    path = Path(path or config_path())
    if path.exists() and identity is None:
        return check(json.loads(path.read_text()))
    keychain = Path(keychain or run(['/usr/bin/security', 'default-keychain', '-d', 'user']).strip().strip('"'))
    keychain = keychain.expanduser().resolve(strict=True)
    if identity is None:
        path.parent.mkdir(parents=True, exist_ok=True)
        certificate = path.parent / 'local-signing.pem'
        # Retain only the public certificate for retries after a Keychain UI prompt.
        # Private key material exists only in a mode-0700 temporary directory, then
        # is imported as non-extractable with access limited to codesign.
        if not certificate.exists():
            with tempfile.TemporaryDirectory(prefix='shoji-signing-') as directory:
                directory = Path(directory)
                directory.chmod(0o700)
                key, request, cert, bundle = [directory / name for name in ('key.pem', 'request.pem', 'cert.pem', 'identity.p12')]
                extensions = directory / 'extensions.cnf'
                extensions.write_text('basicConstraints=critical,CA:FALSE\n'
                                      'keyUsage=critical,digitalSignature\n'
                                      'extendedKeyUsage=critical,codeSigning\n')
                run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes',
                     '-keyout', key, '-out', request, '-subj', f'/CN={LOCAL_NAME}/'])
                key.chmod(0o600)
                run(['/usr/bin/openssl', 'x509', '-req', '-in', request, '-signkey', key,
                     '-out', cert, '-days', '3650', '-sha256', '-extfile', extensions])
                password = secrets.token_urlsafe(32)
                run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', key, '-in', cert,
                     '-out', bundle, '-name', LOCAL_NAME, '-passout', 'stdin'], input=password + '\n')
                run(['/usr/bin/openssl', 'pkcs12', '-in', bundle, '-noout', '-passin', 'stdin'],
                    input=password + '\n')
                bundle.chmod(0o600)
                try:
                    run(['/usr/bin/security', 'import', bundle, '-k', keychain, '-f', 'pkcs12',
                         '-P', password, '-x', '-T', '/usr/bin/codesign'])
                except ValueError as error:
                    raise ValueError('Keychain import failed. Run setup from your logged-in macOS '
                                     f'terminal with the selected keychain unlocked. Details: {error}') from error
                with certificate.open('x') as output:
                    output.write(cert.read_text())
        identity = fingerprint(certificate)
        if identity not in identities(keychain, valid=False).upper():
            raise ValueError('local certificate exists but its private key is unavailable; '
                             'restore the original keychain or select an existing identity with --identity')
        # User-domain trust, constrained to code signing. No system/SSL trust changes.
        run(['/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
             '-k', keychain, certificate])
    config = check({'identity': identity, 'keychain': str(keychain)})
    save_config(path, config)
    return config


def sign(binary, config, identifier=IDENTIFIER, install=None, codesign='/usr/bin/codesign'):
    binary = Path(binary)
    if binary.is_symlink() or not binary.is_file():
        raise ValueError('signing input must be a regular, non-symlink file')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', identifier):
        raise ValueError('invalid signing identifier')
    destination = Path(install) if install is not None else None
    if destination is not None:
        if destination.is_symlink():
            raise ValueError('refusing to replace a symlink')
        if destination.resolve() == binary.resolve():
            raise ValueError('atomic installation requires a separate candidate binary')
        if destination.parent.resolve() != binary.parent.resolve():
            raise ValueError('candidate and installed binary must share a directory')
    arguments = [codesign, '--force', '--sign', config['identity'] if config else '-',
                 '--identifier', identifier, '--timestamp=none']
    requirement = None
    if config:
        # Pin the signing certificate, never the changing executable's cdhash.
        requirement = f'identifier "{identifier}" and certificate leaf = H"{config["identity"]}"'
        arguments += ['--keychain', config['keychain'], '--requirements', f'=designated => {requirement}']
    run([*arguments, binary])
    run([codesign, '--verify', '--strict', binary])
    if requirement:
        run([codesign, '--verify', '--strict', '--test-requirement', '=' + requirement, binary])
    if destination is not None:
        os.replace(binary, destination)
    return destination or binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    commands = parser.add_subparsers(dest='command', required=True)
    setup_parser = commands.add_parser('setup', help='create a persistent local identity, or select an existing certificate')
    setup_parser.add_argument('--identity', help='existing code-signing certificate SHA-1 fingerprint')
    setup_parser.add_argument('--keychain', type=Path)
    commands.add_parser('check')
    sign_parser = commands.add_parser('sign')
    sign_parser.add_argument('binary', type=Path)
    sign_parser.add_argument('--identifier', default=IDENTIFIER)
    sign_parser.add_argument('--install', type=Path)
    sign_parser.add_argument('--codesign', default='/usr/bin/codesign')
    sign_parser.add_argument('--ad-hoc', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'setup':
            config = setup(args.config, args.identity, args.keychain)
            print(f'Persistent identity configured: {config["identity"]}')
            print('Build with task build. Grant Accessibility once after switching from ad-hoc signing.')
        else:
            config = load_config(args.config, getattr(args, 'ad_hoc', False))
            if args.command == 'sign':
                print('Signed:', sign(args.binary, config, args.identifier, args.install, args.codesign))
            else:
                print('Signing:', config['identity'] if config else 'explicit CI ad-hoc mode')
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'signing: {error}\n')


if __name__ == '__main__':
    main()
