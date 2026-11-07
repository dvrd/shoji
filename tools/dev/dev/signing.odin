package development

import tc "../../common"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import support "../../../src/support"

SIGNING_IDENTIFIER :: "tech.shoji.window-manager"
Signing_Config :: struct {
	identity, keychain: string,
	adhoc: bool `json:"-"`,
}
signing_path :: proc() -> string {
	base := os.get_env("XDG_CONFIG_HOME", context.allocator); if base == "" {
		base = support.join(support.home(), ".config")
	}; return support.join(base, "shoji/signing.json")
}
signing_check :: proc(c: tc.Context, config: Signing_Config) -> string {
	if config.adhoc {
		return ""
	}
	if !support.hexadecimal(config.identity, 40) {
		return "signing identity must be a certificate SHA-1 fingerprint"
	}
	if !support.regular(config.keychain) {
		return "configured signing keychain is unavailable"
	}
	out, err := tc.run(
		c,
		[]string {
			"/usr/bin/security",
			"find-identity",
			"-v",
			"-p",
			"codesigning",
			config.keychain,
		},
	)
	if err != "" {
		return err
	}
	if !strings.contains(
		strings.to_upper(out),
		strings.to_upper(config.identity),
	) {
		return(
			"configured signing identity unavailable; unlock its keychain or run task signing:setup. Refusing to fall back to ad-hoc signing" \
		)
	}
	return ""
}
Signing_Disk_Config :: struct {
	identity, keychain: string,
}
read_signing_config :: proc(
	c: tc.Context,
	path: string,
) -> (
	Signing_Config,
	string,
) {
	if !support.regular(path) {
		return {},
			"persistent signing is not configured; run task signing:setup"
	}
	disk: Signing_Disk_Config
	if err := tc.read_json(path, &disk); err != "" {
		return {}, err
	}
	config := Signing_Config {
		identity = strings.to_upper(disk.identity),
		keychain = support.real(disk.keychain),
	}
	return config, signing_check(c, config)
}
signing_load :: proc(
	c: tc.Context,
	path: string = "",
	adhoc: bool = false,
) -> (
	Signing_Config,
	string,
) {
	if adhoc || os.get_env("SHOJI_ADHOC_SIGNING", context.allocator) == "1" {
		return {adhoc = true}, ""
	}
	path := path; if path == "" {
		path = signing_path()
	}
	return read_signing_config(c, path)
}
signing_requirement :: proc(identifier, identity: string) -> string {
	return fmt.tprintf(
		`identifier "%s" and certificate leaf = H"%s"`,
		identifier,
		identity,
	)
}
sign :: proc(
	c: tc.Context,
	path: string,
	config: Signing_Config,
	identifier: string = SIGNING_IDENTIFIER,
	install: string = "",
	codesign: string = "/usr/bin/codesign",
) -> string {
	if !support.regular(path) {
		return "signing input must be a regular non-symlink file"
	}
	if !support.safe_name(identifier) || strings.contains(identifier, "_") {
		return "invalid signing identifier"
	}
	if install != "" {
		if support.kind(install) == .Symlink {
			return "refusing to replace a symlink"
		}
		if support.abs(path) == support.abs(install) {
			return "atomic installation requires a separate candidate"
		}
		if support.real(filepath.dir(support.abs(path))) !=
		   support.real(filepath.dir(support.abs(install))) {
			return "candidate and installed binary must share a directory"
		}
	}
	args := make([dynamic]string)
	append(
		&args,
		codesign,
		"--force",
		"--sign",
		config.adhoc ? "-" : config.identity,
		"--identifier",
		identifier,
		"--timestamp=none",
	)
	requirement := ""
	if !config.adhoc {
		requirement = signing_requirement(identifier, config.identity)
		append(
			&args,
			"--keychain",
			config.keychain,
			"--requirements",
			support.cat("=designated => ", requirement),
		)
	}
	append(&args, path)
	if _, err := tc.run(c, args[:]); err != "" {
		return err
	}
	if _, err := tc.run(c, []string{codesign, "--verify", "--strict", path});
	   err != "" {
		return err
	}
	if requirement != "" {
		if _, err := tc.run(
			c,
			[]string {
				codesign,
				"--verify",
				"--strict",
				"--test-requirement",
				support.cat("=", requirement),
				path,
			},
		); err != "" {
			return err
		}
	}
	if install != "" {
		if err := os.rename(path, install); err != nil {
			return fmt.tprintf("atomic install failed: %v", err)
		}
	}
	return ""
}
signing_setup :: proc(
	c: tc.Context,
	path, identity, keychain: string,
) -> string {
	path := path; identity := identity; keychain := keychain
	if path == "" {
		path = signing_path()
	}
	if support.exists(path) && identity == "" {
		_, err := read_signing_config(c, path); return err
	}
	if keychain == "" {
		out, err := tc.run(
			c,
			[]string{"/usr/bin/security", "default-keychain", "-d", "user"},
		); if err != "" {
			return err
		}; keychain = strings.trim(support.trim(out), "\"")
	}
	keychain = support.real(keychain)
	if keychain == "" {
		return "keychain does not exist"
	}
	if identity == "" {
		if err := support.mkdir(filepath.dir(path)); err != "" {
			return err
		}
		certificate := support.join(filepath.dir(path), "local-signing.pem")
		if !support.exists(certificate) {
			stage, err := support.temp("shoji-signing"); if err != "" {
				return err
			}; defer os.remove_all(stage)
			_ = os.chmod(stage, {.Read_User, .Write_User, .Execute_User})
			key, request, cert, bundle, extensions :=
				support.join(stage, "key.pem"),
				support.join(stage, "request.pem"),
				support.join(stage, "cert.pem"),
				support.join(stage, "identity.p12"),
				support.join(stage, "extensions.cnf")
			if err = support.write(
				extensions,
				"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n",
			); err != "" {
				return err
			}
			if _, err = tc.run(
				c,
				[]string {
					"/usr/bin/openssl",
					"req",
					"-new",
					"-newkey",
					"rsa:3072",
					"-nodes",
					"-keyout",
					key,
					"-out",
					request,
					"-subj",
					"/CN=Shoji Local Development",
				},
			); err != "" {
				return err
			}
			_ = os.chmod(key, {.Read_User, .Write_User})
			if _, err = tc.run(
				c,
				[]string {
					"/usr/bin/openssl",
					"x509",
					"-req",
					"-in",
					request,
					"-signkey",
					key,
					"-out",
					cert,
					"-days",
					"3650",
					"-sha256",
					"-extfile",
					extensions,
				},
			); err != "" {
				return err
			}
			password, e := tc.run(
				c,
				[]string{"/usr/bin/openssl", "rand", "-hex", "32"},
			); if e != "" {
				return e
			}; password = support.trim(password)
			if _, err = tc.run(
				c,
				[]string {
					"/usr/bin/openssl",
					"pkcs12",
					"-export",
					"-inkey",
					key,
					"-in",
					cert,
					"-out",
					bundle,
					"-name",
					"Shoji Local Development",
					"-passout",
					"stdin",
				},
				"",
				support.cat(password, "\n"),
			); err != "" {
				return err
			}
			if _, err = tc.run(
				c,
				[]string {
					"/usr/bin/openssl",
					"pkcs12",
					"-in",
					bundle,
					"-noout",
					"-passin",
					"stdin",
				},
				"",
				support.cat(password, "\n"),
			); err != "" {
				return err
			}
			_ = os.chmod(bundle, {.Read_User, .Write_User})
			if _, err = tc.run(
				c,
				[]string {
					"/usr/bin/security",
					"import",
					bundle,
					"-k",
					keychain,
					"-f",
					"pkcs12",
					"-P",
					password,
					"-x",
					"-T",
					"/usr/bin/codesign",
				},
			); err != "" {
				return support.cat(
					"Keychain import failed; run setup in the logged-in session with an unlocked keychain: ",
					err,
				)
			}
			if err = support.copy_file(certificate, cert); err != "" {
				return err
			}
		}
		out, err := tc.run(
			c,
			[]string {
				"/usr/bin/openssl",
				"x509",
				"-in",
				certificate,
				"-noout",
				"-fingerprint",
				"-sha1",
			},
		); if err != "" {
			return err
		}
		at := strings.index(out, "="); if at < 0 {
			return "invalid certificate fingerprint"
		}; identity, _ = strings.replace_all(support.trim(out[at + 1:]), ":", "")
		identity = strings.to_upper(identity)
		if !support.hexadecimal(identity, 40) {
			return "invalid certificate fingerprint"
		}
		identities, e := tc.run(
			c,
			[]string {
				"/usr/bin/security",
				"find-identity",
				"-p",
				"codesigning",
				keychain,
			},
		); if e != "" {
			return e
		}
		if !strings.contains(strings.to_upper(identities), identity) {
			return(
				"local certificate exists but its private key is unavailable; select an existing identity with --identity" \
			)
		}
		if _, err = tc.run(
			c,
			[]string {
				"/usr/bin/security",
				"add-trusted-cert",
				"-r",
				"trustRoot",
				"-p",
				"codeSign",
				"-k",
				keychain,
				certificate,
			},
		); err != "" {
			return err
		}
	}
	config := Signing_Config {
		identity = strings.to_upper(identity),
		keychain = keychain,
	}
	if err := signing_check(c, config); err != "" {
		return err
	}
	data, encode_error := json.marshal(
		Signing_Disk_Config{config.identity, config.keychain},
		{pretty = true},
	); if encode_error != nil {
		return "cannot encode signing configuration"
	}
	return support.atomic_write(path, string(data))
}
signing_cli :: proc(c: tc.Context, args: []string) -> string {
	if len(args) == 0 {
		return "signing expects setup|check|sign"
	}
	o, err := support.parse(
		args[1:],
		[]string {
			"config",
			"identity",
			"keychain",
			"identifier",
			"install",
			"codesign",
		},
		[]string{"ad-hoc"},
	); if err != "" {
		return err
	}
	if args[0] == "setup" {
		if len(o.positionals) != 0 {
			return "unexpected setup arguments"
		}
		return signing_setup(
			c,
			support.get(o, "config"),
			support.get(o, "identity"),
			support.get(o, "keychain"),
		)
	}
	config, e := signing_load(c, support.get(o, "config"), o.flags["ad-hoc"])
	if e != "" {
		return e
	}
	if args[0] == "check" && len(o.positionals) == 0 {
		fmt.println(
			"Signing:",
			config.adhoc ? "explicit CI ad-hoc mode" : config.identity,
		); return ""
	}
	if args[0] != "sign" || len(o.positionals) != 1 {
		return "signing sign expects one candidate binary"
	}
	err = sign(
		c,
		o.positionals[0],
		config,
		support.get(o, "identifier", SIGNING_IDENTIFIER),
		support.get(o, "install"),
		support.get(o, "codesign", "/usr/bin/codesign"),
	)
	if err == "" {
		fmt.println("Signed:", support.get(o, "install", o.positionals[0]))
	}; return err
}
