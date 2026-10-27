package dockscan

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
