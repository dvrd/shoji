package tests

import mac "../src"
import "core:mem"
import "core:strings"
import "core:testing"
import layout "../src/layout"

@(test)
unknown_resize_stays_eligible_in_the_window_query :: proc(t: ^testing.T) {
	m: mac.Manager
	mac.manager_init(&m)
	defer mac.manager_destroy(&m)
	w := mac.add_window(&m, mac.Window{id = 1})
	testing.expect(t, w.can_resize == nil)
	testing.expect(t, mac.window_json(&m, w).can_resize)
	w.can_resize = false
	testing.expect(t, !mac.window_json(&m, w).can_resize)
}

@(test)
failed_root_query_keeps_a_known_child :: proc(t: ^testing.T) {
	m: mac.Manager
	mac.manager_init(&m)
	defer mac.manager_destroy(&m)
	w := mac.add_window(&m, mac.Window{id = 1, root_window = false, parent = 9})
	mac.reconcile_window_model(&m, mac.Window{id = 1})
	root, known := w.root_window.?
	testing.expect(t, known && !root)
	testing.expect_value(t, w.parent, u32(9))
	mac.reconcile_window_model(&m, mac.Window{id = 1, root_window = true})
	root, known = w.root_window.?
	testing.expect(t, known && root)
	testing.expect_value(t, w.parent, u32(0))
}

@(test)
unavailable_appearance_preserves_the_last_observed_window_layer :: proc(
	t: ^testing.T,
) {
	w := mac.Window {
		layer     = "above",
		sub_level = 3,
		sticky    = true,
		shadow    = false,
	}
	mac.reconcile_window_appearance(&w, {})
	testing.expect_value(t, w.sub_level, i32(3))
	testing.expect_value(t, w.layer, "above")
	testing.expect(t, w.sticky && !w.shadow)
}

@(test)
window_reconciliation_retains_unknown_capabilities_and_space :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	w := state.manager.windows[1]
	w.frame = {10, 10, 600, 400}
	w.can_resize = true; w.ordered_in = true; w.can_move = true
	w.opacity = 0.7; w.level = 12; w.sticky = true
	old_space, old_display := w.space, w.display
	value := w^
	value.can_resize = nil; value.ordered_in = nil
	value.space = 0; value.display = 0
	value.title = "new observation"; value.frame.w = 620
	updated, created := mac.reconcile_window_model(&state.manager, value)
	mac.reconcile_window_appearance(updated, {})
	testing.expect(t, !created && updated == w)
	testing.expect(t, w.can_resize.? or_else false)
	testing.expect(t, w.ordered_in.? or_else false)
	testing.expect(t, w.can_move && w.sticky)
	testing.expect_value(t, w.opacity, f64(0.7))
	testing.expect_value(t, w.level, i32(12))
	testing.expect_value(t, w.space, old_space)
	testing.expect_value(t, w.display, old_display)
	testing.expect_value(t, w.title, "new observation")
	testing.expect_value(t, w.frame.w, f64(620))
	value = w^
	value.can_resize = false; value.ordered_in = false
	mac.reconcile_window_model(&state.manager, value)
	mac.reconcile_window_appearance(
		w,
		{
			can_move = false,
			opacity = f64(0),
			level = i32(0),
			tags = u64(1 << 3),
		},
	)
	testing.expect(t, !(w.can_resize.? or_else true))
	testing.expect(t, !(w.ordered_in.? or_else true))
	testing.expect(t, !w.can_move && !w.sticky && !w.shadow)
	testing.expect_value(t, w.opacity, f64(0))
	testing.expect_value(t, w.level, i32(0))
}

@(test)
new_window_reconciliation_knows_resize_capability_before_tiling :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	w, created := mac.reconcile_window_model(
		&state.manager,
		{
			id = 55,
			pid = 42,
			app = "Fixture",
			title = "Fixed size",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			root_window = true,
			frame = {0, 0, 100, 100},
			space = 100,
			display = 1,
			can_resize = false,
		},
	)
	testing.expect(t, created)
	testing.expect(
		t,
		layout.find(mac.space_by_id(&state.manager, 100).view.root, w.id) == nil,
	)
}

@(test)
snapshot_diff_owns_destroyed_window_payload_without_dispatching :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; events: Event_Recorder
	fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer delete(events.events)
	state.event_sink = record_event; state.event_user = &events
	w := state.manager.windows[1]
	delete(w.title); w.title = strings.clone("owned title")
	before := mac.snapshot(&state, context.allocator)
	defer mac.snapshot_destroy(&before)
	mac.remove_window(&state.manager, 1)
	after := mac.snapshot(&state, context.allocator)
	defer mac.snapshot_destroy(&after)
	found := false
	for event in mac.snapshot_changes(before, after) {
		if event.name == "window_destroyed" && event.window == 1 {
			found = true
			testing.expect_value(t, event.title, "owned title")
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, len(events.events), 0)
}

@(test)
internal_frame_writer_does_not_interrupt_proxy_recovery :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; animation: Animation_Recorder
	fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	state.event_user = &animation
	state.animation_backend = {
		proxy_create,
		proxy_update,
		proxy_restore,
		proxy_destroy,
		mac.apply_frame_now,
	}
	state.animations = make(map[u32]mac.Animation_Job)
	defer delete(state.animations)
	state.animations[1] = {
		generation = state.manager.windows[1].generation,
		pid = state.manager.windows[1].pid,
		presentation = mac.Animation_Proxy{window = 1},
	}
	state.windows = make(map[u32]mac.Ref)
	defer delete(state.windows)
	// A real AX application reference has no window frame attributes. This
	// exercises the production writer's error path without moving any window.
	element := mac.AXUIElementCreateApplication(mac.getpid())
	defer mac.CFRelease(element)
	state.windows[1] = element
	backend := mac.animation_backend(&state)
	testing.expect(t, backend.apply(&state, 1, {0, 0, 100, 100}) != "")
	testing.expect_value(t, len(state.animations), 1)
	testing.expect_value(t, animation.restored, 0)
	testing.expect_value(t, animation.destroyed, 0)
	testing.expect_value(t, state.frame_updates.depth, 0)
}

@(test)
drag_reset_releases_grab_and_keeps_input_observers :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	state.mouse.drag.window = 1; state.mouse.phase = .Released_Drag
	state.mouse.mode = .Native_Resize; state.mouse.pending = true
	state.mouse.resize_frame = resize_frame_from_pointer
	state.mouse.hit_test = resize_hit_test
	state.mouse.hover = 2; state.mouse.scroll_delta = 17
	state.manager.native_resize_window = 1
	state.manager.windows[1].grabbed = true
	state.mouse.down = mac.CGEventCreate(nil)
	mac.mouse_drag_release(&state)
	testing.expect(
		t,
		state.mouse.down == nil && !state.manager.windows[1].grabbed,
	)
	testing.expect_value(t, state.manager.native_resize_window, u32(1))
	mac.mouse_drag_reset(&state)
	testing.expect_value(t, state.mouse.phase, mac.Drag_Phase.Idle)
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	testing.expect_value(t, state.manager.native_resize_window, u32(0))
	testing.expect(
		t,
		!state.manager.windows[1].grabbed && !state.mouse.pending,
	)
	testing.expect(t, state.mouse.resize_frame == resize_frame_from_pointer)
	testing.expect(t, state.mouse.hit_test == resize_hit_test)
	testing.expect_value(t, state.mouse.hover, u32(2))
	testing.expect_value(t, state.mouse.scroll_delta, f64(17))
}

@(test)
failed_native_geometry_does_not_replace_a_known_frame :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	m.windows[1].frame = {10, 20, 800, 600}
	before := m.windows[1].frame
	mac.reconcile_window_model(
		&m,
		mac.Window {
			id = 1,
			pid = m.windows[1].pid,
			frame = {},
			title = "temporary failure",
		},
	)
	testing.expect_value(t, m.windows[1].frame, before)
}

frame_read_probe :: proc(
	element: mac.Ref,
	name: string,
	kind: u32,
	output: rawptr,
) -> bool {
	if uintptr(element) == uintptr(kind) {
		return false
	}
	if kind == 1 {
		(^mac.Point)(output)^ = {10, 20}
	} else {
		(^mac.Size)(output)^ = {800, 600}
	}
	return true
}
@(test)
partial_native_frame_reads_are_explicitly_invalid :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		mac.window_frame(nil, frame_read_probe).? or_else mac.Rect{},
		mac.Rect{10, 20, 800, 600},
	)
	for kind in 1 ..= 2 { testing.expect(t, mac.window_frame(rawptr(uintptr(kind)), frame_read_probe) == nil) }
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	m.windows[1].frame = {10, 20, 800, 600}
	mac.reconcile_window_model(
		&m,
		mac.Window {
			id = 1,
			pid = m.windows[1].pid,
			frame_valid = false,
			frame = {500, 500, 400, 300},
		},
	)
	testing.expect_value(t, m.windows[1].frame, mac.Rect{10, 20, 800, 600})
}

@(test)
callback_scratch_reuses_storage_without_invalidating_nested_callbacks :: proc(
	t: ^testing.T,
) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	scratch: mac.Callback_Scratch
	allocations: i64
	for i in 0 ..< 1000 {
		outer := mac.callback_scratch_begin(&scratch)
		bytes := make([]u8, 32, mem.dynamic_arena_allocator(outer))
		bytes[0] = 123
		inner := mac.callback_scratch_begin(&scratch)
		inside := make([]u8, 32, mem.dynamic_arena_allocator(inner))
		inside[0] = 42
		mac.callback_scratch_end(&scratch)
		testing.expect_value(t, bytes[0], u8(123))
		mac.callback_scratch_end(&scratch)
		if i == 1 {
			allocations = track.total_allocation_count
		}
	}
	testing.expect_value(t, track.total_allocation_count, allocations)
	mac.callback_scratch_destroy(&scratch)
	testing.expect_value(t, track.current_memory_allocated, i64(0))
}

@(test)
unchanged_observations_reuse_owned_maps_and_strings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	mac.observe_changes(&state); mac.observe_changes(&state)
	before := track.total_allocation_count
	for _ in 0 ..< 1000 { mac.observe_changes(&state) }
	testing.expect_value(t, track.total_allocation_count, before)
	mac.remove_window(&state.manager, 1)
	mac.observe_changes(&state); mac.observe_changes(&state)
	testing.expect_value(t, len(state.observed.windows), 1)
	mac.observations_destroy(&state)
	mac.manager_destroy(&state.manager); delete(r.actions)
	testing.expect_value(t, track.current_memory_allocated, i64(0))
}

@(test)
appearance_accepts_observed_zero_sublevel :: proc(t: ^testing.T) {
	w := mac.Window {
		layer     = "above",
		sub_level = 3,
	}
	mac.reconcile_window_appearance(&w, {sub_level = i32(0)})
	testing.expect_value(t, w.sub_level, i32(0))
	testing.expect_value(t, w.layer, "normal")
}

@(test)
sublevel_reply_requires_a_complete_successful_matching_message :: proc(
	t: ^testing.T,
) {
	reply := mac.Sublevel_Message {
		size  = 40,
		id    = 0x7747,
		ndr   = {0, 0, 0, 0, 1, 0, 0, 0},
		value = -20,
	}
	testing.expect_value(
		t,
		mac.decode_sublevel_reply(&reply, 0x76e3).? or_else 999,
		i32(-20),
	)
	reply.value = 0
	testing.expect(t, mac.decode_sublevel_reply(&reply, 0x76e3) != nil)
	reply.size = 36
	testing.expect(t, mac.decode_sublevel_reply(&reply, 0x76e3) == nil)
	reply.size = 40; reply.id += 1
	testing.expect(t, mac.decode_sublevel_reply(&reply, 0x76e3) == nil)
	reply.id -= 1; reply.code = 5
	testing.expect(t, mac.decode_sublevel_reply(&reply, 0x76e3) == nil)
	reply.code = 0; reply.bits = 0x80000000
	testing.expect(t, mac.decode_sublevel_reply(&reply, 0x76e3) == nil)
	reply.bits = 0; reply.ndr[4] = 0
	testing.expect(t, mac.decode_sublevel_reply(&reply, 0x76e3) == nil)
}

@(test)
readback_symbol_lookup_respects_loaded_image_table_bounds :: proc(
	t: ^testing.T,
) {
	Image :: struct {
		header: mac.Readback_Header,
		text, linkedit: mac.Readback_Segment,
		table: mac.Readback_Symtab,
		symbol: mac.Readback_Symbol,
		names: [32]u8,
	}
	image: Image
	base := u64(uintptr(&image))
	image.header = {
		magic         = 0xfeedfacf,
		commands      = 3,
		commands_size = 2 *
			size_of(mac.Readback_Segment) + size_of(mac.Readback_Symtab),
	}
	image.text = {
		kind    = 0x19,
		size    = size_of(mac.Readback_Segment),
		address = base,
		vm_size = size_of(Image),
	}
	image.linkedit = {
		kind      = 0x19,
		size      = size_of(mac.Readback_Segment),
		address   = base,
		file_size = size_of(Image),
	}
	for ch, index in "__TEXT" { image.text.name[index] = u8(ch) }
	for ch, index in "__LINKEDIT" { image.linkedit.name[index] = u8(ch) }
	for ch, index in "_CGSGetConnectionPortById" {
		image.names[index] = u8(ch)
	}
	image.table = {
		kind         = 2,
		size         = size_of(mac.Readback_Symtab),
		symbols      = u32(offset_of(Image, symbol)),
		count        = 1,
		strings      = u32(offset_of(Image, names)),
		strings_size = len(image.names),
	}
	image.symbol = {
		kind  = 0x0e,
		value = base + 4,
	}
	name := "_CGSGetConnectionPortById"
	testing.expect_value(
		t,
		mac.readback_image_symbol(&image, 0, name),
		rawptr(uintptr(base + 4)),
	)
	testing.expect(t, mac.readback_image_symbol(&image, 0, "_missing") == nil)
	image.symbol.name = len(image.names)
	testing.expect(t, mac.readback_image_symbol(&image, 0, name) == nil)
	image.symbol.name = 0; image.table.count = max(u32)
	testing.expect(t, mac.readback_image_symbol(&image, 0, name) == nil)
	image.table.count = 1; image.symbol.value = base + size_of(Image)
	testing.expect(t, mac.readback_image_symbol(&image, 0, name) == nil)
	image.symbol.value = base + 4; image.text.size = 0
	testing.expect(t, mac.readback_image_symbol(&image, 0, name) == nil)
}
