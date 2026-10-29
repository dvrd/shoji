package dockscan

import "core:crypto/sha2"
import "core:fmt"
import "core:strings"
import p "../../../src/dock"
import "core:os"
import "core:path/filepath"
import "core:mem"
import "core:strconv"
import "core:encoding/json"

// Mach-O image parsing
// ------------------------------------------------------------------------

Section :: struct {
	name: string,
	address, offset, size: u64,
	executable: bool,
}
Image :: struct {
	bytes: []u8,
	slice_offset, slice_size, text_address, text_offset, text_size: u64,
	architecture, uuid: string,
	sections: [dynamic]Section,
	functions: [dynamic]u64,
}
span :: proc(b: []u8, at, size: u64) -> bool {
	return at <= u64(len(b)) && size <= u64(len(b)) - at
}
u32le :: proc(b: []u8, i: u64) -> u32 {
	return u32(b[i]) | u32(b[i + 1]) << 8 | u32(b[i + 2]) << 16 | u32(b[i + 3]) << 24
}
u32be :: proc(b: []u8, i: u64) -> u32 {
	return u32(b[i]) << 24 | u32(b[i + 1]) << 16 | u32(b[i + 2]) << 8 | u32(b[i + 3])
}
u64le :: proc(b: []u8, i: u64) -> u64 { return u64(u32le(b, i)) | u64(u32le(b, i + 4)) << 32 }
u64be :: proc(b: []u8, i: u64) -> u64 { return u64(u32be(b, i)) << 32 | u64(u32be(b, i + 4)) }
hex_bytes :: proc(b: []u8) -> string {
	s := strings.builder_make(context.allocator)
	for c in b { fmt.sbprintf(&s, "%02x", c) }
	return strings.to_string(s)
}
digest :: proc(b: []u8) -> string {
	c: sha2.Context_256; sha2.init_256(&c); sha2.update(&c, b)
	d: [32]u8; sha2.final(&c, d[:]); return hex_bytes(d[:])
}
fixed_name :: proc(b: []u8) -> string {
	n := 0; for n < len(b) && b[n] != 0 { n += 1 }; return string(b[:n])
}
// File offsets are relative to the selected slice; virtual addresses are unslid.
parse_image :: proc(data: []u8) -> (im: Image, err: string) {
	if len(data) < 32 {
		return {}, "truncated Mach-O header"
	}
	im.bytes = data; im.slice_size = u64(len(data))
	magic := u32be(data, 0)
	if magic == 0xcafebabe || magic == 0xcafebabf {
		count := u32be(data, 4); stride: u64 = 20; if magic == 0xcafebabf {
			stride = 32
		}
		if count == 0 || count > 128 || !span(data, 8, u64(count) * stride) {
			return {}, "invalid universal architecture table"
		}
		chosen := false; preferred := false
		for i: u64 = 0; i < u64(count); i += 1 {
			at := 8 + i * stride
			if u32be(data, at) != 0x100000c {
				continue
			}
			subtype := u32be(data, at + 4) & 0xffffff
			off, sz: u64
			if stride == 20 {
				off = u64(u32be(data, at + 8)); sz = u64(u32be(data, at + 12))
			} else {
				off = u64be(data, at + 8); sz = u64be(data, at + 16)
			}
			if !span(data, off, sz) || sz < 32 {
				return {}, "invalid universal slice range"
			}
			if !chosen || (!preferred && subtype == 2) {
				im.slice_offset = off; im.slice_size = sz; chosen = true; preferred = subtype == 2
			}
		}
		if !chosen {
			return {}, "no Apple silicon slice; Intel analysis is not supported"
		}
	}
	b := data[im.slice_offset:im.slice_offset + im.slice_size]
	if !span(b, 0, 32) || u32le(b, 0) != 0xfeedfacf || u32le(b, 4) != 0x100000c {
		return {}, "expected little-endian 64-bit Apple silicon Mach-O"
	}
	subtype := u32le(b, 8) & 0xffffff
	if subtype != 0 && subtype != 2 {
		return {}, fmt.tprintf("unsupported arm64 CPU subtype %d", subtype)
	}
	im.architecture = subtype == 2 ? "arm64e" : "arm64"
	ncmds := u32le(b, 16); cmdsize := u64(u32le(b, 20))
	if ncmds > 65536 || !span(b, 32, cmdsize) {
		return {}, "invalid load-command range"
	}
	stop := 32 + cmdsize; at: u64 = 32; starts_off, starts_size: u64
	text_found := false
	for _ in 0 ..< int(ncmds) {
		if at > stop || stop - at < 8 {
			return {}, "truncated load command"
		}
		cmd := u32le(b, at); sz := u64(u32le(b, at + 4))
		if sz < 8 || sz > stop - at {
			return {}, "invalid load-command size"
		}
		switch cmd {
		case 0x19:
			if sz < 72 {
				return {}, "truncated segment"
			}
			name := fixed_name(b[at + 8:at + 24]); fo := u64le(b, at + 40); fs := u64le(b, at + 48)
			if !span(b, fo, fs) {
				return {}, "segment extends beyond slice"
			}
			if name == "__TEXT" {
				im.text_address = u64le(b, at + 24); im.text_offset = fo; im.text_size = fs
				text_found = true
			}
			n := u64(u32le(b, at + 64)); if n > (sz - 72) / 80 {
				return {}, "truncated section table"
			}
			for i: u64 = 0; i < n; i += 1 {
				s := at + 72 + i * 80; flags := u32le(b, s + 64); kind := flags & 0xff
				sec := Section {
					name       = fixed_name(b[s:s + 16]),
					address    = u64le(b, s + 32),
					offset     = u64(u32le(b, s + 48)),
					size       = u64le(b, s + 40),
					executable = flags & 0x80000400 != 0,
				}
				if kind != 1 && kind != 0xc && kind != 0x12 && !span(b, sec.offset, sec.size) {
					return {}, "section extends beyond slice"
				}
				if kind != 1 && kind != 0xc && kind != 0x12 {
					append(&im.sections, sec)
				}
			}
		case 0x1b:
			if sz < 24 {
				return {}, "truncated UUID"
			}; im.uuid = hex_bytes(b[at + 8:at + 24])
		case 0x26:
			if sz < 16 {
				return {}, "truncated function starts"
			}; starts_off = u64(u32le(b, at + 8)); starts_size = u64(u32le(b, at + 12))
		}
		at += sz
	}
	if at != stop || !text_found || im.text_size == 0 {
		return {}, "invalid commands or missing __TEXT segment"
	}
	if !span(b, starts_off, starts_size) {
		return {}, "invalid function starts range"
	}
	if starts_size > 0 {
		address := im.text_address; cursor := starts_off; end := cursor + starts_size
		for cursor < end {
			delta: u64; shift: uint; done := false
			for cursor < end && shift <= 63 {
				c := b[cursor]; cursor += 1
				if shift == 63 && c & 0x7e != 0 {
					return {}, "function delta overflow"
				}
				delta |= u64(c & 0x7f) << shift
				if c & 0x80 == 0 {
					done = true; break
				}; shift += 7
			}
			if !done {
				return {}, "unterminated function delta"
			}
			if delta == 0 {
				break
			}
			if delta > max(u64) - address {
				return {}, "function address overflow"
			}
			address += delta
			if _, ok := image_offset(im, address, 4); !ok {
				return {}, "function start is outside executable code"
			}
			append(&im.functions, address)
		}
	}
	return im, ""
}
image_offset :: proc(im: Image, address, size: u64) -> (u64, bool) {
	for s in im.sections {
		if s.executable &&
		   address >= s.address &&
		   address - s.address <= s.size &&
		   size <= s.size - (address - s.address) {
			return s.offset + address - s.address, true
		}
	}
	return 0, false
}
slice_bytes :: proc(im: Image) -> []u8 {
	return im.bytes[im.slice_offset:im.slice_offset + im.slice_size]
}

// Compatibility analysis
// ------------------------------------------------------------------------

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
PATTERN_SOURCE :: #load("../../../src/dock/patterns_arm64.odin")
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

// Patch proposals
// ------------------------------------------------------------------------

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
	checkout_source := "src/dock/patterns_arm64.odin"
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
				"a/src/dock/patterns_arm64.odin",
				"-L",
				"b/src/dock/patterns_arm64.odin",
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

// Evidence serialization
// ------------------------------------------------------------------------

run :: proc(args: []string, dir: string = "") -> (string, string) {
	state, out, stderr, e := os.process_exec(
		os.Process_Desc{command = args, working_dir = dir},
		context.allocator,
	)
	if e != nil || !state.success {
		return string(
			out,
		), fmt.tprintf("%s failed (%d): %s %v", args[0], state.exit_code, string(stderr), e)
	}
	return string(out), ""
}
join :: proc(a, b: string) -> string { p, _ := filepath.join([]string{a, b}); return p }
mkdir :: proc(path: string) -> string {
	e := os.make_directory_all(path); if e != nil && e != .Exist {
		return fmt.tprintf("cannot create %s: %v", path, e)
	}; return ""
}
write_text :: proc(path, text: string) -> string {
	if e := os.write_entire_file(path, text); e != nil {
		return fmt.tprintf("cannot write %s: %v", path, e)
	}; return ""
}
write_json :: proc(path: string, value: any) -> string {
	b, e := json.marshal(value, json.Marshal_Options{pretty = true}); if e != nil {
		return fmt.tprintf("JSON encoding failed: %v", e)
	}
	return write_text(path, string(b))
}
read_json :: proc(path: string, value: ^$T) -> string {
	b, e := os.read_entire_file(path, context.allocator); if e != nil {
		return fmt.tprintf("cannot read %s: %v", path, e)
	}
	if err := json.unmarshal(b, value, .JSON); err != nil {
		return fmt.tprintf("invalid JSON in %s: %v", path, err)
	}; return ""
}
Manifest :: struct {
	schema: int,
	os_version, build, sha256, uuid, architecture, source_url, source_sha256, product_id, catalog_url: string,
	binary: string,
	metadata_source: string,
}
Bundle :: struct {
	manifest: Manifest,
	image: Image,
	path: string,
}
load_bundle :: proc(path: string) -> (Bundle, string) {
	manifest: Manifest
	file := path
	if info, e := os.stat(path, context.allocator); e == nil && info.type == .Directory {
		if err := read_json(join(path, "manifest.json"), &manifest); err != "" {
			return {}, err
		}
		if manifest.schema != 1 || manifest.binary != "Dock" {
			return {}, "unsupported snapshot manifest"
		}
		file = join(path, "Dock")
	}
	b, e := os.read_entire_file(file, context.allocator); if e != nil {
		return {}, fmt.tprintf("cannot read %s: %v", file, e)
	}
	im, err := parse_image(b); if err != "" {
		return {}, err
	}
	sum := digest(b)
	if manifest.sha256 != "" && manifest.sha256 != sum {
		return {}, "snapshot digest mismatch"
	}
	if manifest.uuid != "" && manifest.uuid != im.uuid {
		return {}, "snapshot UUID mismatch"
	}
	manifest.sha256 = sum; manifest.uuid = im.uuid; manifest.architecture = im.architecture
	return Bundle{manifest, im, file}, ""
}
plist_field :: proc(path, key: string) -> (string, string) {
	out, err := run([]string{"/usr/bin/plutil", "-extract", key, "raw", "-o", "-", path})
	return strings.trim_space(out), err
}
snapshot :: proc(binary, version, build, out: string, origin: Manifest = {}) -> string {
	if os.exists(out) {
		return "output already exists; choose a fresh directory"
	}
	bundle, err := load_bundle(binary); if err != "" {
		return err
	}
	if version == "" || build == "" {
		return "snapshot requires OS version and build metadata"
	}
	if _, ok := parse_version(version); !ok {
		return "invalid OS version"
	}
	if err = mkdir(out); err != "" {
		return err
	}
	if e := os.write_entire_file(join(out, "Dock"), bundle.image.bytes); e != nil {
		return fmt.tprintf("cannot copy Dock: %v", e)
	}
	m := bundle.manifest; m.schema = 1; m.os_version = version; m.build = build; m.binary = "Dock"
	m.source_url = origin.source_url
	m.source_sha256 = origin.source_sha256
	m.product_id = origin.product_id
	m.catalog_url = origin.catalog_url
	m.metadata_source = origin.metadata_source
	if m.metadata_source == "" {m.metadata_source = "user_supplied"}
	if err = write_json(join(out, "manifest.json"), m); err != "" {
		return err
	}
	fmt.printf("Snapshot: %s (%s %s, %s)\n", out, version, build, m.architecture)
	return ""
}
