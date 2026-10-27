package dockscan

import "core:fmt"
import "core:os"
import "core:strings"

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
