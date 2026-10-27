package harness

import s "../../../src/support"
import tc "../../common"
import "core:fmt"

live_spaces :: proc(c: tc.Context, load_payload: bool) -> string {
	l: Live
	err := live_spaces_run(c, load_payload, &l)
	return finish_live(&l, err)
}
live_spaces_run :: proc(
	c: tc.Context,
	load_payload: bool,
	l: ^Live,
) -> (
	err: string,
) {
	prepared, e := prepare_live(c, "shoji-spaces"); if e != "" {
		return e
	}
	l^ = prepared
	created, original: u64; protected: []u64
	defer {
		s.begin_cleanup()
		defer s.end_cleanup()
		if created != 0 {
			if cleanup := restore_space(l, created, original, protected);
			   cleanup != "" {
				record_cleanup(l, "disposable Space", cleanup)
			}
		}
	}
	if err = build_live_helper(c); err != "" {
		return err
	}
	if load_payload {
		if _, err = live_command(
			l,
			[]string {
				"sudo",
				"-n",
				tc.binary(c, "shoji"),
				"--load-sa",
				tc.binary(c, "shoji-sa.dylib"),
			},
		); err != "" {
			return err
		}
	}
	if _, err = live_command(l, []string{tc.binary(c, "shoji"), "--check-sa"});
	   err != "" {
		return err
	}
	before, e1 := space_snapshot(l); if e1 != "" {
		return e1
	}; protected = space_ids(before)
	focused := 0
	for space in before.spaces {
		if space.focus {
			focused += 1; original = space.id; if space.fullscreen {
				return "start on a regular desktop Space"
			}
		}
	}
	if focused != 1 {
		return "cannot identify the original focused Space"
	}
	text, e2 := live_helper(
		l,
		"space-create-tracked",
		fmt.tprintf("%d", original),
	); if e2 != "" {
		return e2
	}
	fresh, id_error := parse_id(text); if id_error != "" {
		return id_error
	}
	if contains_space(protected, fresh) {
		return "payload returned a pre-existing Space; refusing cleanup target"
	}
	created = fresh; l.report.created_space = created
	if err = wait_space(l, created, true, false); err != "" {
		return err
	}
	if _, err = live_helper(l, "space-focus", fmt.tprintf("%d", created));
	   err != "" {
		return err
	}
	if err = wait_space(l, created, true, true); err != "" {
		return err
	}
	if err = restore_space(l, created, original, protected); err != "" {
		return err
	}
	if err = wait_space(l, created, false, false); err != "" {
		return err
	}
	created = 0
	after, e3 := space_snapshot(l); if e3 != "" {
		return e3
	}
	for id in protected {
		if !contains_space(space_ids(after), id) {
			return "a pre-existing Space disappeared"
		}
	}
	restored := false; for space in after.spaces {
		if space.id == original && space.visible {
			restored = true
		}
	}
	if !restored {
		return "original Space was not restored"
	}
	fmt.println(
		"PASS: tracked Space creation, focus, return and disposable Space destruction",
	)
	return ""
}
