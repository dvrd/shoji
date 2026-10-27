package dockscan

import "core:fmt"
import "core:os"
import "core:strings"

provider_names :: proc() -> [7][3]string {
	return [7][3]string {
		{"dock_spaces", "get_dock_spaces_pattern", "get_dock_spaces_offset"},
		{"desktop_pictures", "get_dppm_pattern", "get_dppm_offset"},
		{"add_space", "get_add_space_pattern", "get_add_space_offset"},
		{"remove_space", "get_remove_space_pattern", "get_remove_space_offset"},
		{"move_space", "get_move_space_pattern", "get_move_space_offset"},
		{"focus_window", "get_set_front_window_pattern", "get_set_front_window_offset"},
		{"animation_time", "get_fix_animation_pattern", "get_fix_animation_offset"},
	}
}
propose :: proc(analysis_dir: string, selections: []string, out: string) -> string {
	if len(selections) == 0 {
		return "propose requires explicit --select TARGET=candidate-N"
	}
	if os.exists(out) {
		return "patch output already exists"
	}
	a: Analysis; if err := read_json(join(analysis_dir, "analysis.json"), &a); err != "" {
		return err
	}
	if a.schema != 1 || !a.static_only {
		return "unsupported analysis format"
	}
	version, ok := parse_version(a.target.os_version); if !ok || a.target.build == "" {
		return "target OS version and build must be known before proposing a patch"
	}
	target, target_err := load_bundle(a.target_path)
	if target_err != "" {
		return target_err
	}
	if target.manifest.sha256 != a.target.sha256 {
		return "target binary changed since comparison; regenerate analysis"
	}
	// Requiring the same compiled source prevents silently proposing edits against
	// tables that have changed since the evidence was generated.
	source, e := os.read_entire_file(join(analysis_dir, "patterns_arm64.odin"), context.allocator)
	if e != nil ||
	   digest(source) != a.pattern_source_sha256 ||
	   a.pattern_source_sha256 != digest(PATTERN_SOURCE) {
		return(
			"pattern source changed or analysis source digest is invalid; regenerate the comparison" \
		)
	}
	updated := string(source); selected := make(map[string]bool)
	checkout_source := "src/addition/patterns/patterns_arm64.odin"
	if os.exists(checkout_source) {
		current, read_error := os.read_entire_file(checkout_source, context.allocator)
		if read_error != nil || digest(current) != a.pattern_source_sha256 {
			return "checkout pattern source changed since comparison; rebuild the tool and regenerate analysis"
		}
	}
	for selection in selections {
		parts := strings.split(
			selection,
			"=",
		); if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			return "selection must be TARGET=candidate-N"
		}
		if selected[parts[0]] {
			return "duplicate target selection"
		}; selected[parts[0]] = true
		found := false
		for t in a.targets {
			if t.name != parts[0] {
				continue
			}
			for c in t.candidates {
				if c.id != parts[1] {
					continue
				}; found = true
				if c.pattern_matches != 1 || c.pattern == "" {
					return(
						"selected pattern must have exactly one match; refine and rescan ambiguous candidates first" \
					)
				}
				actual := scan_target(target.image, Target{pattern = c.pattern})
				if len(actual.matches) != 1 ||
				   actual.matches[0].address != c.address ||
				   actual.matches[0].text_offset != c.text_offset {
					return "selected candidate does not match the target binary"
				}
				// Only safe alphabet characters are permitted in emitted source comments.
				for ch in a.target.build {
					if !(ch >= '0' && ch <= '9' ||
						   ch >= 'A' && ch <= 'Z' ||
						   ch >= 'a' && ch <= 'z') {
						return "invalid target build identifier"
					}
				}
				for ch in c.pattern {
					if !(ch == ' ' ||
						   ch == '?' ||
						   ch >= '0' && ch <= '9' ||
						   ch >= 'A' && ch <= 'F' ||
						   ch >= 'a' && ch <= 'f') {
						return "invalid candidate pattern"
					}
				}
				mapping_found := false
				for names in provider_names() {
					if names[0] != t.name {
						continue
					}; mapping_found = true
					for kind in 0 ..< 2 {
						signature := fmt.tprintf(
							"%s :: proc(os_version: Version) -> %s {{",
							names[kind + 1],
							kind == 0 ? "string" : "u64",
						)
						at := strings.index(updated, signature); if at < 0 {
							return fmt.tprintf(
								"could not locate provider %q in %d bytes",
								signature,
								len(updated),
							)
						}
						value :=
							kind == 0 ? fmt.tprintf("\"%s\"", c.pattern) : fmt.tprintf("0x%x", c.text_offset &~ u64(0xffff))
						block := fmt.tprintf(
							"\n\t// Proposed from %s, Dock SHA-256 %s; selected %s/%s.\n\t// Static evidence only. This condition selects an OS version, not an exact build.\n\tif os_version.major == %d && os_version.minor == %d && os_version.patch == %d {{\n\t\treturn %s\n\t}}\n",
							a.target.build,
							a.target.sha256,
							t.name,
							c.id,
							version.major,
							version.minor,
							version.patch,
							value,
						)
						end :=
							at +
							len(
								signature,
							); updated = fmt.tprintf("%s%s%s", updated[:end], block, updated[end:])
					}
				}
				if !mapping_found {
					return "unknown target name"
				}
			}
		}
		if !found {
			return fmt.tprintf("selection not present in analysis: %s", selection)
		}
	}
	dir, error := os.make_directory_temp(
		"",
		"shoji-dock-proposal-*",
		context.allocator,
	); if error != nil {
		return "cannot create patch workspace"
	}; defer os.remove_all(dir)
	before := join(dir, "before.odin"); after := join(dir, "after.odin")
	if err := write_text(before, string(source)); err != "" {
		return err
	}
	if err := write_text(after, updated); err != "" {
		return err
	}
	state, diff, stderr, err := os.process_exec(
		os.Process_Desc {
			command = []string {
				"/usr/bin/diff",
				"-u",
				"-L",
				"a/src/addition/patterns/patterns_arm64.odin",
				"-L",
				"b/src/addition/patterns/patterns_arm64.odin",
				before,
				after,
			},
		},
		context.allocator,
	)
	if err != nil || state.exit_code != 1 {
		return fmt.tprintf("could not generate patch: %v %s", err, string(stderr))
	}
	if error := write_text(out, string(diff)); error != "" {
		return error
	}
	fmt.printf(
		"Proposed patch: %s\nSupport gate unchanged. Review ABI and behavior before enabling the OS version.\n",
		out,
	)
	return ""
}
