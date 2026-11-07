package tests

import dock "../src/dock"
import mac "../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

Recovery_Recorder :: struct {
	owners:      map[u32]i32,
	restores:    int,
	proxy_valid: bool,
	fail:        bool,
}
recovery_owner :: proc(user: rawptr, window: u32) -> (i32, bool) {
	rec := (^Recovery_Recorder)(user)
	owner, ok := rec.owners[window];return owner, ok
}
recovery_restore :: proc(user: rawptr, entry: dock.Entry, proxy_valid: bool) -> bool {
	rec := (^Recovery_Recorder)(user);rec.restores += 1;rec.proxy_valid = proxy_valid
	return !rec.fail
}
@(test)
animation_recovery_restores_orphan_and_rejects_reused_ids :: proc(t: ^testing.T) {
	rec := Recovery_Recorder {
		owners = make(map[u32]i32),
	}
	defer delete(rec.owners)
	backend := dock.Backend{recovery_owner, recovery_restore, &rec}
	entry := dock.Entry{1, 2, 10, 20}
	rec.owners[1], rec.owners[2] = 10, 20
	testing.expect_value(t, dock.restore(entry, backend, true), dock.Result.Active)
	testing.expect_value(t, rec.restores, 0)
	delete_key(&rec.owners, 2)
	testing.expect_value(t, dock.restore(entry, backend, true), dock.Result.Restored)
	testing.expect(t, !rec.proxy_valid)
	rec.owners[2] = 99
	testing.expect_value(t, dock.restore(entry, backend, false), dock.Result.Restored)
	testing.expect(t, !rec.proxy_valid)
	rec.owners[1] = 99
	testing.expect_value(t, dock.restore(entry, backend, false), dock.Result.Gone)
	testing.expect_value(t, rec.restores, 2)
}
@(test)
animation_recovery_retains_failed_restores :: proc(t: ^testing.T) {
	rec := Recovery_Recorder {
		owners = make(map[u32]i32),
		fail   = true,
	}
	defer delete(rec.owners);rec.owners[1] = 10
	backend := dock.Backend{recovery_owner, recovery_restore, &rec}
	testing.expect_value(t, dock.restore({1, 2, 10, 20}, backend, false), dock.Result.Retry)
	rec.fail = false
	testing.expect_value(t, dock.restore({1, 2, 10, 20}, backend, false), dock.Result.Restored)
}
@(test)
animation_journal_survives_reopen_and_keeps_failed_removal :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/shoji-recovery-test-%d.json", posix.getpid())
	defer os.remove(path)
	journal: mac.Animation_Journal
	testing.expect_value(t, mac.animation_journal_open(&journal, path), "")
	testing.expect_value(t, mac.animation_journal_record(&journal, {1, 2, 10, 20}), "")
	mac.animation_journal_close(&journal)
	testing.expect_value(t, mac.animation_journal_open(&journal, path), "")
	testing.expect_value(t, len(journal.entries), 1)
	testing.expect_value(t, journal.entries[1].owner, i32(10))
	original := journal.path
	journal.path = "/nonexistent/shoji-animation-test.json"
	testing.expect(t, mac.animation_journal_remove(&journal, 1) != "")
	testing.expect_value(t, len(journal.entries), 1)
	journal.path = original
	testing.expect_value(t, mac.animation_journal_remove(&journal, 1), "")
	mac.animation_journal_close(&journal)
	testing.expect_value(t, mac.animation_journal_open(&journal, path), "")
	testing.expect_value(t, len(journal.entries), 0)
	mac.animation_journal_close(&journal)
}
@(test)
animation_journal_rejects_malformed_records :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/shoji-recovery-invalid-%d.json", posix.getpid())
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, []u8{1, 2, 3}) == nil)
	journal: mac.Animation_Journal
	testing.expect(t, mac.animation_journal_open(&journal, path) != "")
	mac.animation_journal_close(&journal)
}
@(test)
animation_journal_failed_record_never_authorizes_hiding :: proc(t: ^testing.T) {
	journal: mac.Animation_Journal
	testing.expect_value(
		t,
		mac.animation_journal_open(&journal, "/nonexistent/shoji-animation.json"),
		"",
	)
	defer mac.animation_journal_close(&journal)
	testing.expect(t, mac.animation_journal_record(&journal, {1, 2, 10, 20}) != "")
	testing.expect_value(t, len(journal.entries), 0)
}
@(test)
animation_journal_rejects_symlink :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/shoji-recovery-symlink-%d.json", posix.getpid())
	defer os.remove(path)
	testing.expect(
		t,
		posix.symlink("/etc/hosts", strings.clone_to_cstring(path, context.temp_allocator)) == nil,
	)
	journal: mac.Animation_Journal
	testing.expect(t, mac.animation_journal_open(&journal, path) != "")
	mac.animation_journal_close(&journal)
}
@(test)
animation_shutdown_releases_proxy_after_failed_restore :: proc(t: ^testing.T) {
	state: mac.State;recorder: Recorder;animation: Animation_Recorder
	fixture(&state.manager, &recorder)
	defer mac.manager_destroy(&state.manager);defer delete(recorder.actions)
	state.event_user = &animation
	state.animation_backend = {
		proxy_create,
		proxy_update,
		proxy_restore,
		proxy_destroy,
		proxy_apply,
	}
	testing.expect_value(
		t,
		mac.animation_start(
			&state,
			{kind = .Frame, window = 1, frame = {0, 0, 200, 200}, duration = 1},
		),
		"",
	)
	animation.fail_restore = true
	mac.animation_stop(&state)
	testing.expect_value(t, animation.destroyed, 1)
	testing.expect_value(t, len(state.animations), 0)
}
