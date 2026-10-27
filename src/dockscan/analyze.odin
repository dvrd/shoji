package dockscan

import p "../addition/patterns"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:mem"
import "core:strconv"
import "core:strings"


Target :: struct {
	name: string,
	pattern: string,
	hint: u64,
	global: bool,
}
Match :: struct {
	address, file_offset, text_offset: u64,
	reference: u64,
	reference_valid: bool,
}
Target_Result :: struct {
	name, pattern, status: string,
	hint: u64,
	matches: [dynamic]Match,
}
Scan_Report :: struct {
	schema: int,
	manifest: Manifest,
	profile: string,
	static_only: bool,
	targets: [dynamic]Target_Result,
}
parse_version :: proc(s: string) -> (p.Version, bool) {
	parts := strings.split(s, "."); if len(parts) < 1 || len(parts) > 3 {
		return {}, false
	}
	v: p.Version; values := [3]int{}
	for part, i in parts {
		n, ok := strconv.parse_u64(part); if !ok || n > 9999 {
			return {}, false
		}; values[i] = int(n)
	}
	v = {values[0], values[1], values[2]}; return v, true
}
targets_for :: proc(v: p.Version) -> [7]Target {
	return [7]Target {
		{"dock_spaces", p.get_dock_spaces_pattern(v), p.get_dock_spaces_offset(v), true},
		{"desktop_pictures", p.get_dppm_pattern(v), p.get_dppm_offset(v), true},
		{"add_space", p.get_add_space_pattern(v), p.get_add_space_offset(v), false},
		{"remove_space", p.get_remove_space_pattern(v), p.get_remove_space_offset(v), false},
		{"move_space", p.get_move_space_pattern(v), p.get_move_space_offset(v), false},
		{
			"focus_window",
			p.get_set_front_window_pattern(v),
			p.get_set_front_window_offset(v),
			false,
		},
		{"animation_time", p.get_fix_animation_pattern(v), p.get_fix_animation_offset(v), false},
	}
}
scan_target :: proc(im: Image, t: Target) -> Target_Result {
	result := Target_Result {
		name    = t.name,
		pattern = t.pattern,
		hint    = t.hint,
		status  = "missing",
	}
	pat, ok := p.compile(t.pattern); if !ok {
		result.status = "no_pattern"; return result
	}; defer p.destroy(pat)
	b := slice_bytes(im)
	for sec in im.sections {
		if !sec.executable || sec.size < u64(len(pat.bytes)) {
			continue
		}
		for off := sec.offset; off <= sec.offset + sec.size - u64(len(pat.bytes)); off += 4 {
			matches := true
			for c, i in pat.bytes {
				if !pat.wildcard[i] && c != b[off + u64(i)] {
					matches = false; break
				}
			}
			if !matches {
				continue
			}
			m := Match {
				address     = sec.address + off - sec.offset,
				file_offset = im.slice_offset + off,
			}
			if m.address >= im.text_address {
				m.text_offset = m.address - im.text_address
			}
			if t.global && span(b, off, 8) {
				m.reference, m.reference_valid = p.decode_adrp_add(
					u32le(b, off),
					u32le(b, off + 4),
					m.address,
				)
			}
			append(&result.matches, m)
		}
	}
	if len(result.matches) > 1 {
		result.status = "ambiguous"
	} else if len(result.matches) == 1 {
		m := result.matches[0]
		result.status = "moved"
		if m.text_offset >= t.hint && m.text_offset - t.hint < 0x1286a0 {
			result.status = "matched"
		}
		if t.global && !m.reference_valid {
			result.status = "invalid_global_reference"
		}
	}
	return result
}
scan :: proc(bundle: Bundle, profile: string) -> (Scan_Report, string) {
	v, ok := parse_version(profile); if !ok {
		return {}, "invalid profile version"
	}
	when ODIN_ARCH != .arm64 { return {}, "build this first-release scanner for Apple silicon" }
	if !scan_profile_available(v) {
		return {},
			"no pattern profile for this OS; specify a known --profile, such as 15.6 or 26.6"
	}
	r := Scan_Report {
		schema      = 1,
		manifest    = bundle.manifest,
		profile     = profile,
		static_only = true,
	}
	for t in targets_for(v) { append(&r.targets, scan_target(bundle.image, t)) }
	return r, ""
}
// Offline profiles can precede runtime validation on the target OS.
scan_profile_available :: proc(v: p.Version) -> bool {
	return p.supported(v) || v == (p.Version{27, 0, 1})
}
choose_profile :: proc(bundle: Bundle, requested: string) -> string {
	if requested != "" {
		return requested
	}
	if v, ok := parse_version(bundle.manifest.os_version); ok && scan_profile_available(v) {
		return bundle.manifest.os_version
	}
	return "26.6"
}
print_scan :: proc(r: Scan_Report) {
	fmt.printf(
		"Static scan: %s %s (%s), profile %s\n",
		r.manifest.os_version,
		r.manifest.build,
		r.manifest.architecture,
		r.profile,
	)
	for t in r.targets {
		fmt.printf("%-20s %-26s %d match(es)\n", t.name, t.status, len(t.matches))
		for m in t.matches { fmt.printf("  VA=0x%x file=0x%x text+0x%x\n", m.address, m.file_offset, m.text_offset) }
	}
	fmt.println("Pattern matches do not certify injection or operation behavior.")
}
// Mask relocation-sensitive operands while retaining opcode and register evidence.
// This is intentionally a bounded similarity heuristic, not semantic equivalence.
instruction_mask :: proc(w: u32) -> u32 {
	if w & 0x7c000000 == 0x14000000 {
		return 0xfc000000
	} 	// B/BL
	if w & 0x9f000000 == 0x90000000 || w & 0x9f000000 == 0x10000000 {
		return 0x9f00001f
	} 	// ADRP/ADR
	if w & 0xff000010 == 0x54000000 {
		return 0xff00001f
	} 	// B.cond
	if w & 0x7e000000 == 0x34000000 {
		return 0xff00001f
	} 	// CBZ/CBNZ
	if w & 0x7e000000 == 0x36000000 {
		return 0xfff8001f
	} 	// TBZ/TBNZ
	if w & 0x3b000000 == 0x18000000 {
		return 0xff00001f
	} 	// literal load
	if w & 0x7f000000 == 0x11000000 {
		return 0xffc003ff
	} 	// immediate ADD/SUB
	return 0xffffffff
}
Candidate :: struct {
	id, target, origin, evidence, pattern, disassembly: string,
	address, file_offset, text_offset: u64,
	score: f64,
	pattern_matches: int,
	references: [dynamic]string,
}
Comparison_Target :: struct {
	name, status, baseline_status: string,
	baseline_address: u64,
	baseline_disassembly: string,
	candidates: [dynamic]Candidate,
}
Analysis :: struct {
	schema: int,
	baseline, target: Manifest,
	profile: string,
	static_only: bool,
	pattern_source_sha256: string,
	target_path: string,
	targets: [dynamic]Comparison_Target,
}
PATTERN_SOURCE :: #load("../addition/patterns/patterns_arm64.odin")
reference_strings :: proc(im: Image, address: u64) -> [dynamic]string {
	refs := make([dynamic]string)
	off, ok := image_offset(im, address, 8); if !ok {
		return refs
	}
	b := slice_bytes(im)
	for i: u64 = 0; i < 64; i += 4 {
		if !span(b, off + i, 8) {
			break
		}
		va, valid := p.decode_adrp_add(u32le(b, off + i), u32le(b, off + i + 4), address + i)
		if !valid {
			continue
		}
		for sec in im.sections {
			if va < sec.address || va - sec.address >= sec.size {
				continue
			}
			at := sec.offset + va - sec.address; n := 0; valid_string := false
			for n < 160 && at + u64(n) < sec.offset + sec.size {
				c := b[at + u64(n)]
				if c == 0 {
					valid_string = n >= 4; break
				}
				if c < 32 || c > 126 {
					break
				}; n += 1
			}
			if valid_string {
				s := string(b[at:at + u64(n)]); exists := false; for r in refs {
					if r == s {
						exists = true
					}
				}; if !exists {
					append(&refs, s)
				}
			}
		}
	}
	return refs
}
similarity :: proc(a: Image, aa: u64, b: Image, ba: u64) -> f64 {
	ao, aok := image_offset(a, aa, 96); bo, bok := image_offset(b, ba, 96); if !aok || !bok {
		return 0
	}
	ab := slice_bytes(a); bb := slice_bytes(b); score := 0
	for i: u64 = 0; i < 96; i += 4 {
		x := u32le(ab, ao + i); y := u32le(bb, bo + i)
		if x & instruction_mask(x) == y & instruction_mask(y) {
			score += 1
		}
	}
	return f64(score) / 24
}
candidate_pattern :: proc(im: Image, address: u64) -> string {
	off, ok := image_offset(im, address, 64); if !ok {
		return ""
	}
	b := slice_bytes(im); out := strings.builder_make(context.allocator)
	for i: u64 = 0; i < 64; i += 4 {
		mask := instruction_mask(u32le(b, off + i))
		for j: u64 = 0; j < 4; j += 1 {
			if i + j != 0 {
				strings.write_string(&out, " ")
			}
			if (mask >> (j * 8)) & 255 == 255 {
				fmt.sbprintf(&out, "%02X", b[off + i + j])
			} else {
				strings.write_string(&out, "??")
			}
		}
	}
	return strings.to_string(out)
}
disassemble :: proc(bundle: Bundle, address: u64) -> string {
	parent_allocator := context.allocator
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.allocator = mem.dynamic_arena_allocator(&scratch)
	context.temp_allocator = context.allocator
	out, err := run(
		[]string {
			"/usr/bin/xcrun",
			"llvm-objdump",
			"--disassemble",
			fmt.tprintf("--arch=%s", bundle.image.architecture),
			fmt.tprintf("--start-address=0x%x", address),
			fmt.tprintf("--stop-address=0x%x", address + 128),
			bundle.path,
		},
	)
	if err != "" {
		return strings.clone(fmt.tprintf("Disassembly unavailable: %s", err), parent_allocator)
	}
	// Apple's Mach-O mode can ignore start/stop flags. Filter addresses ourselves
	// and release full subprocess output at this procedure's arena boundary.
	filtered := strings.builder_make(parent_allocator)
	count := 0
	for line in strings.split_lines_iterator(&out) {
		colon := strings.index(line, ":")
		if colon < 1 {continue}
		va, parsed := strconv.parse_u64(strings.trim_space(line[:colon]), 16)
		if !parsed || va < address || va - address >= 128 {continue}
		fmt.sbprintf(&filtered, "%s\n", line)
		count += 1
	}
	if count == 0 {return strings.clone("Disassembly unavailable: no instructions in the requested range", parent_allocator)}
	return strings.to_string(filtered)
}
insert_ranked :: proc(list: ^[dynamic]Candidate, c: Candidate) {
	if len(list^) == 5 && c.score <= list^[4].score {
		return
	}
	append(list, c)
	for i := len(list^) - 1;
	    i > 0 && list^[i].score > list^[i - 1].score;
	    i -= 1 { list^[i], list^[i - 1] = list^[i - 1], list^[i] }
	if len(list^) > 5 {
		resize(list, 5)
	}
}
compare :: proc(
	old, new: Bundle,
	profile: string,
	baseline_selections: []string = nil,
) -> (
	Analysis,
	string,
) {
	baseline, err := scan(old, profile); if err != "" {
		return {}, err
	}
	target, err2 := scan(new, profile); if err2 != "" {
		return {}, err2
	}
	a := Analysis {
		schema                = 1,
		baseline              = old.manifest,
		target                = new.manifest,
		profile               = profile,
		static_only           = true,
		pattern_source_sha256 = digest(transmute([]u8)PATTERN_SOURCE),
	}
	a.target_path, _ = filepath.abs(new.path)
	selections := make(map[string]u64)
	for selection in baseline_selections {
		parts := strings.split(selection, "=")
		if len(parts) != 2 {
			return {}, "baseline selection must be TARGET=0xADDRESS"
		}
		value := parts[1]; if strings.has_prefix(value, "0x") {
			value = value[2:]
		}
		address, ok := strconv.parse_u64(value, 16)
		if !ok || address == 0 {
			return {}, "invalid baseline address"
		}
		if _, exists := selections[parts[0]]; exists {
			return {}, "duplicate baseline target"
		}
		selections[parts[0]] = address
	}
	v, _ := parse_version(profile); defs := targets_for(v)
	for t, i in baseline.targets {
		fmt.eprintf("Comparing %s...\n", t.name)
		ct := Comparison_Target {
			name            = t.name,
			status          = target.targets[i].status,
			baseline_status = t.status,
		}
		base: Match; chosen := false
		if address, explicit := selections[t.name]; explicit {
			for m in t.matches {
				if m.address == address {
					base = m; chosen = true
				}
			}
			if !chosen {
				return {}, fmt.tprintf("baseline address for %s is not a known-pattern match", t.name)
			}
			delete_key(&selections, t.name)
			ct.baseline_status = "explicit_selection"
		} else if len(t.matches) == 1 {
			base = t.matches[0]; chosen = true
		}
		if !chosen || (defs[i].global && !base.reference_valid) {
			ct.status = "baseline_unresolved"; append(&a.targets, ct); continue
		}
		ct.baseline_address =
			base.address; ct.baseline_disassembly = disassemble(old, ct.baseline_address)
		old_refs := reference_strings(old.image, ct.baseline_address)
		if len(target.targets[i].matches) > 0 {
			for m in target.targets[i].matches {
				c := Candidate {
					target      = t.name,
					address     = m.address,
					file_offset = m.file_offset,
					text_offset = m.text_offset,
					origin      = "known_pattern",
					score       = similarity(old.image, ct.baseline_address, new.image, m.address),
					pattern     = t.pattern,
					evidence    = "Known instruction pattern; identity and ABI still require review.",
				}
				insert_ranked(&ct.candidates, c)
			}
		} else {
			addresses := make([dynamic]u64)
			b := slice_bytes(new.image)
			if defs[i].global || t.name == "animation_time" {
				for sec in new.image.sections {
					if !sec.executable || sec.size < 96 {
						continue
					}
					for off := sec.offset; off + 96 <= sec.offset + sec.size; off += 4 {
						w := u32le(b, off)
						if defs[i].global && w & 0x9f000000 != 0x90000000 {
							continue
						}
						if !defs[i].global &&
						   w & instruction_mask(w) !=
							   u32le(
								   slice_bytes(old.image),
								   base.file_offset - old.image.slice_offset,
							   ) &
								   instruction_mask(
									   u32le(
										   slice_bytes(old.image),
										   base.file_offset - old.image.slice_offset,
									   ),
								   ) {
							continue
						}
						append(&addresses, sec.address + off - sec.offset)
					}
				}
			} else {
				if len(new.image.functions) > 0 {
					append(&addresses, ..new.image.functions[:])
				} else {
					for sec in new.image.sections {
						if !sec.executable || sec.size < 96 {
							continue
						}
						for off := sec.offset; off + 96 <= sec.offset + sec.size; off += 4 {
							w := u32le(b, off); if w == 0xd503237f || w == 0xd503233f {
								append(&addresses, sec.address + off - sec.offset)
							}
						}
					}
				}
			}
			for address in addresses {
				score := similarity(old.image, ct.baseline_address, new.image, address)
				if score < 0.60 {
					continue
				}
				off, valid := image_offset(new.image, address, 96); if !valid {
					continue
				}
				if defs[i].global {
					if _, ok := p.decode_adrp_add(u32le(b, off), u32le(b, off + 4), address); !ok {
						continue
					}
				}
				refs := reference_strings(new.image, address); shared := 0
				for r in refs {
					for old_reference in old_refs {
						if r == old_reference {
							shared += 1; break
						}
					}
				}
				c := Candidate {
					target      = t.name,
					address     = address,
					file_offset = new.image.slice_offset + off,
					text_offset = address - new.image.text_address,
					origin      = "structural_similarity",
					score       = min(1.0, score + min(f64(shared) * 0.025, 0.1)),
					references  = refs,
					evidence    = fmt.tprintf(
						"24-instruction normalized similarity %.3f; %d shared decoded string reference(s). Heuristic candidate, not a verified target.",
						score,
						shared,
					),
				}
				insert_ranked(&ct.candidates, c)
			}
		}
		for &c, j in ct.candidates {
			c.id = fmt.tprintf("candidate-%d", j + 1)
			if c.pattern == "" {
				c.pattern = candidate_pattern(new.image, c.address)
			}
			result := scan_target(new.image, Target{pattern = c.pattern})
			if len(result.matches) > 1 && c.origin == "known_pattern" {
				c.pattern = candidate_pattern(new.image, c.address)
				result = scan_target(new.image, Target{pattern = c.pattern})
			}
			c.pattern_matches = len(result.matches)
			c.disassembly = disassemble(new, c.address)
			if len(c.references) == 0 {
				c.references = reference_strings(new.image, c.address)
			}
		}
		append(&a.targets, ct)
	}
	if len(selections) > 0 {
		return {}, "unknown baseline selection target"
	}
	return a, ""
}
write_analysis :: proc(a: Analysis, out: string) -> string {
	if os.exists(out) {
		return "analysis output already exists; choose a fresh directory"
	}
	if err := mkdir(out); err != "" {
		return err
	}
	if err := write_json(join(out, "analysis.json"), a); err != "" {
		return err
	}
	if err := write_text(join(out, "patterns_arm64.odin"), string(PATTERN_SOURCE)); err != "" {
		return err
	}
	b := strings.builder_make(context.allocator)
	fmt.sbprintf(
		&b,
		"# Dock comparison\n\nBaseline: %s %s (%s)\n\nTarget: %s %s (%s)\n\nProfile: %s. Static evidence only; injection compatibility is unverified.\n",
		a.baseline.os_version,
		a.baseline.build,
		a.baseline.sha256,
		a.target.os_version,
		a.target.build,
		a.target.sha256,
		a.profile,
	)
	for t in a.targets {
		fmt.sbprintf(
			&b,
			"\n## %s\n\nStatus: %s; baseline: %s\n\n",
			t.name,
			t.status,
			t.baseline_status,
		)
		if t.baseline_disassembly != "" {
			fmt.sbprintf(
				&b,
				"Baseline at `0x%x`:\n\n```text\n%s\n```\n",
				t.baseline_address,
				t.baseline_disassembly,
			)
		}
		if len(t.candidates) == 0 {
			strings.write_string(&b, "Unresolved: no sufficiently similar candidate found.\n")
		}
		for c in t.candidates { fmt.sbprintf(&b, "\n### %s\n\nVA `0x%x`, file `0x%x`, text offset `0x%x`, score %.3f, pattern matches %d.\n\n%s\n\nReferences: %v\n\n```text\n%s\n```\n", c.id, c.address, c.file_offset, c.text_offset, c.score, c.pattern_matches, c.evidence, c.references, c.disassembly) }
	}
	return write_text(join(out, "report.md"), strings.to_string(b))
}
