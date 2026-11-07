package dockscan

import dock "../../../src/dock"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// Scanner regressions
// ------------------------------------------------------------------------

put32 :: proc(b: []u8, at: int, w: u32) { for j in 0 ..< 4 { b[at + j] = u8(w >> uint(j * 8)) } }
put64 :: proc(b: []u8, at: int, w: u64) { put32(b, at, u32(w)); put32(b, at + 4, u32(w >> 32)) }
fixture :: proc() -> []u8 {
	b := make([]u8, 0x400)
	put32(b, 0, 0xfeedfacf); put32(b, 4, 0x100000c); put32(b, 8, 2)
	put32(b, 12, 2); put32(b, 16, 2); put32(b, 20, 176)
	put32(b, 32, 0x19); put32(b, 36, 152); copy(b[40:56], "__TEXT")
	put64(b, 56, 0x100000000); put64(b, 64, 0x1000); put64(b, 72, 0); put64(b, 80, u64(len(b)))
	put32(b, 96, 1); copy(b[104:120], "__text"); copy(b[120:136], "__TEXT")
	put64(
		b,
		136,
		0x100000100,
	); put64(b, 144, 0x300); put32(b, 152, 0x100); put32(b, 168, 0x80000400)
	put32(b, 184, 0x1b); put32(b, 188, 24); for i in 0 ..< 16 { b[192 + i] = u8(i) }
	for i := 0x100; i + 4 <= len(b); i += 4 { put32(b, i, 0xd503201f) }
	return b
}
@(test)
image_parses_mapping_and_fat_architecture :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	b := fixture(); im, e := parse_image(b)
	testing.expect_value(t, e, ""); testing.expect_value(t, im.architecture, "arm64e")
	testing.expect_value(t, im.uuid, "000102030405060708090a0b0c0d0e0f")
	off, ok := image_offset(
		im,
		0x100000120,
		4,
	); testing.expect(t, ok); testing.expect_value(t, off, u64(0x120))
	fat := make([]u8, len(b) + 0x100)
	fat[0] = 0xca; fat[1] = 0xfe; fat[2] = 0xba; fat[3] = 0xbe; fat[7] = 1
	fat[8] = 1; fat[11] = 12; fat[15] = 2; fat[18] = 1; fat[22] = 4
	copy(fat[0x100:], b)
	universal, error := parse_image(fat)
	testing.expect_value(t, error, ""); testing.expect_value(t, universal.slice_offset, u64(0x100))
	m := scan_target(universal, Target{pattern = "1F 20 03 D5"})
	testing.expect_value(
		t,
		m.status,
		"ambiguous",
	); testing.expect_value(t, m.matches[0].file_offset, u64(0x200))
	testing.expect_value(t, m.matches[0].address, u64(0x100000100))
}
@(test)
image_rejects_truncation_and_bad_ranges :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	b := fixture()
	for n in 0 ..< 208 { _, e := parse_image(b[:n]); testing.expect(t, e != "") }
	put64(b, 80, max(u64)); _, e := parse_image(b); testing.expect(t, e != "")
	b = fixture(); put32(b, 36, 7); _, e = parse_image(b); testing.expect(t, e != "")
	b = fixture(); put64(b, 144, 0x1000); _, e = parse_image(b); testing.expect(t, e != "")
	b = fixture(); put32(b, 4, 0x1000007); _, e = parse_image(b); testing.expect(t, e != "")
}
@(test)
scanner_reports_missing_unique_and_ambiguity :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	b := fixture(

	); put32(b, 0x140, 0xd503237f); im, e := parse_image(b); testing.expect_value(t, e, "")
	one := scan_target(im, Target{pattern = "7F 23 03 D5", hint = 0x100})
	testing.expect_value(t, one.status, "matched"); testing.expect_value(t, len(one.matches), 1)
	put32(b, 0x180, 0xd503237f)
	two := scan_target(
		im,
		Target{pattern = "7F 23 03 D5"},
	); testing.expect_value(t, two.status, "ambiguous")
	missing := scan_target(
		im,
		Target{pattern = "FF FF FF FF"},
	); testing.expect_value(t, missing.status, "missing")
}
@(test)
normalization_masks_branches_not_other_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	b := fixture(); a, _ := parse_image(b); other := fixture(); c, _ := parse_image(other)
	put32(b, 0x140, 0x94000001); put32(other, 0x140, 0x94012345)
	testing.expect_value(t, similarity(a, 0x100000100, c, 0x100000100), f64(1))
	put32(other, 0x140, 0xd65f03c0)
	testing.expect(t, similarity(a, 0x100000100, c, 0x100000100) < 1)
}
@(test)
catalog_and_distribution_are_matched_by_build :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	catalog := `<?xml version="1.0"?><plist><dict><key>Products</key><dict><key>product-1</key><dict><key>Packages</key><array><dict><key>URL</key><string>https://swcdn.apple.com/content/InstallAssistant.pkg</string></dict></array><key>Distributions</key><dict><key>English</key><string>https://swdist.apple.com/product.dist</string></dict></dict></dict></dict></plist>`
	products, e := catalog_products(catalog, "https://swscan.apple.com/catalog")
	testing.expect_value(t, e, ""); if testing.expect_value(t, len(products), 1) {
		testing.expect_value(t, products[0].id, "product-1")
	}
	build, version, error := distribution_identity(
		`<installer-gui-script><auxinfo><dict><key>BUILD</key><string>26A434</string><key>VERSION</key><string>27.0.1</string></dict></auxinfo></installer-gui-script>`,
	)
	testing.expect_value(
		t,
		error,
		"",
	); testing.expect_value(t, build, "26A434"); testing.expect_value(t, version, "27.0.1")
	testing.expect(t, !apple_url("https://swcdn.apple.com.evil.example/package"))
	testing.expect(t, !apple_url("https://swcdn.apple.com@evil.example/package"))
	testing.expect(t, !apple_url("file:///etc/passwd"))
	testing.expect(t, apple_url("https://swcdn.apple.com/package"))
}
@(test)
snapshot_detects_tampered_binary :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-dock-test-*",
		context.allocator,
	); if !testing.expect_value(t, e, nil) {
		return
	}; defer os.remove_all(dir)
	file := join(
		dir,
		"source",
	); testing.expect_value(t, os.write_entire_file(file, fixture()), nil)
	out := join(dir, "snapshot"); testing.expect_value(t, snapshot(file, "15.6", "24G84", out), "")
	_, err := load_bundle(out); testing.expect_value(t, err, "")
	changed := fixture(

	); changed[0x100] = 1; testing.expect_value(t, os.write_entire_file(join(out, "Dock"), changed), nil)
	_, err = load_bundle(out); testing.expect(t, strings.contains(err, "digest mismatch"))
}
@(test)
proposal_requires_selection_and_binds_evidence_to_binary :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-dock-propose-test-*",
		context.allocator,
	); if !testing.expect_value(t, e, nil) {
		return
	}; defer os.remove_all(dir)
	source := join(dir, "Dock"); b := fixture(); put32(b, 0x140, 0xd503237f)
	testing.expect_value(t, os.write_entire_file(source, b), nil)
	bundle, err := load_bundle(source); testing.expect_value(t, err, "")
	pattern := candidate_pattern(bundle.image, 0x100000140)
	// A unique first instruction and 64-byte evidence window make this candidate
	// intentionally unique, while the surrounding fixture is repeated NOPs.
	r := scan_target(
		bundle.image,
		Target{pattern = pattern},
	); testing.expect_value(t, len(r.matches), 1)
	a := Analysis {
		schema                = 1,
		static_only           = true,
		target                = bundle.manifest,
		target_path           = source,
		pattern_source_sha256 = digest(PATTERN_SOURCE),
	}
	a.target.os_version = "27.0.1"; a.target.build = "26A434"
	append(
		&a.targets,
		Comparison_Target{name = "add_space", candidates = make([dynamic]Candidate)},
	)
	append(
		&a.targets[0].candidates,
		Candidate {
			id = "candidate-1",
			pattern = pattern,
			pattern_matches = 1,
			address = 0x100000140,
			text_offset = 0x140,
		},
	)
	evidence := join(dir, "analysis"); testing.expect_value(t, write_analysis(a, evidence), "")
	patch := join(dir, "proposal.patch")
	testing.expect(t, propose(evidence, nil, patch) != "")
	testing.expect_value(t, propose(evidence, []string{"add_space=candidate-1"}, patch), "")
	text, read_err := os.read_entire_file(
		patch,
		context.allocator,
	); testing.expect_value(t, read_err, nil)
	testing.expect(t, strings.contains(string(text), "os_version.major == 27"))
	testing.expect(t, !strings.contains(string(text), "supported ::"))
	changed := fixture(); testing.expect_value(t, os.write_entire_file(source, changed), nil)
	testing.expect(
		t,
		strings.contains(
			propose(evidence, []string{"add_space=candidate-1"}, join(dir, "stale.patch")),
			"changed since comparison",
		),
	)
}
@(test)
image_mutations_do_not_panic :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	// Vary structural header fields, including length/offset overflow, rather than
	// merely reproducing each parser branch with a hand-written assertion.
	seed: u32 = 0x12345678
	for _ in 0 ..< 500 {
		arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
		{
			context.allocator = mem.dynamic_arena_allocator(&arena)
			b := fixture()
			for _ in 0 ..< 4 { seed = seed * 1664525 + 1013904223; at := int(seed % 208); seed = seed * 1664525 + 1013904223; b[at] = u8(seed >> 24) }
			_, _ = parse_image(b)
		}
		mem.dynamic_arena_destroy(&arena)
	}
	testing.expect(t, true)
}

@(test)
comparison_ranks_changed_function_with_real_disassembly :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(
		&arena,
	); context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-dock-compare-test-*",
		context.allocator,
	); if !testing.expect_value(t, e, nil) {
		return
	}; defer os.remove_all(dir)
	v, _ := parse_version("15.6"); defs := targets_for(v)
	target := defs[2]; pattern, valid := dock.compile(target.pattern); if !testing.expect(t, valid) {
		return
	}
	old := fixture(); new := fixture()
	copy(old[0x140:], pattern.bytes); copy(new[0x240:], pattern.bytes)
	// Change the stack adjustment immediate: the literal pattern must disappear,
	// while instruction normalization still identifies the counterpart.
	new[0x245] = 0x83
	before := join(dir, "before"); after := join(dir, "after")
	testing.expect_value(
		t,
		os.write_entire_file(before, old),
		nil,
	); testing.expect_value(t, os.write_entire_file(after, new), nil)
	a, err := load_bundle(
		before,
	); testing.expect_value(t, err, ""); b, error := load_bundle(after); testing.expect_value(t, error, "")
	comparison, compare_err := compare(a, b, "15.6"); testing.expect_value(t, compare_err, "")
	found := false
	for result in comparison.targets {
		if result.name != "add_space" {
			continue
		}
		if !testing.expect(t, len(result.candidates) > 0) {
			continue
		}
		found = true
		c := result.candidates[0]
		testing.expect_value(t, c.origin, "structural_similarity")
		testing.expect_value(t, c.address, u64(0x100000240))
		testing.expect_value(t, c.pattern_matches, 1)
		testing.expect(t, !strings.contains(c.disassembly, "Disassembly unavailable"))
		testing.expect(t, strings.contains(c.disassembly, "100000240:"))
		testing.expect(t, !strings.contains(c.disassembly, "100000100:"))
	}
	testing.expect(t, found)
}

@(test)
extracted_root_checks_actual_build_before_snapshot :: proc(t: ^testing.T) {
 arena: mem.Dynamic_Arena
 mem.dynamic_arena_init(&arena)
 defer mem.dynamic_arena_destroy(&arena)
 context.allocator = mem.dynamic_arena_allocator(&arena)
 context.temp_allocator = context.allocator
 dir, e := os.make_directory_temp("", "shoji-dock-root-test-*", context.allocator)
 if !testing.expect_value(t, e, nil) {return}
 defer os.remove_all(dir)
 root := join(dir, "system")
 core := join(root, "System/Library/CoreServices")
 executable := join(core, "Dock.app/Contents/MacOS")
 testing.expect_value(t, mkdir(executable), "")
 testing.expect_value(t, os.write_entire_file(join(executable,"Dock"),fixture()),nil)
 plist := `<?xml version="1.0"?><plist version="1.0"><dict><key>ProductVersion</key><string>27.0.1</string><key>ProductBuildVersion</key><string>26A434</string></dict></plist>`
 testing.expect_value(t, write_text(join(core,"SystemVersion.plist"),plist),"")
 output:=join(dir,"snapshot")
 found,error:=find_os_root(root,"WRONG",output,{})
 testing.expect(t,!found && strings.contains(error,"does not match"))
 testing.expect(t,!os.exists(output))
 found,error=find_os_root(root,"26A434",output,{source_url="https://swcdn.apple.com/InstallAssistant.pkg"})
 testing.expect(t,found);testing.expect_value(t,error,"")
 bundle,err:=load_bundle(output);testing.expect_value(t,err,"")
 testing.expect_value(t,bundle.manifest.build,"26A434")
 testing.expect_value(t,bundle.manifest.metadata_source,"extracted_system_plist")
 resumed:=join(dir,"resumed")
 error=fetch("26A434",resumed,"","","",false,root)
 testing.expect_value(t,error,"")
 testing.expect(t,os.exists(join(resumed,"acquisition.log")))
 testing.expect(t,os.exists(join(root,"System/Library/CoreServices/SystemVersion.plist")))
}

@(test)
unreadable_container_reports_native_failure :: proc(t: ^testing.T) {
 arena:mem.Dynamic_Arena
 mem.dynamic_arena_init(&arena)
 defer mem.dynamic_arena_destroy(&arena)
 context.allocator=mem.dynamic_arena_allocator(&arena)
 context.temp_allocator=context.allocator
 root,e:=os.make_directory_temp("","shoji-dock-bad-image-*",context.allocator)
 if !testing.expect_value(t,e,nil) {return}
 defer os.remove_all(root)
 image:=join(root,"SharedSupport.dmg")
 testing.expect_value(t,write_text(image,"invalid disk image"),"")
 found,error:=find_os_root(root,"26A434",join(root,"snapshot"),{})
 testing.expect(t,!found)
 testing.expect(t,strings.contains(error,"could not inspect extracted containers"))
 testing.expect(t,strings.contains(error,image))
 testing.expect(t,strings.contains(error,"hdiutil"))
 testing.expect(t,os.exists(image))
}

@(test)
mobileasset_zip_extracts_only_required_files :: proc(t: ^testing.T) {
 arena:mem.Dynamic_Arena
 mem.dynamic_arena_init(&arena)
 defer mem.dynamic_arena_destroy(&arena)
 context.allocator=mem.dynamic_arena_allocator(&arena)
 context.temp_allocator=context.allocator
 dir,e:=os.make_directory_temp("","shoji-dock-zip-test-*",context.allocator)
 if !testing.expect_value(t,e,nil) {return}
 defer os.remove_all(dir)
 source:=join(dir,"source")
 core:=join(source,"System/Library/CoreServices")
 testing.expect_value(t,mkdir(join(core,"Dock.app/Contents/MacOS")),"")
 testing.expect_value(t,os.write_entire_file(join(core,"Dock.app/Contents/MacOS/Dock"),fixture()),nil)
 testing.expect_value(t,write_text(join(core,"SystemVersion.plist"),`<plist version="1.0"><dict><key>ProductVersion</key><string>27.0.1</string><key>ProductBuildVersion</key><string>26A434</string></dict></plist>`),"")
 stage:=join(dir,"stage")
 testing.expect_value(t,mkdir(join(stage,"AssetData/payloadv2")),"")
 _,error:=run([]string{"/usr/bin/aa","archive","-d",source,"-o",join(stage,"AssetData/payloadv2/payload.000"),"-a","lzfse"})
 testing.expect_value(t,error,"")
 containers:=join(dir,"containers")
 testing.expect_value(t,mkdir(containers),"")
 archive:=join(containers,"asset.zip")
 _,error=run([]string{"/usr/bin/bsdtar","-acf",archive,"-C",stage,"AssetData"})
 testing.expect_value(t,error,"")
 found:bool
 found,error=find_os_root(containers,"26A434",join(dir,"snapshot"),{})
 testing.expect_value(t,error,"")
 testing.expect(t,found)
 testing.expect(t,os.exists(join(dir,"snapshot/Dock")))
 testing.expect_value(t,write_text(join(stage,"AssetData/payloadv2/payload.000"),"pbzm invalid test payload"),"")
 _,error=run([]string{"/usr/bin/bsdtar","-acf",archive,"-C",stage,"AssetData"})
 testing.expect_value(t,error,"")
 found,error=find_os_root(containers,"26A434",join(dir,"unsupported"),{})
 testing.expect(t,!found)
 testing.expect(t,strings.contains(error,"pbzm"))
 testing.expect(t,!os.exists(join(dir,"unsupported")))
 for path in ([]string{"AssetData/payloadv2/payload.000","AssetData/payloadv2/payload.027"}) {testing.expect(t,mobileasset_payload(path))}
 for path in ([]string{"../AssetData/payloadv2/payload.000","AssetData/payloadv2/payload.000.ecc","AssetData/payloadv2/payload.abc","AssetData/payloadv2/payload.000/../../x"}) {testing.expect(t,!mobileasset_payload(path))}
}

@(test)
macos27_static_profile_keeps_runtime_gate_explicit :: proc(t: ^testing.T) {
 arena:mem.Dynamic_Arena
 mem.dynamic_arena_init(&arena)
 defer mem.dynamic_arena_destroy(&arena)
 context.allocator=mem.dynamic_arena_allocator(&arena)
 context.temp_allocator=context.allocator
 version:=dock.Version{27,0,1}
 testing.expect(t,scan_profile_available(version))
 testing.expect_value(t,dock.supported(version),dock.MACOS27_CANDIDATE)
 testing.expect(t,!dock.supported({27,2,0}))
 testing.expect(t,!scan_profile_available({27,2,0}))
 testing.expect_value(t,choose_profile(Bundle{manifest=Manifest{os_version="27.0.1"}},""),"27.0.1")
 definitions:=targets_for(version)
 testing.expect_value(t,len(definitions),7)
 for target in definitions {
  testing.expect(t,target.pattern!="")
  testing.expect(t,target.hint>0)
 }
}

@(test)
progress_line_stays_on_one_terminal_row :: proc(t: ^testing.T) {
 arena: mem.Dynamic_Arena
 mem.dynamic_arena_init(&arena)
 defer mem.dynamic_arena_destroy(&arena)
 context.allocator=mem.dynamic_arena_allocator(&arena)
 context.temp_allocator=context.allocator
 a:=progress_line("Downloading macOS installer","",0,65,2*1024*1024*1024,80)
 b:=progress_line("Downloading macOS installer","",1,65,2*1024*1024*1024,80)
 testing.expect(t,a!=b)
 testing.expect(t,strings.contains(a,"2.00 GiB"))
 testing.expect(t,strings.contains(a,"1:05"))
 testing.expect(t,!strings.contains(a,"\n"))
 for width in ([]int{0,1,8,20,80}) {
  line:=progress_line("Finding requested macOS build","19/19",3,1,-1,width)
  testing.expect(t,len(line)<=max(0,width-1))
 }
}

@(test)
progress_captures_output_and_retains_native_errors :: proc(t: ^testing.T) {
 arena: mem.Dynamic_Arena
 mem.dynamic_arena_init(&arena)
 defer mem.dynamic_arena_destroy(&arena)
 context.allocator=mem.dynamic_arena_allocator(&arena)
 context.temp_allocator=context.allocator
 work,err:=os.make_directory_temp("","shoji-dock-progress-test-*",context.allocator)
 if !testing.expect_value(t,err,nil) {return}
 defer os.remove_all(work)
 p,error:=progress_open(work,true)
 if !testing.expect_value(t,error,"") {return}
 defer progress_close(&p)
 // Force animation even in CI, capturing the terminal control sequences separately.
 terminal,terminal_error:=os.create_temp_file(work,"terminal-*")
 if !testing.expect_value(t,terminal_error,nil) {return}
 defer os.close(terminal)
 p.interactive=true
 p.output=terminal
 progress_stage(&p,"Testing subprocess")
 out,run_error:=run_progress([]string{"/bin/sh","-c","sleep 0.3; /usr/bin/seq 1 10000"},&p)
 testing.expect_value(t,run_error,"")
 testing.expect(t,strings.has_prefix(out,"1\n"))
 testing.expect(t,strings.has_suffix(out,"10000\n"))
 _,run_error=run_progress([]string{"/bin/sh","-c","printf 'native failure' >&2; exit 7"},&p)
 testing.expect(t,strings.contains(run_error,"failed (7)"))
 testing.expect(t,strings.contains(run_error,"native failure"))
 progress_close(&p)
 log,read_error:=os.read_entire_file(p.log_path,context.allocator)
 testing.expect_value(t,read_error,nil)
 testing.expect(t,strings.contains(string(log),"native failure"))
 testing.expect(t,!strings.contains(string(log),"\x1b["))
 _,_=os.seek(terminal,0,.Start)
 rendered,render_error:=os.read_entire_file(terminal,context.allocator)
 testing.expect_value(t,render_error,nil)
 testing.expect(t,strings.contains(string(rendered),"| Testing subprocess"))
 testing.expect(t,strings.contains(string(rendered),"/ Testing subprocess"))
 testing.expect(t,strings.has_suffix(string(rendered),"\r\x1b[2K"))
}

// PBZM regressions
// ------------------------------------------------------------------------

pbzm_bytes :: proc(s: string) -> []u8 { return transmute([]u8)s }

pbzm_append64 :: proc(bytes: ^[dynamic]u8, value: u64) {
	for shift := 56;
	    shift >= 0;
	    shift -= 8 { append(bytes, u8(value >> uint(shift))) }
}
pbzm_fixture :: proc(
	payload: []u8,
	decoded_size: u64,
	nominal: u64 = 8192,
) -> []u8 {
	bytes := make([dynamic]u8)
	append(&bytes, ..pbzm_bytes("pbzm"))
	pbzm_append64(&bytes, nominal)
	pbzm_append64(&bytes, decoded_size)
	pbzm_append64(&bytes, u64(len(payload)))
	append(&bytes, ..payload)
	return bytes[:]
}

@(test)
pbzm_decodes_upstream_raven_and_stored_chunks :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-pbzm-test-*",
		context.allocator,
	)
	if !testing.expect_value(t, e, nil) {
		return
	}
	defer os.remove_all(dir)
	encoded := transmute([]u8)#load(
		"testdata/zeros_4k.rav",
	)
	bytes := make([dynamic]u8)
	append(&bytes, ..pbzm_fixture(encoded, 4096))
	pbzm_append64(&bytes, 3); pbzm_append64(&bytes, 3)
	append(&bytes, ..pbzm_bytes("end"))
	source := join(dir, "payload")
	output := join(dir, "decoded")
	testing.expect_value(t, os.write_entire_file(source, bytes[:]), nil)
	testing.expect_value(t, decode_pbzm(source, output), "")
	actual, read_error := os.read_entire_file(output, context.allocator)
	testing.expect_value(t, read_error, nil)
	if testing.expect_value(t, len(actual), 4099) {
		for b in actual[:4096] { testing.expect_value(t, b, u8(0)) }
		testing.expect_value(t, string(actual[4096:]), "end")
	}
	// Existing output is never overwritten.
	testing.expect(
		t,
		strings.contains(decode_pbzm(source, output), "cannot create"),
	)
}

@(test)
pbzm_rejects_truncation_sizes_and_corrupt_codec :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-pbzm-reject-*",
		context.allocator,
	)
	if !testing.expect_value(t, e, nil) {
		return
	}
	defer os.remove_all(dir)
	source := join(dir, "payload")
	output := join(dir, "decoded")
	valid := pbzm_fixture(pbzm_bytes("stored"), 6)
	for size in 0 ..< len(valid) {
		testing.expect_value(
			t,
			os.write_entire_file(source, valid[:size]),
			nil,
		)
		testing.expect(t, decode_pbzm(source, output) != "")
		testing.expect(t, !os.exists(output))
	}
	for bad in ([]([]u8) {
			pbzm_fixture(pbzm_bytes("bad"), 4096),
			pbzm_fixture(pbzm_bytes("x"), 1, PBZM_BLOCK_LIMIT + 1),
			pbzm_fixture(pbzm_bytes("x"), 0),
			pbzm_fixture(pbzm_bytes("x"), 9000),
		}) {
		testing.expect_value(t, os.write_entire_file(source, bad), nil)
		testing.expect(t, decode_pbzm(source, output) != "")
		testing.expect(t, !os.exists(output))
	}
}
