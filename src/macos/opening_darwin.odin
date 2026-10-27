package macos

import recovery "../addition/recovery"
import e "../engine"
import "core:fmt"
import "core:math"
import "core:time"

Opening_Guard :: struct {
    proxy: Animation_Proxy,
    hidden: bool,
    requested, sample: e.Rect,
    original: e.Rect,
    samples: int,
    checked: time.Time,
}

// Diagnostic builds arm on discovery so a human-triggered opening cannot miss
// the bounded capture interval. Only geometry and native operation status enter it.
opening_trace_begin :: proc(state: ^State) {
    when #config(SHOJI_OPENING_TRACE, false) {
        if !state.manager.motion_trace.active {e.motion_debug(&state.manager, {"motion", "start"})}
    }
}

opening_trace_native :: proc(state: ^State, kind: string, id: u32, requested: e.Rect = {}) {
    if !state.manager.motion_trace.active {return}
    actual: e.Rect
    code := SLSGetWindowBounds(state.connection, id, &actual)
    e.motion_trace_record(&state.manager.motion_trace, {kind = kind, window = id, requested = requested, observed = actual, status = code})
}

// Both native notifications and enumeration use this admission boundary.
opening_observe :: proc(state: ^State, app: Application, element: Ref, observation: e.Window) -> ^e.Window {
    value := observation
    old := state.manager.windows[value.id]
    if state.opening_tracking && !state.read_only && (old == nil || old.pid != value.pid) {
        opening_trace_begin(state)
        opening_trace_native(state, "opening-discovered", value.id)
        value.opening = {phase = .Pending, focus_origin = state.manager.focused}
    }
    w: ^e.Window
    if element != nil {w, _ = reconcile_window(state, app, element, value)}
    else {w, _ = reconcile_window_model(&state.manager, value)}
    if w.opening.phase == .Pending {
        if state.opening_windows == nil {state.opening_windows = make(map[u32]bool)}
        state.opening_windows[w.id] = true
        if state.opening_collecting {
            backend := state.opening_backend
            if backend.prepare == nil {backend = {opening_native_prepare, opening_conceal}}
            _, err := e.stage_opening(&state.manager, w, backend)
            if err != "" {fmt.eprintln("shoji: stage opening:", w.id, err)}
        } else {opening_attempt(state, w)}
    }
    if element != nil {reconcile_window_appearance(w, collect_window_appearance(state, element, w.id))}
    return w
}

opening_created :: proc(state: ^State, observer, element: Ref) {
    if state.read_only || !state.opening_tracking {return}
    id: u32
    if _AXUIElementGetWindow(element, &id) != 0 || id == 0 || attribute_text(element, "AXRole") != "AXWindow" {return}
    opening_trace_begin(state)
    opening_trace_native(state, "opening-created", id)
    for pid, app in state.applications {
        if app.observer != observer {continue}
        if state.validation_pid != 0 && state.validation_pid != pid {return}
        opening_observe(state, app, element, collect_window(state, app, element, id, pid, app.policy, app.hidden))
        return
    }
}

// The transparent owned surface is a liveness token, not a screenshot. Dock's
// orphan recovery restores the real window if the token owner crashes.
opening_conceal :: proc(m: ^e.Manager, w: ^e.Window) -> string {
    state := (^State)(m.backend_user)
    guard, exists := state.opening_guards[w.id]
    if !exists {
        owner, known := animation_recovery_query_owner(state.connection, w.id)
        pid: i32
        if !known || SLSConnectionGetPID(owner, &pid) != 0 || pid != w.pid {return "opening window ownership is unavailable"}
        surface, err := surface_create(state, {0, 0, 1, 1}, w.id, (1 << 1) | (1 << 3) | (1 << 9), 13, 1)
        if err != "" {return err}
        proxy_owner, proxy_known := animation_recovery_query_owner(state.connection, surface.id)
        if !proxy_known {surface_destroy(state, surface);return "opening token ownership is unavailable"}
        if err := animation_journal_record(&state.animation_journal, recovery.Entry{w.id, surface.id, owner, proxy_owner}); err != "" {
            surface_destroy(state, surface);return err
        }
        CGContextClearRect(surface.ctx, {0, 0, 1, 1});CGContextFlush(surface.ctx)
        guard.proxy = {window = w.id, surface = surface}
        guard.original = w.frame
        if state.opening_guards == nil {state.opening_guards = make(map[u32]Opening_Guard)}
        state.opening_guards[w.id] = guard
    }
    if guard.hidden {return ""}
    opening_trace_native(state, "opening-conceal-begin", w.id)
    if err := animation_swap(guard.proxy, true); err != "" {return err}
    opening_trace_native(state, "opening-conceal-end", w.id)
    guard.hidden = true;state.opening_guards[w.id] = guard
    return ""
}

opening_release :: proc(state: ^State, id: u32) -> string {
    guard, exists := state.opening_guards[id]
    if !exists {return ""}
    if w := state.manager.windows[id]; w != nil && (w.opening.phase == .Pending || w.opening.phase == .Excluded) && guard.requested.w > 0 && guard.original.w > 0 {
        if err := apply_frame_now(state, id, guard.original); err != "" {return err}
    }
    opening_trace_native(state, "opening-reveal-begin", id)
    if err := native_proxy_restore(state, guard.proxy); err != "" {return err}
    opening_trace_native(state, "opening-reveal-end", id)
    native_proxy_destroy(state, guard.proxy);delete_key(&state.opening_guards, id)
    return ""
}

opening_native_prepare :: proc(m: ^e.Manager, w: ^e.Window, seed: e.Rect) -> (e.Rect, bool, string) {
    state := (^State)(m.backend_user)
    element := state.windows[w.id]
    guard, exists := state.opening_guards[w.id]
    if element == nil || !exists || !guard.hidden {return {}, false, ""}
    if guard.requested != seed {
        if err := e.perform(m, {kind = .Frame, window = w.id, frame = seed, direct = true}); err != "" {return {}, false, err}
        guard.requested = seed;guard.samples = 0
        guard.checked = time.now();state.opening_guards[w.id] = guard
        return {}, false, ""
    }
    now := time.now()
    if time.diff(guard.checked, now) < 8 * time.Millisecond {return {}, false, ""}
    accepted := window_frame(element)
    if accepted.w <= 0 || accepted.h <= 0 {return {}, false, ""}
	if math.abs(accepted.x - guard.sample.x) <= 1 && math.abs(accepted.y - guard.sample.y) <= 1 && math.abs(accepted.w - guard.sample.w) <= 1 && math.abs(accepted.h - guard.sample.h) <= 1 {guard.samples += 1}
    else {guard.samples = 1}
    guard.sample = accepted;guard.checked = now;state.opening_guards[w.id] = guard
    return accepted, guard.samples >= 2, ""
}

opening_attempt :: proc(state: ^State, w: ^e.Window) {
    backend := state.opening_backend
    if backend.prepare == nil {backend = {opening_native_prepare, opening_conceal}}
    wait := w.opening.wait
    admitted, err := e.admit_window(&state.manager, w, backend)
    if admitted {opening_trace_native(state, "opening-admitted", w.id, w.opening.seed)}
    if err != "" && wait != .Backend {fmt.eprintln("shoji: opening:", w.id, err)}
    if admitted || w.opening.phase == .Excluded {
        if err := opening_release(state, w.id); err != "" {fmt.eprintln("shoji: reveal opening:", err)}
    }
}

opening_destroyed :: proc(state: ^State, element: Ref) {
    id: u32
    for window, ref in state.windows {if CFEqual(element, ref) {id = window;break}}
    if id == 0 {return}
    w := state.manager.windows[id];if w == nil {return}
    s := e.space_by_id(&state.manager, w.space)
    app := state.applications[w.pid]
    window_reference_remove(state, id, app.observer)
    e.remove_window(&state.manager, id)
    if err := opening_release(state, id); err != "" {fmt.eprintln("shoji: closed opening:", err)}
    delete_key(&state.opening_windows, id)
    if s != nil {if err := e.flush(&state.manager, s); err != "" {fmt.eprintln("shoji: close layout:", err)}}
}

opening_tick :: proc(state: ^State) {
    if state.read_only || state.manager.suspended || state.manager.gesture_active {return}
    ids := make([dynamic]u32, 0, len(state.opening_windows), context.temp_allocator)
    for id in state.opening_windows {append(&ids, id)}
    e.sort_ids(ids[:])
    for id in ids {
        w := state.manager.windows[id]
        if w == nil || w.opening.phase == .Excluded || w.opening.phase == .Admitted {
            if err := opening_release(state, id); err == "" {delete_key(&state.opening_windows, id)}
            continue
        }
        if w.opening.phase == .Pending {
            if element := state.windows[id]; element != nil {
                w.ordered_in = window_ordered_in(state, id)
                if sid := window_space(state, id); sid != 0 {w.space = sid}
                w.frame = window_frame(element)
            }
            opening_attempt(state, w)
            continue
        }
        if err := opening_release(state, id); err != "" {continue}
        busy := false
        for window in state.animations {if other := state.manager.windows[window]; other != nil && other.space == w.space {busy = true;break}}
        if s := e.space_by_id(&state.manager, w.space); s != nil && s.view.layout == .Scroll && (s.view.scroll.motion.active || s.view.scroll.geometry_active) {busy = true}
        if !busy {
            if err := e.finish_opening(&state.manager, w); err != "" {fmt.eprintln("shoji: finish opening:", err)}
        }
    }
    opening_notice_tick(state)
}

opening_stop :: proc(state: ^State) {
    for id, guard in state.opening_guards {
        if w := state.manager.windows[id]; w != nil && w.opening.phase == .Pending {
            e.perform(&state.manager, {kind = .Layer, window = id, value = w.opening.original_layer})
        }
        if err := opening_release(state, id); err != "" {
            fmt.eprintln("shoji: opening recovery:", err)
            native_proxy_destroy(state, guard.proxy)
        }
    }
    delete(state.opening_guards);delete(state.opening_windows)
    surface_destroy(state, state.opening_notice)
}
