package dockscan

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
