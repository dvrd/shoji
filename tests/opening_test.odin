package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

@(test)
all_native_observations_use_one_admission_boundary :: proc(t: ^testing.T) {
    for app in ([]string{"Mail", "Ghostty", "Chrome"}) {
        state: mac.State;r: Recorder;fixture(&state.manager, &r)
        defer e.manager_destroy(&state.manager);defer delete(r.actions);defer delete(state.opening_windows)
        state.opening_tracking = true
        state.opening_backend = {prepare = e.opening_apply_seed}
        value := e.Window{id = 30, pid = 42, app = app, role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {10, 10, 700, 600}}
        w := mac.opening_observe(&state, {}, nil, value)
        testing.expect_value(t, w.opening.phase, e.Opening_Phase.Opening)
        clear(&r.actions)
        mac.opening_observe(&state, {}, nil, value)
        testing.expect_value(t, len(r.actions), 0)
        testing.expect(t, e.find(e.space_by_id(&state.manager, 100).view.root, w.id) != nil)
    }
}

@(test)
move_only_opening_does_not_capture_the_concealed_native_window :: proc(t: ^testing.T) {
    state: mac.State;r: Recorder;fixture(&state.manager, &r)
    defer e.manager_destroy(&state.manager);defer delete(r.actions);defer delete(state.animations)
    w := state.manager.windows[1]
    w.opening.phase = .Opening;w.frame = {0, 0, 500, 800}
    action := mac.animation_frame_action(&state, {kind = .Frame, window = w.id, frame = {500, 0, 500, 800}, duration = 0.5})
    // No recovery journal exists: a snapshot attempt would fail rather than
    // animate. Preparation already established the real window's starting size.
    testing.expect_value(t, mac.animation_start(&state, action), "")
    job, exists := state.animations[w.id]
    testing.expect(t, exists && mac.animation_is_live(job))
    testing.expect_value(t, job.from, w.frame)
}

opening_record_conceal :: proc(m: ^e.Manager, w: ^e.Window) -> string {
    return e.perform(m, {kind = .Opacity, window = w.id, value = 0})
}

@(test)
newcomer_is_concealed_during_collection_before_other_apps_are_scanned :: proc(t: ^testing.T) {
    state: mac.State;r: Recorder;fixture(&state.manager, &r)
    defer e.manager_destroy(&state.manager);defer delete(r.actions);defer delete(state.opening_windows)
    state.opening_tracking = true;state.opening_collecting = true
    state.opening_backend = {prepare = e.opening_apply_seed, conceal = opening_record_conceal}
    value := e.Window{id = 30, pid = 42, app = "Mail", role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {866, 42, 858, 1071}}
    clear(&r.actions)
    w := mac.opening_observe(&state, {}, nil, value)
    testing.expect_value(t, w.opening.phase, e.Opening_Phase.Pending)
    testing.expect(t, e.find(e.space_by_id(&state.manager, 100).view.root, w.id) == nil)
    concealed := false
    for a in r.actions {
        if a.kind == .Opacity && a.window == w.id && a.value == 0 {concealed = true}
        testing.expect(t, a.kind != .Frame)
    }
    testing.expect(t, concealed)
}
