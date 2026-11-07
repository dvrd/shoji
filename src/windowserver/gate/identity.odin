package gate

foreign import system "system:System"

// Pin the exact signed controller artifact, not its path or caller-supplied PID.
// Empty/malformed policy refuses every client. Ad-hoc signatures identify a
// build artifact; they do not establish an Apple developer/team identity.
gate_identity_matches :: proc "contextless" (expected: string, observed: []u8, query_status: i32) -> bool {
	if query_status != 0 || len(expected) != 40 || len(observed) != 20 {return false}
	for i in 0 ..< 20 {
		value: u8
		for j in 0 ..< 2 {
			ch := expected[2*i+j]
			nibble: u8
			if ch >= '0' && ch <= '9' {nibble = ch-'0'} else if ch >= 'a' && ch <= 'f' {nibble = ch-'a'+10} else {return false}
			value = value*16+nibble
		}
		if observed[i] != value {return false}
	}
	return true
}

// Allowlist form: 40-hex CDHashes separated by commas or whitespace (the
// build-time pins, or the root-owned clients file). Any match authorizes;
// empty or malformed entries never match.
gate_identity_matches_any :: proc "contextless" (expected_list: string, observed: []u8, query_status: i32) -> bool {
	if query_status != 0 {return false}
	start := 0
	for i in 0 ..= len(expected_list) {
		if i == len(expected_list) || gate_allowlist_separator(expected_list[i]) {
			if gate_identity_matches(expected_list[start:i], observed, 0) {return true}
			start = i + 1
		}
	}
	return false
}

gate_allowlist_separator :: proc "contextless" (ch: u8) -> bool {
	return ch == ',' || ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t'
}

// Runtime allowlist: Shoji's root installer records each update's CDHash in
// a file beside the payload, so an update needs no payload rebuild or
// WindowServer restart. Without an Apple team identity, trust comes from
// root ownership: only root may have written the file or its directory.
GATE_CLIENTS_LIMIT :: 4096
S_IFMT_BITS :: 0o170000
S_IFREG_BITS :: 0o100000
S_IFDIR_BITS :: 0o040000

gate_allowlist_trusted :: proc "contextless" (file_uid, file_mode: u32, file_size: i64, dir_uid, dir_mode: u32) -> bool {
	return file_uid == 0 && file_mode & S_IFMT_BITS == S_IFREG_BITS && file_mode & 0o022 == 0 &&
	       file_size > 0 && file_size <= GATE_CLIENTS_LIMIT &&
	       dir_uid == 0 && dir_mode & S_IFMT_BITS == S_IFDIR_BITS && dir_mode & 0o022 == 0
}

foreign system {
	csops_audittoken :: proc "c" (pid: i32, operation: u32, buffer: rawptr, size: uintptr, token: ^Audit_Token) -> i32 ---
}

// Any list may authorize; the kernel is queried once.
gate_client_identity :: proc(token: ^Audit_Token, expected_lists: ..string) -> bool {
	usable := false
	for list in expected_lists {if len(list) >= 40 {usable = true}}
	if !usable {return false}
	pid := gate_audit_pid(token)
	if pid == 0 || pid > 0x7fffffff {return false}
	hash: [20]u8
	// CS_OPS_CDHASH=5. The kernel binds this query to pidversion in token,
	// avoiding the PID-reuse race of a path-based signature check.
	status := csops_audittoken(i32(pid), 5, &hash, len(hash), token)
	for list in expected_lists {
		if gate_identity_matches_any(list, hash[:], status) {return true}
	}
	return false
}
