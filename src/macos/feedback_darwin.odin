package macos

import e "../engine"
import "core:fmt"

foreign import feedback_sls "system:SkyLight.framework"
foreign import feedback_cg "system:CoreGraphics.framework"

Feedback_Window :: struct {
	plan: e.Feedback_Plan,
	surface: Owned_Surface,
}
Feedback_Backend :: struct {
	create: proc(
		state: ^State,
		plan: e.Feedback_Plan,
	) -> (
		Owned_Surface,
		string,
	),
	destroy: proc(state: ^State, surface: Owned_Surface),
}

@(default_calling_convention = "c")
foreign feedback_sls {
	SLSOrderWindow :: proc(cid: i32, window: u32, order: i32, relative: u32) -> i32 ---
	SLSSetWindowTags :: proc(cid: i32, window: u32, tags: ^u64, count: uint) -> i32 ---
}
@(default_calling_convention = "c")
foreign feedback_cg {
	CGContextSetRGBFillColor :: proc(ctx: Ref, r, g, b, a: f64) ---
	CGContextSetRGBStrokeColor :: proc(ctx: Ref, r, g, b, a: f64) ---
	CGContextSetLineWidth :: proc(ctx: Ref, width: f64) ---
	CGContextFillRect :: proc(ctx: Ref, rect: e.Rect) ---
	CGContextStrokeRect :: proc(ctx: Ref, rect: e.Rect) ---
}

native_feedback_create :: proc(
	state: ^State,
	plan: e.Feedback_Plan,
) -> (
	surface: Owned_Surface,
	err: string,
) {
	if plan.frame.w <= 2 || plan.frame.h <= 2 {
		return {}, "feedback area is too small"
	}
	surface, err = surface_create(
		state,
		plan.frame,
		plan.window,
		(1 << 1) | (1 << 9),
		13,
		1,
	)
	if err != "" {
		return {}, err
	}
	success := false
	defer {
		if !success {
			surface_destroy(state, surface)
		}
	}
	shadow: u64 = 1 << 3
	SLSSetWindowTags(state.connection, surface.id, &shadow, 64)
	r, g, b, a :=
		f64((plan.color >> 16) & 255) /
		255,
		f64((plan.color >> 8) & 255) /
		255,
		f64(plan.color & 255) /
		255,
		f64(plan.color >> 24) /
		255
	frame := e.Rect{0, 0, plan.frame.w, plan.frame.h}
	CGContextClearRect(surface.ctx, frame)
	CGContextSetRGBFillColor(surface.ctx, r, g, b, a * 0.25)
	CGContextFillRect(surface.ctx, frame)
	CGContextSetRGBStrokeColor(surface.ctx, r, g, b, a)
	CGContextSetLineWidth(surface.ctx, 2)
	CGContextStrokeRect(surface.ctx, {1, 1, frame.w - 2, frame.h - 2})
	CGContextFlush(surface.ctx)
	if error := surface_update(state, surface, surface.frame); error != "" {
		return {}, error
	}
	if SLSOrderWindow(state.connection, surface.id, 1, plan.window) != 0 {
		return {}, "could not order feedback window"
	}
	success = true
	return surface, ""
}

feedback_backend :: proc(state: ^State) -> Feedback_Backend {
	if state.feedback_backend.create != nil {
		return state.feedback_backend
	}
	return {native_feedback_create, surface_destroy}
}

feedback_sync :: proc(state: ^State, plans: map[u32]e.Feedback_Plan) {
	backend := feedback_backend(state)
	removed := make([dynamic]u32, context.temp_allocator)
	for key, window in state.feedback {
		plan, exists := plans[key]
		if !exists || plan != window.plan {
			backend.destroy(state, window.surface); append(&removed, key)
		}
	}
	for key in removed { delete_key(&state.feedback, key) }
	for key, plan in plans {
		if _, exists := state.feedback[key]; exists {
			continue
		}
		surface, err := backend.create(state, plan)
		if err != "" {
			fmt.eprintln("shoji: feedback:", err)
		}
		if state.feedback == nil {
			state.feedback = make(map[u32]Feedback_Window)
		}
		// Cache failed plans too, avoiding a log/allocation storm every frame.
		state.feedback[key] = Feedback_Window{plan, surface}
	}
}

feedback_tick :: proc(state: ^State) {
	plans := make(map[u32]e.Feedback_Plan, context.temp_allocator)
	if !state.read_only {
		for s in state.manager.spaces {
			if plan, valid := e.insertion_feedback(&state.manager, s); valid {
				plans[plan.window] = plan
			}
		}
		mouse := &state.mouse
		if mouse_drag_moved(mouse) &&
		   !mouse_drag_finished(mouse) &&
		   !mouse.failed {
			if plan, valid := e.drag_feedback(
				&state.manager,
				mouse.drag,
				mouse.target,
				mouse.point,
			); valid {
				plans[0] = plan
			}
		}
	}
	feedback_sync(state, plans)
}

feedback_stop :: proc(state: ^State) {
	backend := feedback_backend(state)
	for _, window in state.feedback { backend.destroy(state, window.surface) }
	delete(state.feedback); state.feedback = nil
}
