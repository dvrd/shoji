package macos

import "core:fmt"

Frame_Updates :: struct {
	depth: int,
	user: rawptr,
	set_enabled: proc(user: rawptr, connection: i32, enabled: bool) -> i32,
}

foreign import frame_updates_sls "system:SkyLight.framework"
foreign frame_updates_sls {
	SLSDisableUpdate :: proc "c" (connection: i32) -> i32 ---
	SLSReenableUpdate :: proc "c" (connection: i32) -> i32 ---
}

frame_updates_set :: proc(state: ^State, enabled: bool) -> i32 {
	if state.frame_updates.set_enabled != nil {
		return state.frame_updates.set_enabled(
			state.frame_updates.user,
			state.connection,
			enabled,
		)
	}
	if state.connection == 0 {
		return 0
	}
	return(
		enabled \
			? SLSReenableUpdate(state.connection) \
			: SLSDisableUpdate(state.connection) \
	)
}

frame_updates_begin :: proc(state: ^State) -> string {
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, false); code != 0 {
			return fmt.tprintf(
				"could not begin frame presentation batch (%d)",
				code,
			)
		}
	}
	state.frame_updates.depth += 1
	return ""
}

frame_updates_end :: proc(state: ^State) -> string {
	if state.frame_updates.depth <= 0 {
		return "unbalanced frame presentation batch"
	}
	state.frame_updates.depth -= 1
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, true); code != 0 {
			return fmt.tprintf("could not present frame batch (%d)", code)
		}
	}
	return ""
}
