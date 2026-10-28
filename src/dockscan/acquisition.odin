package dockscan

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "base:runtime"
import "core:mem"
import "core:sys/posix"
import "core:time"

foreign import raven "../../bin/libshoji-raven.a"
foreign import progress_libc "system:c"

// Apple installer acquisition
// ------------------------------------------------------------------------

DEFAULT_CATALOG :: "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"
Apple_Product :: struct {
	id, url, distribution, build, version, catalog: string,
}
apple_url :: proc(url: string) -> bool {
	if !strings.has_prefix(url, "https://") {
		return false
	}
	rest := url[8:]; end := strings.index(rest, "/"); if end < 0 {
		end = len(rest)
	}
	host := rest[:end]
	return host == "apple.com" || strings.has_suffix(host, ".apple.com")
}
secure_url :: proc(url: string) -> string {
	if strings.has_prefix(url, "http://") {
		return fmt.tprintf("https://%s", url[7:])
	}; return url
}
download :: proc(url, path: string, progress: ^Progress = nil) -> string {
	if !apple_url(url) {
		return "download URL must be HTTPS on an Apple-owned host"
	}
	if progress != nil {
		progress.file = path
	}
	defer {
		if progress != nil {
			progress.file = ""
		}
	}
	// No shell interpolation, credentials, cookies, installer execution or sudo.
	// Redirects remain HTTPS; final Apple origin is independently checked below.
	effective, err := run_progress(
		[]string {
			"/usr/bin/curl",
			"--fail",
			"--silent",
			"--show-error",
			"--location",
			"--max-redirs",
			"5",
			"--proto",
			"=https",
			"--proto-redir",
			"=https",
			"--connect-timeout",
			"15",
			"--max-time",
			"3600",
			"--retry",
			"2",
			"--output",
			path,
			"--write-out",
			"%{url_effective}",
			url,
		},
		progress,
	)
	if err != "" {
		return err
	}
	if !apple_url(strings.trim_space(effective)) {
		_ = os.remove(path); return "download redirected outside Apple hosts"
	}
	return ""
}
xml_children :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
) -> [dynamic]xml.Element_ID {
	result := make([dynamic]xml.Element_ID)
	for v in doc.elements[id].value {
		if c, ok := v.(xml.Element_ID); ok {
			append(&result, c)
		}
	}
	return result
}
xml_text :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	b := strings.builder_make(context.allocator)
	for v in doc.elements[id].value {
		if s, ok := v.(string); ok {
			strings.write_string(&b, s)
		}
	}
	return strings.to_string(b)
}
xml_field :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	key: string,
) -> (
	xml.Element_ID,
	bool,
) {
	children := xml_children(doc, id)
	for i := 0; i + 1 < len(children); i += 2 {
		if doc.elements[children[i]].ident == "key" &&
		   xml_text(doc, children[i]) == key {
			return children[i + 1], true
		}
	}
	return 0, false
}
field_text :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	key: string,
) -> string {
	if child, ok := xml_field(doc, id, key); ok {
		return xml_text(doc, child)
	}; return ""
}
parse_xml :: proc(data: string) -> (^xml.Document, string) {
	doc, e := xml.parse(
		data,
		xml.Options{flags = {.Ignore_Unsupported, .Decode_SGML_Entities}},
	)
	if e != .None {
		return nil, fmt.tprintf("invalid Apple XML: %v", e)
	}; return doc, ""
}
catalog_products :: proc(data, catalog: string) -> ([]Apple_Product, string) {
	doc, err := parse_xml(data); if err != "" {
		return nil, err
	}
	defer xml.destroy(doc)
	products: xml.Element_ID; found := false
	for el, i in doc.elements {
		if el.ident == "dict" {
			if id, ok := xml_field(doc, xml.Element_ID(i), "Products"); ok {
				products = id; found = true; break
			}
		}
	}
	if !found {
		return nil, "catalog has no Products dictionary"
	}
	pairs := xml_children(doc, products)
	result := make([dynamic]Apple_Product)
	for i := 0; i + 1 < len(pairs); i += 2 {
		id := strings.clone(xml_text(doc, pairs[i])); value := pairs[i + 1]
		packages, ok := xml_field(doc, value, "Packages"); if !ok {
			continue
		}
		url: string
		for pkg in xml_children(doc, packages) {
			s := field_text(doc, pkg, "URL")
			if strings.has_suffix(s, "/InstallAssistant.pkg") {
				url = secure_url(s); break
			}
		}
		if url == "" {
			continue
		}
		distributions, has := xml_field(doc, value, "Distributions"); if !has {
			continue
		}
		distro := field_text(doc, distributions, "English"); if distro == "" {
			distro = field_text(doc, distributions, "en")
		}
		if distro == "" {
			children := xml_children(doc, distributions)
			if len(children) > 1 {
				distro = xml_text(doc, children[1])
			}
		}
		if !apple_url(url) || !apple_url(secure_url(distro)) {
			continue
		}
		append(
			&result,
			Apple_Product {
				id = id,
				url = strings.clone(url),
				distribution = strings.clone(secure_url(distro)),
				catalog = catalog,
			},
		)
	}
	return result[:], ""
}
distribution_identity :: proc(data: string) -> (string, string, string) {
	doc, err := parse_xml(data); if err != "" {
		return "", "", err
	}; defer xml.destroy(doc)
	build, version: string
	for el, i in doc.elements {
		if el.ident != "dict" {
			continue
		}
		id := xml.Element_ID(i)
		for key in ([]string{"BUILD", "Build", "macOSProductBuildVersion"}) {
			if s := field_text(doc, id, key); s != "" {
				build = s
			}
		}
		for key in ([]string {
				"VERSION",
				"ProductVersion",
				"macOSProductVersion",
			}) {
			if s := field_text(doc, id, key); s != "" {
				version = s
			}
		}
	}
	return strings.clone(build), strings.clone(version), ""
}
resolve_product :: proc(
	catalog, build, work: string,
	progress: ^Progress = nil,
) -> (
	Apple_Product,
	string,
) {
	progress_stage(progress, "Reading Apple catalog")
	file := join(work, "catalog.download")
	if err := download(catalog, file, progress); err != "" {
		return {}, err
	}
	b, e := os.read_entire_file(file, context.allocator); if e != nil {
		return {}, "cannot read catalog"
	}
	data := string(b)
	if len(b) > 2 && b[0] == 0x1f && b[1] == 0x8b {
		out, err := run_progress(
			[]string{"/usr/bin/gzip", "-dc", file},
			progress,
		); if err != "" {
			return {}, err
		}; data = out
	}
	products, err := catalog_products(data, catalog); if err != "" {
		return {}, err
	}
	for &product, i in products {
		progress_stage(
			progress,
			"Finding requested macOS build",
			fmt.tprintf("%d/%d", i + 1, len(products)),
		)
		distribution := join(work, fmt.tprintf("distribution-%d.xml", i))
		if error := download(product.distribution, distribution, progress);
		   error != "" {
			return {}, error
		}
		d, read_err := os.read_entire_file(distribution, context.allocator)
		if read_err != nil {
			return {}, "cannot read product distribution"
		}
		actual, version, error := distribution_identity(string(d))
		if error != "" {
			return {}, error
		}
		if actual == build {
			product.build = actual; product.version = version
			return product, ""
		}
	}
	return {}, fmt.tprintf(
		"build %s is not available in this Apple catalog; no other build was substituted",
		build,
	)
}
// Search bounded extraction trees without following symlinks. Direct OS roots are
// checked first; the remainder searches package/image containers, not user data.
find_payloads :: proc(
	root: string,
	depth: int,
	images, packages: ^[dynamic]string,
	archives: ^[dynamic]string = nil,
) {
	if depth > 8 {
		return
	}
	entries, e := os.read_directory_by_path(root, -1, context.allocator)
	if e != nil {
		return
	}
	for entry in entries {
		if entry.type == .Directory {
			find_payloads(
				entry.fullpath,
				depth + 1,
				images,
				packages,
				archives,
			)
		}
		if entry.type != .Regular {
			continue
		}
		if strings.has_suffix(entry.name, ".dmg") {
			append(images, entry.fullpath)
		}
		if strings.has_suffix(entry.name, ".pkg") {
			append(packages, entry.fullpath)
		}
		if archives != nil && strings.has_suffix(entry.name, ".zip") {
			append(archives, entry.fullpath)
		}
	}
}
find_os_root :: proc(
	root, expected: string,
	out: string,
	origin: Manifest,
	depth: int = 0,
	progress: ^Progress = nil,
) -> (
	bool,
	string,
) {
	if depth > 4 {
		return false, "container nesting exceeds supported extraction depth"
	}
	dock := join(
		root,
		"System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
	)
	system := join(root, "System/Library/CoreServices/SystemVersion.plist")
	if os.exists(dock) && os.exists(system) {
		build, err := plist_field(system, "ProductBuildVersion")
		if err != "" {
			return false, err
		}
		if build != expected {
			return false, fmt.tprintf(
				"extracted OS build %s does not match requested %s",
				build,
				expected,
			)
		}
		version, error := plist_field(system, "ProductVersion")
		if error != "" {
			return false, error
		}
		provenance := origin
		provenance.metadata_source = "extracted_system_plist"
		return true, snapshot(dock, version, build, out, provenance)
	}
	images, packages, archives: [dynamic]string
	find_payloads(root, 0, &images, &packages, &archives)
	container_errors := strings.builder_make(context.allocator)
	for image in images {
		progress_stage(progress, "Inspecting system images")
		mount, mount_err := os.make_directory_temp(
			"",
			"shoji-dock-mount-*",
			context.allocator,
		)
		if mount_err != nil {
			return false, "cannot create image mount point"
		}
		// Images are mounted read-only and hidden; no installer is launched.
		_, err := run_progress(
			[]string {
				"/usr/bin/hdiutil",
				"attach",
				"-readonly",
				"-nobrowse",
				"-noautoopen",
				"-mountpoint",
				mount,
				image,
			},
			progress,
			false,
		)
		if err != "" {
			_ = os.remove(mount)
			if progress != nil {
				fmt.fprintf(progress.log, "Skipping image: %s\n", err)
			}
			fmt.sbprintf(&container_errors, "\nImage %s: %s", image, err)
			continue
		}
		found, error := find_os_root(
			mount,
			expected,
			out,
			origin,
			depth + 1,
			progress,
		)
		_, detach_error := run_progress(
			[]string{"/usr/bin/hdiutil", "detach", mount},
			progress,
			false,
		)
		if detach_error != "" {
			return false, fmt.tprintf(
				"could not detach %s: %s",
				mount,
				detach_error,
			)
		}
		_ = os.remove(mount)
		if error != "" || found {
			return found, error
		}
	}
	for pkg in packages {
		progress_stage(progress, "Extracting system package")
		package_work, work_err := os.make_directory_temp(
			"",
			"shoji-dock-package-*",
			context.allocator,
		)
		if work_err != nil {
			return false, "cannot create nested package workspace"
		}
		expanded := join(package_work, "expanded")
		_, err := run_progress(
			[]string{"/usr/sbin/pkgutil", "--expand-full", pkg, expanded},
			progress,
			false,
		)
		if err != "" {
			fmt.sbprintf(&container_errors, "\nPackage %s: %s", pkg, err)
			_ = os.remove_all(package_work)
			continue
		}
		found, error := find_os_root(
			expanded,
			expected,
			out,
			origin,
			depth + 1,
			progress,
		)
		_ = os.remove_all(package_work)
		if error != "" || found {
			return found, error
		}
	}
	for archive in archives {
		found, error := inspect_mobileasset(
			archive,
			expected,
			out,
			origin,
			progress,
		)
		if error != "" {
			fmt.sbprintf(
				&container_errors,
				"\nMobileAsset %s: %s",
				archive,
				error,
			)
		}
		if found {
			return true, ""
		}
	}
	if errors := strings.to_string(container_errors); errors != "" {
		return false, fmt.tprintf(
			"could not inspect extracted containers; files retained at %s:%s",
			root,
			errors,
		)
	}
	return false, ""
}
fetch :: proc(
	build, out, catalog, package_path, url: string,
	animate: bool = true,
	extracted_path: string = "",
) -> string {
	if build == "" {
		return "fetch requires --build; builds are never silently substituted"
	}
	if os.exists(out) {
		return "output already exists; choose a fresh directory"
	}
	if extracted_path != "" {
		if package_path != "" || url != "" {
			return "choose --extracted, --package or --url"
		}
		if info, error := os.stat(extracted_path, context.allocator);
		   error != nil || info.type != .Directory {
			return "--extracted must name an existing extraction directory"
		}
	}
	work, e := os.make_directory_temp(
		"",
		"shoji-dock-fetch-*",
		context.allocator,
	); if e != nil {
		return "cannot create extraction directory"
	}
	// Keep failed extraction evidence; delete only after successful extraction and
	// image detachment. No cleanup ever traverses a mounted system image.
	progress, progress_error := progress_open(work, animate)
	if progress_error != "" {
		return progress_error
	}
	defer progress_close(&progress)
	fmt.eprintf("Acquisition log: %s\n", progress.log_path)
	origin := Manifest {
		build       = build,
		catalog_url = catalog,
	}
	if package_path != "" || url != "" || extracted_path != "" {
		origin.catalog_url = ""
	}
	expanded := extracted_path
	if expanded == "" {
		pkg := package_path
		if pkg == "" {
			package_url := url
			if package_url == "" {
				product, err := resolve_product(
					catalog,
					build,
					work,
					&progress,
				); if err != "" {
					return err
				}
				origin.product_id = product.id; package_url = product.url
			}
			pkg = join(work, "InstallAssistant.pkg")
			origin.source_url = package_url
			progress_stage(&progress, "Downloading macOS installer")
			if err := download(package_url, pkg, &progress); err != "" {
				return err
			}
		}
		pkg_abs, abs_err := filepath.abs(pkg); if abs_err != nil {
			return "cannot resolve package path"
		}; pkg = pkg_abs
		progress_stage(&progress, "Checking package signature")
		if _, err := run_progress(
			[]string{"/usr/sbin/pkgutil", "--check-signature", pkg},
			&progress,
		); err != "" {
			return err
		}
		progress_stage(&progress, "Hashing installer")
		sha, err := run_progress(
			[]string{"/usr/bin/shasum", "-a", "256", pkg},
			&progress,
		); if err != "" {
			return err
		}
		fields := strings.fields(sha); if len(fields) == 0 {
			return "cannot hash package"
		}; origin.source_sha256 = fields[0]
		expanded = join(work, "expanded")
		progress_stage(&progress, "Extracting installer")
		if _, err := run_progress(
			[]string{"/usr/sbin/pkgutil", "--expand-full", pkg, expanded},
			&progress,
			false,
		); err != "" {
			return err
		}
	}
	found, error := find_os_root(
		expanded,
		build,
		out,
		origin,
		progress = &progress,
	)
	if error != "" {
		return error
	}
	if !found {
		return fmt.tprintf(
			"package extracted but no matching OS image containing Dock was found; workspace retained at %s",
			work,
		)
	}
	progress_clear(&progress)
	_ = os.sync(progress.log)
	if error := os.copy_file(join(out, "acquisition.log"), progress.log_path);
	   error != nil {
		return fmt.tprintf(
			"snapshot created, but acquisition log could not be copied: %v",
			error,
		)
	}
	progress_close(&progress)
	// The workspace can contain attacker-controlled paths from a local package;
	// os.remove_all does not follow symlinks. Mounted images were detached above.
	if error := os.remove_all(work); error != nil {
		fmt.eprintf("Acquisition succeeded; cleanup failed: %v\n", error)
	}
	return ""
}

// MobileAsset acquisition
// ------------------------------------------------------------------------

// Only numbered payloads and the two required regular files are extracted.
// Firmware, scripts, patch bases and ECC data cannot become snapshot inputs.
mobileasset_payload :: proc(path: string) -> bool {
	if !strings.has_prefix(path, "AssetData/payloadv2/payload.") {
		return false
	}
	suffix := path[len("AssetData/payloadv2/payload."):]
	if len(suffix) != 3 {
		return false
	}
	for c in suffix {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

inspect_mobileasset :: proc(
	archive, expected, out: string,
	origin: Manifest,
	progress: ^Progress,
) -> (
	bool,
	string,
) {
	progress_stage(progress, "Inspecting MobileAsset ZIP")
	listing, error := run_progress(
		[]string{"/usr/bin/bsdtar", "-tf", archive},
		progress,
	)
	if error != "" {
		return false, error
	}
	payloads := make([dynamic]string)
	for entry in strings.split_lines(listing) {
		if mobileasset_payload(entry) {
			append(&payloads, entry)
		}
	}
	if len(payloads) == 0 {
		return false, ""
	}
	work, e := os.make_directory_temp(
		"",
		"shoji-dock-mobileasset-*",
		context.allocator,
	)
	if e != nil {
		return false, "cannot create MobileAsset workspace"
	}
	defer os.remove_all(work)
	system := join(work, "system")
	if error := mkdir(system); error != "" {
		return false, error
	}
	for payload, i in payloads {
		progress_stage(
			progress,
			"Reading MobileAsset payloads",
			fmt.tprintf("%d/%d", i + 1, len(payloads)),
		)
		_, error := run_progress(
			[]string {
				"/usr/bin/bsdtar",
				"-xf",
				archive,
				"-C",
				work,
				"--",
				payload,
			},
			progress,
			false,
		)
		if error != "" {
			return false, error
		}
		path := join(work, payload)
		file, open_error := os.open(path)
		if open_error != nil {
			return false, "cannot read extracted MobileAsset payload"
		}
		header: [4]u8
		n, read_error := os.read(file, header[:])
		_ = os.close(file)
		if read_error != nil || n != 4 {
			return false, "truncated MobileAsset payload"
		}
		archive_path := path
		if string(header[:]) == "pbzm" {
			archive_path = join(work, "decoded.aar")
			if error := decode_pbzm(path, archive_path, progress);
			   error != "" {
				return false, error
			}
		}
		_, error = run_progress(
			[]string {
				"/usr/bin/aa",
				"extract",
				"-i",
				archive_path,
				"-d",
				system,
				"-include-regex",
				`^(\./)?System/Library/CoreServices/(Dock\.app/Contents/MacOS/Dock|SystemVersion\.plist)$`,
				"-include-type",
				"f",
			},
			progress,
			false,
		)
		_ = os.remove(path)
		if archive_path != path {
			_ = os.remove(archive_path)
		}
		if error != "" {
			return false, error
		}
	}
	return find_os_root(system, expected, out, origin, progress = progress)
}

// PBZM decompression
// ------------------------------------------------------------------------

foreign raven {
	lzraven_decode_buffer_ex :: proc(dst: [^]u8, capacity: uint, src: [^]u8, size: uint, status: ^i32) -> uint ---
	lzraven_status_string :: proc(status: i32) -> cstring ---
}

PBZM_BLOCK_LIMIT :: 64 * 1024 * 1024
pbzm_be64 :: proc(bytes: []u8) -> u64 {
	v: u64
	for b in bytes { v = (v << 8) | u64(b) }
	return v
}
pbzm_read :: proc(file: ^os.File, bytes: []u8) -> bool {
	offset := 0
	for offset < len(bytes) {
		n, error := os.read(file, bytes[offset:])
		if error != nil || n == 0 {
			return false
		}
		offset += n
	}
	return true
}

// pbzm is a sequence of independently compressed chunks. Keep only one encoded
// and one decoded chunk in memory; never allocate from the whole archive's size.
decode_pbzm :: proc(
	source, destination: string,
	progress: ^Progress = nil,
) -> string {
	file, error := os.open(source)
	if error != nil {
		return fmt.tprintf("cannot open pbzm: %v", error)
	}
	defer os.close(file)
	info, stat_error := os.stat(source, context.allocator)
	if stat_error != nil || info.size < 12 {
		return "truncated pbzm header"
	}
	header: [12]u8
	if !pbzm_read(file, header[:]) || string(header[:4]) != "pbzm" {
		return "invalid pbzm header"
	}
	nominal := pbzm_be64(header[4:])
	if nominal == 0 || nominal > PBZM_BLOCK_LIMIT {
		return "pbzm block size exceeds the 64 MiB limit"
	}
	output, create_error := os.open(
		destination,
		{.Write, .Create, .Excl},
		os.perm(0o600),
	)
	if create_error != nil {
		return fmt.tprintf("cannot create decoded archive: %v", create_error)
	}
	success := false
	defer {
		_ = os.close(output)
		if !success {
			_ = os.remove(destination)
		}
	}
	allocator := runtime.heap_allocator()
	encoded := make([]u8, int(nominal), allocator)
	decoded := make([]u8, int(nominal), allocator)
	defer delete(encoded, allocator)
	defer delete(decoded, allocator)
	offset := i64(12)
	block := 0
	defer progress_clear(progress)
	for offset < info.size {
		chunk: [16]u8
		if info.size - offset < 16 || !pbzm_read(file, chunk[:]) {
			return "truncated pbzm chunk header"
		}
		offset += 16
		uncompressed := pbzm_be64(chunk[:8])
		compressed := pbzm_be64(chunk[8:])
		if uncompressed == 0 ||
		   uncompressed > nominal ||
		   compressed == 0 ||
		   compressed > nominal {
			return "invalid pbzm chunk size"
		}
		if compressed > u64(info.size - offset) {
			return "pbzm chunk extends past end of file"
		}
		bytes := encoded[:int(compressed)]
		if !pbzm_read(file, bytes) {
			return "truncated pbzm chunk"
		}
		offset += i64(compressed)
		if compressed != uncompressed {
			status: i32
			n := lzraven_decode_buffer_ex(
				raw_data(decoded),
				uint(uncompressed),
				raw_data(bytes),
				uint(compressed),
				&status,
			)
			if status != 0 || n != uint(uncompressed) {
				return fmt.tprintf(
					"pbzm/LZRAVEN block %d failed: %s (decoded %d, expected %d)",
					block,
					lzraven_status_string(status),
					n,
					uncompressed,
				)
			}
			bytes = decoded[:int(uncompressed)]
		}
		written := 0
		for written < len(bytes) {
			n, write_error := os.write(output, bytes[written:])
			if write_error != nil || n == 0 {
				return fmt.tprintf(
					"cannot write decoded archive: %v",
					write_error,
				)
			}
			written += n
		}
		block += 1
		progress_stage(
			progress,
			"Decoding MobileAsset payload",
			fmt.tprintf("block %d", block),
		)
		progress_draw(progress)
	}
	if block == 0 {
		return "pbzm container has no chunks"
	}
	success = true
	return ""
}

// Progress presentation
// ------------------------------------------------------------------------

Progress :: struct {
	interactive, drawn: bool,
	label, detail, last_label, file, log_path: string,
	started: time.Tick,
	frame: int,
	log: ^os.File,
	output: ^os.File,
}
Window_Size :: struct {
	rows, columns, x_pixels, y_pixels: u16,
}
foreign progress_libc {
	@(link_name = "ioctl")
	progress_ioctl :: proc(fd: i32, request: uintptr, data: ^Window_Size) -> i32 ---
}
progress_open :: proc(work: string, enabled: bool) -> (Progress, string) {
	path := join(work, "acquisition.log")
	log, err := os.open(
		path,
		{.Read, .Write, .Create, .Append},
		os.perm(0o600),
	)
	if err != nil {
		return {}, fmt.tprintf("cannot open acquisition log: %v", err)
	}
	terminal := os.get_env("TERM", context.allocator)
	return Progress {
			interactive = enabled && posix.isatty(2) && terminal != "dumb",
			log = log,
			output = os.stderr,
			log_path = path,
			started = time.tick_now(),
		},
		""
}
progress_clear :: proc(p: ^Progress) {
	if p == nil || !p.drawn {
		return
	}
	fmt.fprint(p.output, "\r\x1b[2K")
	p.drawn = false
}
progress_close :: proc(p: ^Progress) {
	progress_clear(p)
	if p != nil && p.log != nil {
		_ = os.close(p.log); p.log = nil
	}
}
progress_stage :: proc(p: ^Progress, label: string, detail: string = "") {
	if p == nil {
		return
	}
	if p.label != label {
		p.started = time.tick_now(); p.frame = 0
	}
	p.label = label; p.detail = detail
	if !p.interactive && p.last_label != label {
		fmt.fprintln(p.output, label)
	}
	p.last_label = label
}
// ASCII frames and width-limited text avoid wrapping when the terminal is narrow.
// No cursor hiding or terminal mode changes need recovery after interruption.
progress_line :: proc(
	label, detail: string,
	frame, elapsed: int,
	bytes: i64,
	width: int,
	allocator := context.allocator,
) -> string {
	frames := [4]string{"|", "/", "-", "\\"}
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s %s", frames[frame % 4], label)
	if detail != "" {
		fmt.sbprintf(&b, " (%s)", detail)
	}
	if bytes >= 0 {
		if bytes >= 1024 * 1024 * 1024 {
			fmt.sbprintf(&b, "  %.2f GiB", f64(bytes) / (1024 * 1024 * 1024))
		} else {
			fmt.sbprintf(&b, "  %.1f MiB", f64(bytes) / (1024 * 1024))
		}
	}
	fmt.sbprintf(&b, "  %d:%02d", elapsed / 60, elapsed % 60)
	s := strings.to_string(b); limit := max(0, width - 1)
	if len(s) > limit {
		return s[:limit]
	}
	return s
}
progress_draw :: proc(p: ^Progress) {
	if p == nil || !p.interactive {
		return
	}
	// Each frame uses bounded stack storage and never changes the caller's allocators.
	buffer: [8192]u8
	scratch: mem.Arena
	mem.arena_init(&scratch, buffer[:])
	allocator := mem.arena_allocator(&scratch)
	columns := 80
	size: Window_Size
	if p.output == os.stderr &&
	   progress_ioctl(2, 0x40087468, &size) == 0 &&
	   size.columns > 0 {
		columns = int(size.columns)
	}
	bytes: i64 = -1
	if p.file != "" {
		if info, err := os.stat(p.file, allocator); err == nil {
			bytes = info.size
		}
	}
	line := progress_line(
		p.label,
		p.detail,
		p.frame,
		int(time.tick_since(p.started) / time.Second),
		bytes,
		columns,
		allocator,
	)
	fmt.fprintf(p.output, "\r\x1b[2K%s", line)
	p.frame += 1; p.drawn = true
}
log_tail :: proc(log: ^os.File) -> string {
	end, err := os.seek(log, 0, .End); if err != nil {
		return ""
	}
	_, _ = os.seek(log, max(i64(0), end - 4096), .Start)
	b := make([]u8, min(i64(4096), end))
	n, read_error := os.read(log, b)
	_, _ = os.seek(log, 0, .End)
	if read_error != nil {
		return ""
	}
	return strings.trim_space(string(b[:n]))
}
// Redirect subprocess output to files so verbose extraction cannot flood the
// terminal or fill a pipe while the parent polls and renders progress.
run_progress :: proc(
	args: []string,
	p: ^Progress,
	capture: bool = true,
) -> (
	string,
	string,
) {
	if p == nil {
		return run(args)
	}
	fmt.fprintf(p.log, "command: %q\n", args)
	output, err := os.create_temp_file(
		filepath.dir(p.log_path),
		"command-output-*",
	)
	if err != nil {
		return "", fmt.tprintf("cannot create progress output: %v", err)
	}
	defer os.close(output)
	defer os.remove(os.name(output))
	destination := output
	if !capture {
		destination = p.log
	}
	child, start_error := os.process_start(
		os.Process_Desc{command = args, stdout = destination, stderr = p.log},
	)
	if start_error != nil {
		return "", fmt.tprintf("cannot start %s: %v", args[0], start_error)
	}
	defer progress_clear(p)
	state: os.Process_State
	for {
		wait_error: os.Error
		state, wait_error = os.process_wait(
			child,
			p.interactive ? 0 : os.TIMEOUT_INFINITE,
		)
		if wait_error == .Timeout {
			progress_draw(p)
			time.sleep(100 * time.Millisecond)
			continue
		}
		if wait_error != nil {
			_ = os.process_kill(child); _, _ = os.process_wait(child)
			return "", fmt.tprintf(
				"cannot wait for %s: %v",
				args[0],
				wait_error,
			)
		}
		break
	}
	if !state.success {
		return "", fmt.tprintf(
			"%s failed (%d); details: %s\n%s",
			args[0],
			state.exit_code,
			p.log_path,
			log_tail(p.log),
		)
	}
	if !capture {
		return "", ""
	}
	_, _ = os.seek(output, 0, .Start)
	bytes, read_error := os.read_entire_file(output, context.allocator)
	if read_error != nil {
		return "", fmt.tprintf("cannot read command output: %v", read_error)
	}
	return string(bytes), ""
}
