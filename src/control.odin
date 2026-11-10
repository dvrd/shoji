package shoji

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"
import "core:time"
import health "health"
import ipc "ipc"
import layout "layout"
import n "native"

// Command dispatch
// ------------------------------------------------------------------------

Response :: struct {
	text:   string,
	failed: bool,
}

success :: proc(text: string = "") -> Response {
	return {text, false}
}

failure :: proc(text: string) -> Response {
	return {text, true}
}

result :: proc(err: string) -> Response {
	return {err, err != ""}
}

layout_name :: proc(mode: layout.Layout) -> string {
	switch mode {
	case .BSP:
		return "bsp"
	case .Stack:
		return "stack"
	case .Scroll:
		return "scroll"
	case .Float:
		return "float"
	}
	return "float"
}

parse_layout :: proc(text: string) -> (layout.Layout, bool) {
	switch text {
	case "bsp":
		return .BSP, true
	case "stack":
		return .Stack, true
	case "scroll":
		return .Scroll, true
	case "float":
		return .Float, true
	}
	return .Float, false
}

parse_numbers :: proc(text: string, values: []f64) -> bool {
	parts := strings.split(text, ":", context.temp_allocator)
	if len(parts) != len(values) {
		return false
	}
	for part, i in parts {
		value, ok := strconv.parse_f64(part)
		if !ok || math.is_nan(value) || math.is_inf(value) {
			return false
		}
		values[i] = value
	}
	return true
}

select_display :: proc(m: ^Manager, text: string) -> ^Display {
	if text == "recent" {
		return display_by_id(m, m.last_display)
	}
	if text == "mouse" {
		return display_by_id(m, m.mouse_display)
	}
	current := space_by_id(m, m.active_space)
	if text == "" {
		if current != nil {
			return display_by_id(m, current.display)
		}
		return nil
	}
	if text == "first" && len(m.displays) > 0 {
		return &m.displays[0]
	}
	if text == "last" && len(m.displays) > 0 {
		return &m.displays[len(m.displays) - 1]
	}
	if current != nil && (text == "north" || text == "east" || text == "south" || text == "west") {
		origin := display_by_id(m, current.display)
		if origin == nil {
			return nil
		}
		ox, oy := origin.frame.x + origin.frame.w / 2, origin.frame.y + origin.frame.h / 2
		best: ^Display
		best_score := math.inf_f64(1)
		for &candidate in m.displays {
			if candidate.id == origin.id {
				continue
			}
			x := candidate.frame.x + candidate.frame.w / 2 - ox
			y := candidate.frame.y + candidate.frame.h / 2 - oy
			major, minor: f64
			switch text {
			case "north":
				major, minor = -y, x
			case "east":
				major, minor = x, y
			case "south":
				major, minor = y, x
			case "west":
				major, minor = -x, y
			}
			if major <= 0 {
				continue
			}
			// Prefer the closest display in the requested direction, then the
			// one most aligned with that direction.
			score := major * 10000 + math.abs(minor)
			if score < best_score {
				best, best_score = &candidate, score
			}
		}
		return best
	}
	number, numeric := strconv.parse_u64(text)
	for &d, i in m.displays {
		if (numeric && u64(d.index) == number) || d.label == text {
			return &d
		}
		if current != nil && d.id == current.display && (text == "next" || text == "prev") {
			j := text == "next" ? i + 1 : i - 1
			if j >= 0 && j < len(m.displays) {
				return &m.displays[j]
			}
		}
	}
	return nil
}

execute :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("missing command domain")
	}
	switch args[0] {
	case "debug":
		return motion_debug(m, args[1:])
	case "query":
		return query(m, args[1:])
	case "config":
		return config(m, args[1:])
	case "window":
		return window_command(m, args[1:])
	case "space":
		return space_command(m, args[1:])
	case "display":
		return display_command(m, args[1:])
	case "rule":
		return rule_command(m, args[1:])
	case "signal":
		return signal_command(m, args[1:])
	case "notify":
		if len(args) != 2 || args[1] != "test" {
			return failure("usage: notify test")
		}
		if m.health_notify_test == nil {
			return failure("notifications are posted only by the daemon")
		}
		return m.health_notify_test(m.health_user)
	}
	return failure(errorf("unknown command domain '%s'", args[0]))
}

// Queries
// ------------------------------------------------------------------------

Window_JSON :: struct {
	opening_state:             string `json:"opening-state"`,
	resize_transitioning:      bool `json:"resize-transitioning"`,
	size_request_pending:      bool `json:"size-request-pending"`,
	width_adjusted:            bool `json:"width-adjusted"`,
	height_adjusted:           bool `json:"height-adjusted"`,
	accepted_width:            f64 `json:"accepted-width"`,
	accepted_height:           f64 `json:"accepted-height"`,
	layout_frame:              Rect `json:"layout-frame"`,
	column_index:              int `json:"column-index"`,
	column_tabbed:             bool `json:"column-tabbed"`,
	column_active:             bool `json:"column-active"`,
	column_full:               bool `json:"column-full-width"`,
	column_width_request:      f64 `json:"column-width-request"`,
	column_width_proportional: bool `json:"column-width-proportional"`,
	row_height_request:        f64 `json:"row-height-request"`,
	row_weight:                f64 `json:"row-weight"`,
	id:                        u32,
	pid:                       i32,
	app, title:                string,
	scratchpad:                string,
	frame:                     Rect,
	role, subrole:             string,
	root_window:               bool `json:"root-window"`,
	display:                   u32,
	space:                     u32,
	level:                     int,
	sub_level:                 int `json:"sub-level"`,
	layer:                     string,
	sub_layer:                 string `json:"sub-layer"`,
	opacity:                   f64,
	split_type:                string `json:"split-type"`,
	split_child:               string `json:"split-child"`,
	stack_index:               int `json:"stack-index"`,
	can_move:                  bool `json:"can-move"`,
	can_resize:                bool `json:"can-resize"`,
	has_focus:                 bool `json:"has-focus"`,
	has_shadow:                bool `json:"has-shadow"`,
	has_parent_zoom:           bool `json:"has-parent-zoom"`,
	has_fullscreen_zoom:       bool `json:"has-fullscreen-zoom"`,
	has_ax_reference:          bool `json:"has-ax-reference"`,
	is_native_fullscreen:      bool `json:"is-native-fullscreen"`,
	is_visible:                bool `json:"is-visible"`,
	is_minimized:              bool `json:"is-minimized"`,
	is_hidden:                 bool `json:"is-hidden"`,
	is_floating:               bool `json:"is-floating"`,
	is_sticky:                 bool `json:"is-sticky"`,
	is_grabbed:                bool `json:"is-grabbed"`,
	is_concealed:              bool `json:"is-concealed"`,
}

Space_JSON :: struct {
	scroll_resizing:      bool `json:"scroll-resizing"`,
	scroll_position:      f64 `json:"scroll-position"`,
	scroll_velocity:      f64 `json:"scroll-velocity"`,
	scroll_animating:     bool `json:"scroll-animating"`,
	scroll_interacting:   bool `json:"scroll-interacting"`,
	scroll_offset:        f64 `json:"scroll-offset"`,
	scroll_width:         f64 `json:"scroll-width"`,
	id:                   u64,
	uuid:                 string,
	index:                u32,
	label:                string,
	type:                 string,
	display:              u32,
	windows:              [dynamic]u32,
	first_window:         u32 `json:"first-window"`,
	last_window:          u32 `json:"last-window"`,
	has_focus:            bool `json:"has-focus"`,
	is_visible:           bool `json:"is-visible"`,
	is_native_fullscreen: bool `json:"is-native-fullscreen"`,
}

Display_JSON :: struct {
	id, index:   u32,
	label, uuid: string,
	frame:       Rect,
	spaces:      [dynamic]u32,
	has_focus:   bool `json:"has-focus"`,
}

json_text :: proc(value: $T) -> string {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil {
		return "null"
	}
	return string(data)
}

window_json :: proc(m: ^Manager, w: ^Window) -> Window_JSON {
	result := Window_JSON {
		opening_state        = w.opening.phase == .Pending \
			? (w.opening.wait == .Space \
					? "needs-more-room" \
					: (w.opening.wait == .Backend ? "waiting-for-backend" : "preparing")) \
			: (w.opening.phase == .Opening ? "opening" : "settled"),
		resize_transitioning = w.resize_transitioning,
		size_request_pending = w.size_feedback.pending,
		width_adjusted       = w.size_feedback.width_valid,
		height_adjusted      = w.size_feedback.height_valid,
		accepted_width       = w.size_feedback.width_valid ? w.size_feedback.accepted.w : 0,
		accepted_height      = w.size_feedback.height_valid ? w.size_feedback.accepted.h : 0,
		id                   = w.id,
		pid                  = w.pid,
		app                  = w.app,
		title                = w.title,
		frame                = w.frame,
		role                 = w.role,
		subrole              = w.subrole,
		root_window          = w.root_window.? or_else true,
		is_grabbed           = w.grabbed,
		is_concealed         = w.concealed,
		scratchpad           = w.scratchpad,
		opacity              = w.opacity,
		layer                = w.layer,
		level                = int(w.level),
		sub_level            = int(w.sub_level),
		sub_layer            = w.layer,
		has_focus            = w.focused,
		has_shadow           = w.shadow,
		can_move             = w.can_move,
		can_resize           = w.can_resize.? or_else false,
		has_ax_reference     = true,
		is_native_fullscreen = w.fullscreen,
		is_minimized         = w.minimized,
		is_hidden            = w.hidden,
		is_floating          = w.floating,
		is_sticky            = w.sticky,
		is_visible           = (w.ordered_in.? or_else true) && !w.hidden && !w.minimized && !w.scratchpad_hidden,
		split_type           = "none",
		split_child          = "none",
	}
	if d := display_by_id(m, w.display); d != nil {
		result.display = d.index
	}
	if s := space_by_id(m, w.space); s != nil {
		result.space = s.index
		result.is_visible = result.is_visible && (w.sticky || s.visible)
		if n := layout.find(s.view.root, w.id); n != nil {
			if s.view.layout == .Scroll {
				result.layout_frame = size_feedback_frame(
					w,
					layout.scroll_window_frame(&s.view, n, w.id, false),
				)
				result.column_tabbed, result.column_active, result.column_full =
					n.column_tabbed, n.order[0] == w.id, n.column_full
				size :=
					n.column_size.kind == .Default \
						? s.view.scroll_options.default_width \
						: n.column_size
				result.column_width_request, result.column_width_proportional =
					size.value, size.kind == .Proportion
				result.row_height_request, result.row_weight =
					w.row_fixed, w.row_weight > 0 ? w.row_weight : 1
				for column := layout.first(s.view.root);
				    column != nil;
				    column = layout.next(column) {
					result.column_index += 1; if column == n {
						break
					}
				}
			}
			for i in 0 ..< n.count {
				if n.windows[i] == w.id {
					result.stack_index = i + 1
				}
			}
			if p := n.parent; p != nil {
				result.split_type = p.split == .Vertical ? "vertical" : "horizontal"
				result.split_child = p.left == n ? "first_child" : "second_child"
				result.has_parent_zoom = n.zoom == p
			}
			result.has_fullscreen_zoom = n.zoom == s.view.root
		}
	}
	return result
}

space_json :: proc(m: ^Manager, s: ^Space) -> Space_JSON {
	result := Space_JSON {
		scroll_resizing      = s.view.scroll.geometry_active,
		scroll_position      = m.scroll_animate && s.view.scroll.motion.initialized \
			? s.view.scroll.motion.position \
			: s.view.scroll.offset,
		scroll_velocity      = s.view.scroll.motion.velocity,
		scroll_animating     = s.view.scroll.motion.active,
		scroll_interacting   = s.view.scroll.dragging,
		scroll_offset        = s.view.scroll.offset,
		scroll_width         = s.view.scroll.content_width,
		id                   = s.id,
		uuid                 = s.uuid,
		index                = s.index,
		label                = s.label,
		type                 = layout_name(s.view.layout),
		has_focus            = s.id == m.active_space,
		is_visible           = s.visible,
		is_native_fullscreen = s.fullscreen,
	}
	if d := display_by_id(m, s.display); d != nil {
		result.display = d.index
	}
	result.windows = make([dynamic]u32, 0, 8, context.temp_allocator)
	for id, w in m.windows {
		if w.space == s.id {
			append(&result.windows, id)
		}
	}
	sort_ids(result.windows[:])
	if n := layout.first(s.view.root); n != nil && n.count > 0 {
		result.first_window = n.windows[0]
	}
	if n := layout.last(s.view.root); n != nil && n.count > 0 {
		result.last_window = n.windows[n.count - 1]
	}
	return result
}

sort_ids :: proc(ids: []u32) {
	for i in 1 ..< len(ids) {
		j := i
		for j > 0 && ids[j] < ids[j - 1] {
			ids[j], ids[j - 1] = ids[j - 1], ids[j]
			j -= 1
		}
	}
}

query :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 1 && args[0] == "--health" {
		if m.health_report == nil {
			return failure("health is reported only by the daemon")
		}
		return success(m.health_report(m.health_user))
	}
	if len(args) < 2 || strings.has_prefix(args[1], "--") {
		return query_full(m, args)
	}
	fields := strings.split(args[1], ",", context.temp_allocator)
	schema: string
	switch args[0] {
	case "--windows":
		schema = json_text(Window_JSON{})
	case "--spaces":
		schema = json_text(Space_JSON{})
	case "--displays":
		schema = json_text(Display_JSON{})
	case:
		return failure("unknown query")
	}
	shape, err := json.parse(schema, allocator = context.temp_allocator)
	if err != nil {
		return failure("could not inspect query schema")
	}
	object := shape.(json.Object)
	for field in fields {
		if _, exists := object[field]; !exists {
			return failure(errorf("unknown query property '%s'", field))
		}
	}
	clean := make([dynamic]string, 0, len(args) - 1, context.temp_allocator)
	append(&clean, args[0]); append(&clean, ..args[2:])
	response := query_full(m, clean[:])
	if response.failed {
		return response
	}
	value, parse_err := json.parse(
		response.text,
		parse_integers = true,
		allocator = context.temp_allocator,
	)
	if parse_err != nil {
		return failure("could not parse query output")
	}
	projected := project_query(value, fields)
	data, marshal_err := json.unparse(projected, allocator = context.temp_allocator)
	if marshal_err != nil {
		return failure("could not encode projected query")
	}
	return success(data)
}

project_query :: proc(value: json.Value, fields: []string) -> json.Value {
	#partial switch v in value {
	case json.Object:
		object := make(json.Object, context.temp_allocator)
		for field in fields {object[field] = v[field]}
		return object
	case json.Array:
		array := make(json.Array, 0, len(v), context.temp_allocator)
		for item in v {append(&array, project_query(item, fields))}
		return array
	case:
		return value
	}
}

query_full :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("query expects --windows, --spaces, or --displays")
	}
	kind := args[0]
	selector, filter := "", ""
	if len(args) > 1 {
		filter = args[1]
		if filter != "--window" && filter != "--space" && filter != "--display" {
			return failure("invalid query filter")
		}
		if len(args) > 2 {
			selector = args[2]
		}
		if len(args) > 3 {
			return failure("too many query arguments")
		}
	}
	window: ^Window
	space: ^Space
	display: ^Display
	switch filter {
	case "--window":
		window = select_window(m, selector)
		if window == nil {
			return failure("could not locate window")
		}
	case "--space":
		space = select_space(m, selector)
		if space == nil {
			return failure("could not locate space")
		}
	case "--display":
		display = select_display(m, selector)
		if display == nil {
			return failure("could not locate display")
		}
	}
	switch kind {
	case "--windows":
		if window != nil {
			return success(json_text(window_json(m, window)))
		}
		result := make([dynamic]Window_JSON, 0, len(m.windows), context.temp_allocator)
		ids := make([dynamic]u32, 0, len(m.windows), context.temp_allocator)
		for id in m.windows {
			append(&ids, id)
		}
		sort_ids(ids[:])
		for id in ids {
			w := m.windows[id]
			if space != nil && w.space != space.id {
				continue
			}
			if display != nil && w.display != display.id {
				continue
			}
			append(&result, window_json(m, w))
		}
		return success(json_text(result))
	case "--spaces":
		if window != nil {
			space = space_by_id(m, window.space)
		}
		if space != nil {
			return success(json_text(space_json(m, space)))
		}
		result := make([dynamic]Space_JSON, 0, len(m.spaces), context.temp_allocator)
		for s in m.spaces {
			if display == nil || s.display == display.id {
				append(&result, space_json(m, s))
			}
		}
		return success(json_text(result))
	case "--displays":
		if window != nil {
			display = display_by_id(m, window.display)
		}
		if space != nil {
			display = display_by_id(m, space.display)
		}
		result := make([dynamic]Display_JSON, 0, len(m.displays), context.temp_allocator)
		for d in m.displays {
			if display != nil && d.id != display.id {
				continue
			}
			r := Display_JSON {
				id        = d.id,
				index     = d.index,
				label     = d.label,
				uuid      = d.uuid,
				frame     = d.frame,
				has_focus = d.active_space == m.active_space,
			}
			r.spaces = make([dynamic]u32, 0, len(d.spaces), context.temp_allocator)
			for id in d.spaces {
				if s := space_by_id(m, id); s != nil {
					append(&r.spaces, s.index)
				}
			}
			append(&result, r)
		}
		if display != nil && len(result) > 0 {
			return success(json_text(result[0]))
		}
		return success(json_text(result))
	}
	return failure(strings.concatenate({"unknown query '", kind, "'"}, context.temp_allocator))
}

// Space commands
// ------------------------------------------------------------------------

space_command :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) == 0 || len(args) > 2 {
		return failure("expected space operation and optional operand")
	}
	s := select_space(m, selector)
	op := args[0]
	operand := len(args) > 1 ? args[1] : ""
	if op == "--focus" && operand != "" {
		s = select_space(m, operand)
	}
	if op == "--destroy" && operand != "" {
		s = select_space(m, operand)
	}
	if op == "--create" && operand != "" {
		if d := select_display(m, operand); d != nil {
			s = space_by_id(m, d.active_space)
		} else {
			return failure("could not locate display")
		}
	}
	if s == nil {
		return failure("could not locate space")
	}
	switch op {
	case "--scroll":
		if s.view.layout != .Scroll {
			return failure("scroll requires scroll layout")
		}
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 2 {
			return failure("scroll expects abs:pixels or rel:pixels")
		}
		value, ok := strconv.parse_f64(parts[1])
		if !ok || math.is_nan(value) || math.is_inf(value) {
			return failure("invalid scroll offset")
		}
		switch parts[0] {
		case "abs":
		case "rel":
			value += s.view.scroll.offset
		case:
			return failure("scroll expects abs or rel")
		}
		layout.scroll_pan(&s.view, value)
		s.view.scroll.centered = false
		s.view.scroll.focused = m.focused; s.view.scroll.reveal = false
	case "--layout":
		layout, ok := parse_layout(operand)
		if !ok {
			return failure("invalid layout")
		}
		set_layout(m, s, layout)
		s.overrides["layout"] = true
	case "--rotate":
		if s.view.layout == .Scroll {
			return failure("rotation is unavailable in scroll layout")
		}
		angle, ok := strconv.parse_int(operand)
		if !ok || (angle != 90 && angle != 180 && angle != 270) {
			return failure("rotate expects 90, 180, or 270")
		}
		layout.rotate(s.view.root, angle)
	case "--mirror":
		if s.view.layout == .Scroll {
			return failure("mirroring is unavailable in scroll layout")
		}
		if operand != "x-axis" && operand != "y-axis" {
			return failure("mirror expects x-axis or y-axis")
		}
		layout.mirror(s.view.root, operand == "x-axis" ? .Horizontal : .Vertical)
	case "--balance", "--equalize":
		if s.view.layout == .Scroll {
			return failure("balance/equalize split ratios are unavailable in scroll layout")
		}
		axis: layout.Split
		switch operand {
		case "", "both":
			axis = .Auto
		case "x-axis":
			axis = .Horizontal
		case "y-axis":
			axis = .Vertical
		case:
			return failure("invalid axis")
		}
		if op == "--balance" {
			layout.balance(s.view.root, axis)
		} else {
			layout.equalize(s.view.root, axis, s.view.ratio)
		}
	case "--label":
		delete(s.label)
		s.label = strings.clone(operand)
		workspace_reconcile(m)
	case "--toggle":
		switch operand {
		case "padding":
			s.view.padding_enabled = !s.view.padding_enabled
		case "gap":
			s.view.gap_enabled = !s.view.gap_enabled
		case:
			return failure("toggle expects padding or gap")
		}
	case "--padding":
		parts := strings.split(operand, ":", context.temp_allocator)
		values: [4]f64
		if len(parts) != 5 ||
		   !parse_numbers(strings.join(parts[1:], ":", context.temp_allocator), values[:]) {
			return failure("padding expects abs|rel:top:bottom:left:right")
		}
		p := layout.Padding{values[0], values[1], values[2], values[3]}
		if parts[0] == "rel" {
			p.top += s.view.padding.top
			p.bottom += s.view.padding.bottom
			p.left += s.view.padding.left
			p.right += s.view.padding.right
		} else if parts[0] != "abs" {
			return failure("invalid padding mode")
		}
		if min(p.top, p.bottom, p.left, p.right) < 0 {
			return failure("padding cannot be negative")
		}
		s.view.padding = p
		for key in ([]string {
				"top_padding",
				"bottom_padding",
				"left_padding",
				"right_padding",
			}) {s.overrides[key] = true}
	case "--gap":
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 2 {
			return failure("gap expects abs:value or rel:value")
		}
		value, ok := strconv.parse_f64(parts[1])
		if !ok || math.is_nan(value) || math.is_inf(value) {
			return failure("invalid gap")
		}
		if parts[0] == "rel" {
			value += s.view.gap
		} else if parts[0] != "abs" {
			return failure("invalid gap mode")
		}
		if value < 0 {
			return failure("gap cannot be negative")
		}
		s.view.gap = value
		s.overrides["window_gap"] = true
	case "--focus":
		return result(perform(m, Action{kind = .Space_Focus, space = s.id}))
	case "--create":
		return result(perform(m, Action{kind = .Space_Create, space = s.id}))
	case "--destroy":
		return result(perform(m, Action{kind = .Space_Destroy, space = s.id}))
	case "--move":
		target := select_space(m, operand)
		if target == nil {
			return failure("could not locate target space")
		}
		if s == target {
			return success()
		}
		if s.display != target.display {
			return failure("space --move requires the same display; use --display")
		}
		if s.fullscreen || target.fullscreen {
			return failure("cannot reorder native fullscreen spaces")
		}
		if s.index < target.index {
			return result(move_space_after(m, s, target))
		}
		previous := previous_space_on_display(m, target)
		if previous != nil {
			return result(move_space_after(m, s, previous))
		}
		return result(move_space_pair(m, s, target, target, s))
	case "--swap", "--switch":
		target := select_space(m, operand)
		if op == "--switch" {
			s = select_space(m, "")
		}
		if target == nil || s == nil {
			return failure("could not locate target space")
		}
		if s == target {
			return success()
		}
		if s.fullscreen || target.fullscreen {
			return failure("cannot swap native fullscreen spaces")
		}
		if op == "--switch" && s.display == target.display {
			return result(perform(m, {kind = .Space_Focus, space = target.id}))
		}
		if s.display != target.display {
			if err := swap_space_windows(m, s, target); err != "" {
				return failure(err)
			}
		} else {
			earlier, later := s, target
			if earlier.index > later.index {
				earlier, later = later, earlier
			}
			previous := previous_space_on_display(m, later)
			if previous == earlier {
				previous = later
			}
			if err := move_space_pair(m, later, earlier, earlier, previous); err != "" {
				return failure(err)
			}
		}
		if op == "--switch" {
			return result(perform(m, {kind = .Space_Focus, space = target.id}))
		}
		return success()
	case "--vertical":
		return result(workspace_vertical(m, s, operand))
	case "--send-window":
		return result(workspace_send(m, operand, false))
	case "--send-column":
		return result(workspace_send(m, operand, true))
	case "--nudge":
		return result(workspace_nudge(m, s, operand))
	case "--overview":
		return result(workspace_overview_command(m, s, operand))
	case "--display":
		d := select_display(m, operand)
		if d == nil {
			return failure("could not locate display")
		}
		if s.display == d.id {
			return success()
		}
		if s.fullscreen {
			return failure("cannot move a native fullscreen space")
		}
		return result(perform(m, {kind = .Space_Move, space = s.id, destination = d.active_space}))
	case:
		return failure(errorf("unsupported space operation '%s'", op))
	}
	return result(flush(m, s))
}

previous_space_on_display :: proc(m: ^Manager, target: ^Space) -> ^Space {
	previous: ^Space
	for s in m.spaces {
		if s == target {
			return previous
		}; if s.display == target.display {
			previous = s
		}
	}
	return nil
}

move_space_pair :: proc(
	m: ^Manager,
	first, first_anchor, second, second_anchor: ^Space,
) -> string {
	original := make([dynamic]^Space, context.temp_allocator)
	for space in m.spaces {
		if space.display == first.display {
			append(&original, space)
		}
	}
	if err := move_space_after(m, first, first_anchor); err != "" {
		return err
	}
	if err := move_space_after(m, second, second_anchor); err != "" {
		// Rebuild the original adjacency through real backend moves. Updating only
		// the array would conceal the partial reorder that already reached Dock.
		for i in 1 ..< len(original) {
			space, anchor := original[i], original[i - 1]
			if previous_space_on_display(m, space) == anchor {
				continue
			}
			if rollback := move_space_after(m, space, anchor); rollback != "" {
				return errorf("%s; rollback failed: %s", err, rollback)
			}
		}
		return err
	}
	return ""
}

move_space_after :: proc(m: ^Manager, s, anchor: ^Space) -> string {
	if s == nil || anchor == nil || s == anchor {
		return "invalid space move"
	}
	if err := perform(m, {kind = .Space_Move, space = s.id, destination = anchor.id}); err != "" {
		return err
	}
	from, to := -1, -1
	for space, i in m.spaces {
		if space == s {
			from = i
		}; if space == anchor {
			to = i
		}
	}
	if from > to {
		to += 1
	}
	if from < to {
		for j := from; j < to; j += 1 {m.spaces[j] = m.spaces[j + 1]}
	}
	if from > to {
		for j := from; j > to; j -= 1 {m.spaces[j] = m.spaces[j - 1]}
	}
	m.spaces[to] = s
	for &d in m.displays {clear(&d.spaces)}
	for space, i in m.spaces {
		space.index = u32(i + 1)
		if d := display_by_id(m, space.display); d != nil {
			append(&d.spaces, space.id)
		}
	}
	return ""
}

Space_Window_Move :: struct {
	window:         ^Window,
	source, target: ^Space,
	moved:          bool,
}
swap_space_windows :: proc(m: ^Manager, a, b: ^Space) -> string {
	moves := make([dynamic]Space_Window_Move, context.temp_allocator)
	for _, w in m.windows {
		if w.space == a.id {
			append(&moves, Space_Window_Move{w, a, b, false})
		}
		if w.space == b.id {
			append(&moves, Space_Window_Move{w, b, a, false})
		}
	}
	err := ""
	for &move in moves {
		if error := perform(m, {kind = .Space, window = move.window.id, space = move.target.id});
		   error != "" {
			err = error; break
		}
		move.moved = true
	}
	if err != "" {
		for &move in moves {
			if move.moved {
				if rollback := perform(
					m,
					{kind = .Space, window = move.window.id, space = move.source.id},
				); rollback == "" {
					move.moved = false
				} else {
					err = errorf("%s; rollback failed: %s", err, rollback)
				}
			}
		}
	}
	for move in moves {
		if !move.moved {
			continue
		}
		move.window.space, move.window.display = move.target.id, move.target.display
		if err != "" {
			layout.remove(&move.source.view, move.window.id)
			if layout_admitted(move.window) {
				layout.add(&move.target.view, move.window.id)
			}
		}
	}
	if err != "" {
		return err
	}
	// The windows and their complete virtual desktop move together. Keep native
	// Space identity and destination geometry, including when one side is empty.
	a_frame, b_frame := a.view.frame, b.view.frame
	a.view, b.view = b.view, a.view
	a.view.frame, b.view.frame = a_frame, b_frame
	a.overrides, b.overrides = b.overrides, a.overrides
	a.label, b.label = b.label, a.label
	if err := flush(m, a); err != "" {
		return err
	}
	return flush(m, b)
}

// Display commands
// ------------------------------------------------------------------------

display_command :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) < 1 || len(args) > 2 || (args[0] != "--label" && len(args) != 2) {
		return failure("display expects --focus selector, --space selector, or --label [label]")
	}
	if args[0] == "--focus" {
		selector = args[1]
	}
	d := select_display(m, selector)
	if d == nil {
		return failure("could not locate display")
	}
	if args[0] == "--label" {
		delete(d.label)
		d.label = len(args) == 2 ? strings.clone(args[1]) : ""
		return success()
	}
	if args[0] == "--space" {
		s := select_space(m, args[1])
		if s == nil {
			return failure("could not locate space")
		}
		if s.display != d.id {
			return failure("space must belong to the selected display")
		}
		return result(perform(m, Action{kind = .Space_Focus, space = s.id}))
	}
	if args[0] == "--focus" {
		return result(
			perform(m, Action{kind = .Display_Focus, display = d.id, space = d.active_space}),
		)
	}
	return failure("unsupported display operation")
}

Unix_Address :: n.Unix_Address
Timeval :: n.Timeval
Poll_FD :: n.Poll_FD
socket :: n.socket
bind :: n.bind
connect :: n.connect
listen :: n.listen
accept :: n.accept
close :: n.close
shutdown :: n.shutdown
recv :: n.recv
send :: n.send
setsockopt :: n.setsockopt
chmod :: n.chmod
unlink :: n.unlink
flock :: n.flock
poll :: n.poll
getpeereid :: n.getpeereid
address :: n.address
prepare_socket :: n.prepare_socket
connect_socket :: n.connect_socket
wait_socket :: n.wait_socket
read_exact :: n.read_exact
write_all :: n.write_all

// Nonblocking command server
// ------------------------------------------------------------------------

MAX_COMMAND_CLIENTS :: 32
COMMAND_BYTE_BUDGET :: 64 * 1024
Pending_Command :: struct {
	watch:    Socket_Watch,
	fd:       i32,
	header:   [4]u8,
	data:     []u8,
	received: int,
	output:   string,
	sent:     int,
	deadline: time.Time,
}
Command_Server :: struct {
	listener:                    Socket_Watch,
	listener_fd, listener_flags: i32,
	event_driven:                bool,
	clients:                     [dynamic]Pending_Command,
}

command_accept :: proc(
	server: ^Command_Server,
	fd: i32,
	timeout: time.Duration = 2 * time.Second,
) -> bool {
	prepare_socket(fd)
	uid, gid: u32
	if len(server.clients) >= MAX_COMMAND_CLIENTS ||
	   getpeereid(fd, &uid, &gid) != 0 ||
	   uid != getuid() {
		close(fd); return false
	}
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 || posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		close(fd); return false
	}
	client := Pending_Command {
		fd       = fd,
		deadline = time.time_add(time.now(), timeout),
	}
	if server.event_driven && !socket_watch_start(&client.watch, fd, 1) {
		close(fd); return false
	}
	append(&server.clients, client)

	return true
}

command_close :: proc(client: ^Pending_Command) {
	socket_watch_stop(&client.watch)
	close(client.fd); delete(client.data); delete(client.output)
}
command_server_stop :: proc(server: ^Command_Server) {
	socket_watch_stop(&server.listener)
	if server.event_driven {
		posix.fcntl(posix.FD(server.listener_fd), .SETFL, server.listener_flags)
	}
	for &client in server.clients {command_close(&client)}
	delete(server.clients); server^ = {}
}

command_reply :: proc(client: ^Pending_Command, response: Response, now: time.Time) {
	// Query/error text can borrow the tick arena; responses must own their bytes
	// until a slow reader has drained them or its fixed deadline expires.
	client.output = fmt.aprintf("%s%s\n", response.failed ? "\a" : "", response.text)
	client.deadline = time.time_add(now, 2 * time.Second)
}

command_tick :: proc(client: ^Pending_Command, manager: ^Manager, now: time.Time) -> bool {
	if time.diff(now, client.deadline) <= 0 {
		return true
	}
	budget := COMMAND_BYTE_BUDGET
	for client.output == "" && budget > 0 {
		buffer: []u8
		if client.received < 4 {
			buffer = client.header[client.received:]
		} else {
			buffer = client.data[client.received:]
		}
		buffer = buffer[:min(len(buffer), budget)]
		n := recv(client.fd, raw_data(buffer), uint(len(buffer)), 0x80) // MSG_DONTWAIT
		if n < 0 && (__error()^ == 35 || __error()^ == 4) {
			return false
		}
		if n <= 0 {
			return true
		}
		client.received += n; budget -= n
		if client.received == 4 && client.data == nil {
			h := client.header
			count := u32(h[0]) | u32(h[1]) << 8 | u32(h[2]) << 16 | u32(h[3]) << 24
			if count < 2 || count > ipc.MAX_MESSAGE {
				command_reply(client, failure("invalid message length"), now)
				break
			}
			client.data = make([]u8, int(count) + 4)
			copy(client.data, h[:])
		}
		if client.data != nil && client.received == len(client.data) {
			args, valid := ipc.decode_message(client.data)
			defer delete(args)
			// Discovery or another client can block after the loop was sampled.
			// Start this action now, otherwise its first animation frame may
			// already be past the settling deadline.
			if valid {
				manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, time.now()))
				motion_trace_record(&manager.motion_trace, {kind = "command"})
			}
			response := valid ? execute(manager, args[:]) : failure("malformed message")
			command_reply(client, response, time.now())
		}
	}
	if client.output != "" {
		buffer := transmute([]u8)client.output[client.sent:]
		buffer = buffer[:min(len(buffer), COMMAND_BYTE_BUDGET)]
		n := send(client.fd, raw_data(buffer), uint(len(buffer)), 0x80)
		if n < 0 && (__error()^ == 35 || __error()^ == 4) {
			return false
		}
		if n <= 0 {
			return true
		}
		client.sent += n
		return client.sent == len(client.output)
	}
	return false
}

command_server_tick :: proc(server: ^Command_Server, manager: ^Manager, now: time.Time = {}) {
	now := now
	if (now == time.Time{}) {
		now = time.now()
	}
	if server.event_driven {
		// Nonblocking and bounded even if the backlog refills while it is drained.
		for _ in 0 ..< MAX_COMMAND_CLIENTS {
			fd := accept(server.listener_fd, nil, nil)
			if fd < 0 {
				break
			}
			command_accept(server, fd)
		}
		socket_watch_arm(&server.listener, 1)
	}
	for i := 0; i < len(server.clients); {
		if command_tick(&server.clients[i], manager, now) {
			command_close(&server.clients[i])
			ordered_remove(&server.clients, i)
		} else {
			socket_watch_arm(&server.clients[i].watch, server.clients[i].output == "" ? 1 : 2)
			i += 1
		}
	}
}

// Native callbacks carry no pointers into the movable client array. They only
// wake CFRunLoopRunInMode; command execution stays in the outer daemon tick.
Socket_Watch :: struct {
	descriptor, source, loop: Ref,
}
File_Descriptor_Context :: struct {
	version:                         int,
	info, retain, release, describe: rawptr,
}
foreign import ipc_cf "system:CoreFoundation.framework"
foreign ipc_cf {
	CFRunLoopGetCurrent :: proc "c" () -> Ref ---
	CFFileDescriptorCreate :: proc "c" (allocator: Ref, fd: i32, close_on_invalidate: bool, callback: proc "c" (_: Ref, _: uint, _: rawptr), info: ^File_Descriptor_Context) -> Ref ---
	CFFileDescriptorCreateRunLoopSource :: proc "c" (allocator, descriptor: Ref, order: int) -> Ref ---
	CFFileDescriptorEnableCallBacks :: proc "c" (descriptor: Ref, events: uint) ---
	CFFileDescriptorDisableCallBacks :: proc "c" (descriptor: Ref, events: uint) ---
	CFFileDescriptorInvalidate :: proc "c" (descriptor: Ref) ---
}
socket_ready :: proc "c" (_: Ref, _: uint, _: rawptr) {}
socket_watch_stop :: proc(watch: ^Socket_Watch) {
	if watch.source != nil {
		CFRunLoopRemoveSource(watch.loop, watch.source, kCFRunLoopDefaultMode)
		CFRelease(watch.source)
	}
	if watch.descriptor != nil {
		CFFileDescriptorInvalidate(watch.descriptor)
		CFRelease(watch.descriptor)
	}
	if watch.loop != nil {
		CFRelease(watch.loop)
	}
	watch^ = {}
}
socket_watch_arm :: proc(watch: ^Socket_Watch, events: uint) {
	if watch.descriptor == nil {
		return
	}
	CFFileDescriptorDisableCallBacks(watch.descriptor, 3)
	CFFileDescriptorEnableCallBacks(watch.descriptor, events)
}
socket_watch_start :: proc(watch: ^Socket_Watch, fd: i32, events: uint) -> bool {
	assert(watch.descriptor == nil)
	info: File_Descriptor_Context
	watch.descriptor = CFFileDescriptorCreate(nil, fd, false, socket_ready, &info)
	if watch.descriptor == nil {
		return false
	}
	watch.source = CFFileDescriptorCreateRunLoopSource(nil, watch.descriptor, 0)
	if watch.source == nil {
		socket_watch_stop(watch); return false
	}
	watch.loop = CFRetain(CFRunLoopGetCurrent())
	CFRunLoopAddSource(watch.loop, watch.source, kCFRunLoopDefaultMode)
	socket_watch_arm(watch, events)
	return true
}
command_server_start :: proc(server: ^Command_Server, fd: i32) -> string {
	if server.event_driven || len(server.clients) != 0 {
		return "command event sources must start on an empty server"
	}
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 || posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		return "cannot configure command listener"
	}
	if !socket_watch_start(&server.listener, fd, 1) {
		posix.fcntl(posix.FD(fd), .SETFL, flags)
		return "cannot register command listener with the run loop"
	}
	server.event_driven = true; server.listener_fd = fd
	server.listener_flags = flags
	return ""
}

// Configuration
// ------------------------------------------------------------------------

config :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	s: ^Space
	if len(args) >= 2 && args[0] == "--space" {
		s = select_space(m, args[1])
		if s == nil {
			return failure("could not locate space")
		}
		args = args[2:]
	}
	if len(args) < 1 || len(args) > 2 {
		return failure("config expects a setting and optional value")
	}
	name := args[0]
	setting := len(args) == 2
	value := setting ? args[1] : ""
	if s != nil &&
	   (name == "window_opacity" ||
			   name == "active_window_opacity" ||
			   name == "normal_window_opacity") {
		return failure("opacity settings are global")
	}
	switch name {
	case "windowserver_gate":
		if s != nil {
			return failure("windowserver_gate is global")
		}
		if m.ws_gate_control == nil {
			return failure("windowserver_gate needs the daemon")
		}
		if setting && value != "on" && value != "off" {
			return failure("windowserver_gate expects on or off")
		}
		return m.ws_gate_control(m.ws_gate_user, value)
	case "tab_indicator_gap":
		if s != nil {
			return failure("tab_indicator_gap is global")
		}
		if !setting {
			return success(fmt.tprintf("%g", m.tab_indicator_gap))
		}
		gap, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(gap) || math.is_inf(gap) || gap < 0 || gap > 32 {
			return failure("tab_indicator_gap expects 0 through 32 logical pixels")
		}
		m.tab_indicator_gap = gap
	case "tab_indicator_width":
		if s != nil {
			return failure("tab_indicator_width is global")
		}
		if !setting {
			return success(fmt.tprintf("%g", m.tab_indicator_width))
		}
		width, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(width) || math.is_inf(width) || width < 1 || width > 32 {
			return failure("tab_indicator_width expects 1 through 32 logical pixels")
		}
		m.tab_indicator_width = width
		for space in m.spaces {space.view.tab_indicator_width = width}
	case "tab_indicator_active_color", "tab_indicator_inactive_color":
		if s != nil {
			return failure(fmt.tprintf("%s is global", name))
		}
		target :=
			name == "tab_indicator_active_color" \
				? &m.tab_indicator_active_color \
				: &m.tab_indicator_inactive_color
		if !setting {
			if color, present := target^.?; present {
				return success(fmt.tprintf("0x%08x", color))
			}
			return success("default")
		}
		if value == "default" {
			target^ = nil
		} else {
			if len(value) != 10 || !strings.has_prefix(value, "0x") {
				return failure(fmt.tprintf("%s expects default or 0xAARRGGBB", name))
			}
			color, ok := strconv.parse_u64(value[2:], 16)
			if !ok {
				return failure("invalid tab indicator color")
			}
			target^ = u32(color)
		}
	case "tab_indicator_position":
		if s != nil {
			return failure("tab_indicator_position is global")
		}
		if !setting {
			return success(m.tab_indicator_top ? "top" : "left")
		}
		if value != "top" && value != "left" {
			return failure("tab_indicator_position expects left or top")
		}
		m.tab_indicator_top = value == "top"
		for space in m.spaces {space.view.tab_indicator_top = m.tab_indicator_top}
	case "window_resize_animation":
		if s != nil {
			return failure("window_resize_animation is global")
		}
		if !setting {
			return success(m.resize_fade ? "fade" : "off")
		}
		if value != "fade" && value != "off" {
			return failure("window_resize_animation expects fade or off")
		}
		m.resize_fade = value == "fade"
	case "scroll_frame_pacing":
		if s != nil {
			return failure("scroll_frame_pacing is global")
		}
		if !setting {
			return success(m.scroll_frame_pacing ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_frame_pacing expects on or off")
		}
		m.scroll_frame_pacing = value == "on"
	case "tab_conceal":
		if s != nil {
			return failure("tab_conceal is global")
		}
		if !setting {
			return success(m.tab_conceal ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("tab_conceal expects on or off")
		}
		m.tab_conceal = value == "on"
		if !m.tab_conceal {
			tab_conceal_release(m)
		}
		for space in m.spaces {
			if err := flush(m, space); err != "" {
				return failure(err)
			}
		}
	case "dynamic_workspaces", "workspace_hotplug":
		if s != nil {
			return failure(fmt.tprintf("%s is global", name))
		}
		if !setting {
			on := m.dynamic_workspaces
			if name == "workspace_hotplug" {
				on = m.workspace_hotplug
			}
			return success(on ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure(fmt.tprintf("%s expects on or off", name))
		}
		enabled := value == "on"
		if name == "dynamic_workspaces" {
			m.dynamic_workspaces = enabled
			if enabled {
				workspace_reconcile(m)
			} else {
				workspace_drop_ephemeral(m)
			}
		} else {
			m.workspace_hotplug = enabled
		}
		return success()
	case "scroll_animation":
		if s != nil {
			return failure("scroll_animation is global")
		}
		if !setting {
			return success(m.scroll_animate ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_animation expects on or off")
		}
		m.scroll_animate = value == "on"
	case "scroll_gestures",
	     "three_finger_horizontal",
	     "stack_swipe",
	     "scroll_drag_edge_scroll",
	     "scroll_drag_edge_width",
	     "scroll_drag_edge_delay",
	     "scroll_drag_edge_speed":
		return mouse_config(m, s, name, value, setting)
	case "scroll_center_focused_column",
	     "scroll_default_column_display",
	     "scroll_center_single_column",
	     "scroll_default_column_width",
	     "scroll_width_presets",
	     "scroll_height_presets",
	     "scroll_warp_pointer":
		return scroll_config(m, s, name, value, setting)
	case "focus_ring":
		if s != nil {
			return failure("focus_ring is global")
		}
		if !setting {
			return success(m.focus_ring.enabled ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("focus_ring expects on or off")
		}
		m.focus_ring.enabled = value == "on"
	case "focus_ring_width", "focus_ring_radius":
		if s != nil {
			return failure(fmt.tprintf("%s is global", name))
		}
		target := name == "focus_ring_width" ? &m.focus_ring.width : &m.focus_ring.radius
		if !setting {
			return success(fmt.tprintf("%g", target^))
		}
		width, valid := strconv.parse_f64(value)
		maximum := name == "focus_ring_width" ? f64(16) : f64(64)
		if !valid || math.is_nan(width) || math.is_inf(width) || width < 1 || width > maximum {
			return failure(fmt.tprintf("%s expects 1 through %g logical pixels", name, maximum))
		}
		target^ = width
	case "insert_feedback_color", "focus_ring_color":
		if s != nil {
			return failure(fmt.tprintf("%s is global", name))
		}
		color_target := name == "focus_ring_color" ? &m.focus_ring.color : &m.feedback_color
		if !setting {
			return success(fmt.tprintf("0x%08x", color_target^))
		}
		if len(value) != 10 || !strings.has_prefix(value, "0x") {
			return failure(fmt.tprintf("%s expects 0xAARRGGBB", name))
		}
		color, valid := strconv.parse_u64(value[2:], 16)
		if !valid {
			return failure("invalid insert feedback color")
		}
		color_target^ = u32(color)
	case "external_bar":
		if s != nil {
			return failure("external_bar is global")
		}
		modes := [3]string{"off", "main", "all"}
		if !setting {
			return success(
				fmt.tprintf("%s:%v:%v", modes[int(m.external_bar)], m.bar_top, m.bar_bottom),
			)
		}
		parts := strings.split(value, ":", context.temp_allocator)
		values: [2]f64
		if len(parts) != 3 ||
		   !parse_numbers(strings.join(parts[1:], ":", context.temp_allocator), values[:]) ||
		   values[0] < 0 ||
		   values[1] < 0 ||
		   values[0] > 100000 ||
		   values[1] > 100000 {
			return failure("external_bar expects main|all|off:top:bottom")
		}
		switch parts[0] {case "off":
			m.external_bar = .Off; case "main":
			m.external_bar = .Main; case "all":
			m.external_bar = .All; case:
			return failure("invalid external_bar mode")
		}
		m.bar_top, m.bar_bottom = values[0], values[1]
		for space in m.spaces {
			if d := display_by_id(m, space.display); d != nil {
				space.view.frame = usable_frame(m, d)
			}
		}
	case "display_arrangement_order":
		if s != nil {
			return failure("display_arrangement_order is global")
		}
		modes := [3]string{"default", "vertical", "horizontal"}
		if !setting {
			return success(modes[int(m.display_order)])
		}
		switch value {case "default":
			m.display_order = .Default; case "vertical":
			m.display_order = .Vertical; case "horizontal":
			m.display_order = .Horizontal; case:
			return failure("invalid display arrangement")
		}
		order_displays(m)
	case "window_origin_display":
		if s != nil {
			return failure("window_origin_display is global")
		}
		modes := [3]string{"default", "focused", "cursor"}
		if !setting {
			return success(modes[int(m.origin_display)])
		}
		switch value {case "default":
			m.origin_display = .Default; case "focused":
			m.origin_display = .Focused; case "cursor":
			m.origin_display = .Cursor; case:
			return failure("invalid window origin display")
		}
	case "window_shadow":
		if s != nil {
			return failure("window_shadow is global")
		}
		modes := [3]string{"on", "off", "float"}
		if !setting {
			return success(modes[int(m.shadow_mode)])
		}
		previous := m.shadow_mode
		switch value {case "on":
			m.shadow_mode = .On; case "off":
			m.shadow_mode = .Off; case "float":
			m.shadow_mode = .Float; case:
			return failure("window_shadow expects on, off or float")
		}
		if err := apply_window_shadows(m); err != "" {
			m.shadow_mode = previous; apply_window_shadows(m)
			return failure(err)
		}
		m.shadow_configured = true
	case "window_animation_duration":
		if s != nil {
			return failure("animation duration is global")
		}
		if !setting {
			return success(fmt.tprintf("%v", m.animation_duration))
		}
		number, valid := strconv.parse_f64(value)
		if !valid || math.is_nan(number) || math.is_inf(number) || number < 0 || number > 3600 {
			return failure("invalid animation duration")
		}
		m.animation_duration = number
	case "window_animation_easing":
		if s != nil {
			return failure("animation easing is global")
		}
		if !setting {
			return success(EASING_NAMES[int(m.animation_easing)])
		}
		found := false
		for name, kind in EASING_NAMES {
			if value == name {
				m.animation_easing = Easing(kind); found = true; break
			}
		}
		if !found {
			return failure("unknown animation easing")
		}
	case "window_zoom_persist":
		if s != nil {
			return failure("window_zoom_persist is global")
		}
		if !setting {
			return success(m.zoom_persist ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("window_zoom_persist expects on or off")
		}
		m.zoom_persist = value == "on"
		for space in m.spaces {space.view.zoom_persist = m.zoom_persist}
	case "window_insertion_point":
		if s != nil {
			return failure("window_insertion_point is global")
		}
		if !setting {
			switch m.insertion_point {case .Focused:
				return success("focused"); case .First:
				return success("first"); case .Last:
				return success("last")
			}
		}
		switch value {case "focused":
			m.insertion_point = .Focused; case "first":
			m.insertion_point = .First; case "last":
			m.insertion_point = .Last; case:
			return failure("invalid insertion point")
		}
	case "mouse_modifier",
	     "mouse_action1",
	     "mouse_action2",
	     "mouse_drop_action",
	     "focus_follows_mouse",
	     "mouse_follows_focus":
		return mouse_config(m, s, name, value, setting)
	case "window_opacity":
		if !setting {
			return success(m.window_opacity ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("window_opacity expects on or off")
		}
		previous := m.window_opacity
		m.window_opacity = value == "on"
		if err := apply_window_opacity(m); err != "" {
			m.window_opacity = previous
			apply_window_opacity(m)
			return failure(err)
		}
	case "window_opacity_duration":
		if s != nil {
			return failure("opacity duration is global")
		}
		if !setting {
			return success(fmt.tprintf("%v", m.opacity_duration))
		}
		number, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(number) || math.is_inf(number) || number < 0 || number > 3600 {
			return failure("invalid opacity duration")
		}
		m.opacity_duration = number
	case "active_window_opacity", "normal_window_opacity":
		p := name == "active_window_opacity" ? &m.active_opacity : &m.normal_opacity
		if !setting {
			return success(fmt.tprintf("%v", p^))
		}
		number, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(number) || math.is_inf(number) || number < 0 || number > 1 {
			return failure("window opacity expects 0..1")
		}
		previous := p^
		p^ = number
		if err := apply_window_opacity(m); err != "" {
			p^ = previous
			apply_window_opacity(m)
			return failure(err)
		}
	case "layout":
		if !setting {
			return success(layout_name(s != nil ? s.view.layout : m.default_layout))
		}
		layout, ok := parse_layout(value)
		if !ok {
			return failure("layout expects bsp, stack, scroll, or float")
		}
		if s == nil {
			m.default_layout = layout
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				set_layout(m, space, layout)
			}
		} else {
			set_layout(m, s, layout)
		}
	case "window_gap",
	     "top_padding",
	     "bottom_padding",
	     "left_padding",
	     "right_padding",
	     "split_ratio":
		p: ^f64
		switch name {
		case "window_gap":
			p = s != nil ? &s.view.gap : &m.gap
		case "top_padding":
			p = s != nil ? &s.view.padding.top : &m.padding.top
		case "bottom_padding":
			p = s != nil ? &s.view.padding.bottom : &m.padding.bottom
		case "left_padding":
			p = s != nil ? &s.view.padding.left : &m.padding.left
		case "right_padding":
			p = s != nil ? &s.view.padding.right : &m.padding.right
		case "split_ratio":
			p = s != nil ? &s.view.ratio : &m.ratio
		}
		if !setting {
			return success(fmt.tprintf("%v", p^))
		}
		number, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(number) || math.is_inf(number) || number < 0 || number > 100000 {
			return failure("invalid numeric setting")
		}
		if name == "split_ratio" && (number < 0.1 || number > 0.9) {
			return failure("split_ratio must be between 0.1 and 0.9")
		}
		p^ = number
		if s == nil {
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				switch name {
				case "window_gap":
					space.view.gap = number
				case "top_padding":
					space.view.padding.top = number
				case "bottom_padding":
					space.view.padding.bottom = number
				case "left_padding":
					space.view.padding.left = number
				case "right_padding":
					space.view.padding.right = number
				case "split_ratio":
					space.view.ratio = number
				}
			}
		}
	case "auto_balance", "window_placement":
		p := name == "auto_balance" ? &m.auto_balance : &m.first_child
		if s != nil {
			p = name == "auto_balance" ? &s.view.auto_balance : &s.view.first_child
		}
		yes, no := "on", "off"
		if name == "window_placement" {
			yes, no = "first_child", "second_child"
		}
		if !setting {
			if name == "auto_balance" && p^ {
				axis := s != nil ? s.view.balance_axis : m.balance_axis
				if axis == .Horizontal {
					return success("x-axis")
				}
				if axis == .Vertical {
					return success("y-axis")
				}
			}
			return success(p^ ? yes : no)
		}
		if value != yes &&
		   value != no &&
		   !(name == "auto_balance" && (value == "x-axis" || value == "y-axis")) {
			return failure(errorf("%s expects %s or %s", name, yes, no))
		}
		p^ = value != no
		axis :=
			value == "x-axis" \
				? layout.Split.Horizontal \
				: (value == "y-axis" ? layout.Split.Vertical : layout.Split.Auto)
		if name == "auto_balance" {
			if s != nil {
				s.view.balance_axis = axis
			} else {
				m.balance_axis = axis
			}
		}
		if s == nil {
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				if name == "auto_balance" {
					space.view.auto_balance = p^
					space.view.balance_axis = axis
				} else {
					space.view.first_child = p^
				}
			}
		}
	case "split_type":
		p := s != nil ? &s.view.split : &m.split
		names := [layout.Split]string {
			.Auto       = "auto",
			.Vertical   = "vertical",
			.Horizontal = "horizontal",
		}
		if !setting {
			return success(names[p^])
		}
		valid := false
		for name, index in names {
			if name == value {
				p^ = layout.Split(index)
				valid = true
			}
		}
		if !valid {
			return failure("split_type expects auto, vertical, or horizontal")
		}
		if s == nil {
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				space.view.split = p^
			}
		}
	case:
		return failure(errorf("unsupported setting '%s'", name))
	}
	if s != nil {
		mark_space_override(s, name)
		return result(flush(m, s))
	}
	for space in m.spaces {
		if space.visible {
			if err := flush(m, space); err != "" {
				return failure(err)
			}
		}
	}
	return success()
}

mark_space_override :: proc(s: ^Space, name: string) {
	// IPC setting names borrow the request buffer; retain only static keys.
	for key in ([]string {
			"layout",
			"scroll_center_focused_column",
			"scroll_default_column_display",
			"scroll_center_single_column",
			"scroll_warp_pointer",
			"scroll_default_column_width",
			"scroll_width_presets",
			"scroll_height_presets",
			"window_gap",
			"top_padding",
			"bottom_padding",
			"left_padding",
			"right_padding",
			"split_ratio",
			"auto_balance",
			"window_placement",
			"split_type",
		}) {
		if key == name {
			s.overrides[key] = true; return
		}
	}
}

apply_window_opacity :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.opacity_override {
			continue
		}
		desired :=
			m.window_opacity ? (w.id == m.focused ? m.active_opacity : m.normal_opacity) : 1.0
		if w.opacity == desired {
			continue
		}
		if err := perform(
			m,
			Action{kind = .Opacity, window = w.id, value = desired, duration = m.opacity_duration},
		); err != "" {
			return err
		}
		w.opacity = desired
	}
	return ""
}

// Display and window appearance settings
// ------------------------------------------------------------------------

usable_frame :: proc(m: ^Manager, d: ^Display) -> Rect {
	r := d.usable
	if m.external_bar == .All || (m.external_bar == .Main && d.id == m.main_display) {
		r.y += m.bar_top
		r.h = max(1, r.h - m.bar_top - m.bar_bottom)
	}
	return r
}

order_displays :: proc(m: ^Manager) {
	for i in 1 ..< len(m.displays) {
		for j := i; j > 0; j -= 1 {
			a, b := m.displays[j - 1], m.displays[j]
			ax, ay := a.frame.x + a.frame.w / 2, a.frame.y + a.frame.h / 2
			bx, by := b.frame.x + b.frame.w / 2, b.frame.y + b.frame.h / 2
			after := a.native_index > b.native_index
			switch m.display_order {
			case .Default:
			case .Vertical:
				after = ay > by || (ay == by && ax > bx)
			case .Horizontal:
				after = ax > bx || (ax == bx && ay > by)
			}
			if !after {
				break
			}
			m.displays[j - 1], m.displays[j] = b, a
		}
	}
	for &d, i in m.displays {d.index = u32(i + 1)}
}

apply_window_shadows :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		desired := m.shadow_mode == .On || (m.shadow_mode == .Float && !managed(w))
		if w.shadow == desired {
			continue
		}
		if err := perform(m, {kind = .Shadow, window = w.id, flag = desired}); err != "" {
			return err
		}
		w.shadow = desired
	}
	return ""
}

apply_window_layers :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.layer_override {
			continue
		}
		below := managed(w)
		// Accessory system panels must remain visible above document windows.
		above := !below && w.application_accessory && w.role == "AXWindow"
		desired := below ? "below" : (above ? "above" : "normal")
		if w.layer == desired {
			continue
		}
		if err := perform(m, {kind = .Layer, window = w.id, value = below ? -1 : (above ? 1 : 0)});
		   err != "" {
			return err
		}
		w.layer = desired
	}
	return ""
}

// Rules and signals
// ------------------------------------------------------------------------

Filter :: struct {
	pattern:          string,
	expression:       POSIX_Regex,
	enabled, exclude: bool,
}

Rule :: struct {
	label:                                          string,
	app, title, role, subrole:                      Filter,
	manage:                                         Maybe(bool),
	space:                                          string,
	display, grid, scratchpad, sub_layer:           string,
	opacity:                                        Maybe(f64),
	sticky, native_fullscreen, mouse_follows_focus: Maybe(bool),
	open_floating, open_maximized:                  Maybe(bool),
	column_width, column_display:                   string,
	one_shot:                                       bool,
	pending_window:                                 u32,
}

Signal :: struct {
	label, event, action: string,
	active:               Maybe(bool),
	app, title:           Filter,
}

rule_destroy :: proc(r: ^Rule) {
	delete(r.label)
	delete(r.space)
	delete(r.display); delete(r.grid); delete(r.scratchpad)
	delete(r.sub_layer)
	delete(r.column_width)
	delete(r.column_display)
	filter_destroy(&r.app)
	filter_destroy(&r.title)
	filter_destroy(&r.role)
	filter_destroy(&r.subrole)
}

signal_destroy :: proc(s: ^Signal) {
	delete(s.label)
	delete(s.event)
	delete(s.action)
	filter_destroy(&s.app)
	filter_destroy(&s.title)
}

rule_matches :: proc(r: Rule, w: ^Window) -> bool {
	return(
		filter_matches(r.app, w.app) &&
		filter_matches(r.title, w.title) &&
		filter_matches(r.role, w.role) &&
		filter_matches(r.subrole, w.subrole) \
	)
}

apply_rules :: proc(
	m: ^Manager,
	w: ^Window,
	existing: bool = false,
	selected: int = -1,
	initial: bool = false,
) -> (
	err: string,
) {
	previous_space := w.space
	was_pending := w.rules_pending
	defer {
		// Explicit reapply excludes one-shots and must not cancel a creation retry.
		if !existing {
			w.rules_pending = err != ""
		}
		if !existing || !was_pending || err != "" {
			delete(w.rule_error); w.rule_error = strings.clone(err)
		}
	}
	// Resolve precedence before issuing operations. A failed earlier destination
	// must not prevent a later management rule from taking effect.
	effects: Rule
	one_shots := make([dynamic]int, context.temp_allocator)
	matched := false
	for i in 0 ..< len(m.rules) {
		r := &m.rules[i]
		matches := rule_matches(r^, w)
		if r.pending_window == w.id && !matches {
			r.pending_window = 0
		}
		if (existing && r.one_shot) ||
		   (selected >= 0 && i != selected) ||
		   !matches ||
		   (r.one_shot && r.pending_window != 0 && r.pending_window != w.id) {
			continue
		}
		matched = true
		if r.manage != nil {
			effects.manage = r.manage
		}
		if r.opacity != nil {
			effects.opacity = r.opacity
		}
		if r.sticky != nil {
			effects.sticky = r.sticky
		}
		if r.native_fullscreen != nil {
			effects.native_fullscreen = r.native_fullscreen
		}
		if r.mouse_follows_focus != nil {
			effects.mouse_follows_focus = r.mouse_follows_focus
		}
		if r.open_floating != nil {
			effects.open_floating = r.open_floating
		}
		if r.open_maximized != nil {
			effects.open_maximized = r.open_maximized
		}
		for pair in ([7][2]^string {
				{&effects.space, &r.space},
				{&effects.display, &r.display},
				{&effects.grid, &r.grid},
				{&effects.scratchpad, &r.scratchpad},
				{&effects.sub_layer, &r.sub_layer},
				{&effects.column_width, &r.column_width},
				{&effects.column_display, &r.column_display},
			}) {
			if pair[1]^ != "" {
				pair[0]^ = pair[1]^
			}
		}
		if r.one_shot {
			r.pending_window = w.id
			append(&one_shots, i)
		}
	}
	if !matched {
		return ""
	}
	if enabled, ok := effects.manage.?; ok {
		w.floating = !enabled; w.manage_override = enabled
		if !managed(w) {
			if s := space_by_id(m, w.space); s != nil {
				layout.remove(&s.view, w.id)
			}
		}
	}
	if value, ok := effects.mouse_follows_focus.?; ok {
		w.mouse_follows_focus = value
	}
	err = apply_rule_effects(m, w, effects)
	// Even a partial backend failure can change management or destination.
	// Reconcile only those changes; unchanged membership keeps its original node.
	if !initial {
		if membership_error := sync_window_membership(m, w, previous_space);
		   membership_error != "" && membership_error != err {
			err = err == "" ? membership_error : errorf("%s; %s", err, membership_error)
		}
	}
	if err != "" {
		return err
	}
	scroll_rule_store(w, effects)
	if realize_err := scroll_rule_realize(m, w); realize_err != "" {
		return realize_err
	}
	for i := len(one_shots) - 1; i >= 0; i -= 1 {
		index := one_shots[i]; rule_destroy(&m.rules[index])
		ordered_remove(&m.rules, index)
	}
	return ""
}

scroll_rule_store :: proc(w: ^Window, effects: Rule) {
	w.rule_maximize = effects.open_maximized
	delete(w.rule_column_width)
	w.rule_column_width = strings.clone(effects.column_width)
	delete(w.rule_column_display)
	w.rule_column_display = strings.clone(effects.column_display)
}

// Column width, display, and maximize wait until the window is in a scrolling
// column. A floating window keeps the request until it joins the strip.
scroll_rule_realize :: proc(m: ^Manager, w: ^Window) -> string {
	if w == nil || w.floating {
		return ""
	}
	s := space_by_id(m, w.space)
	if s == nil || s.view.layout != .Scroll {
		return ""
	}
	n := layout.find(s.view.root, w.id)
	if n == nil {
		return ""
	}
	if w.rule_column_width != "" {
		if err := layout.scroll_set_width(&s.view, w.id, w.rule_column_width); err != "" {
			return err
		}
		n = layout.find(s.view.root, w.id)
		if n == nil {
			return ""
		}
	}
	if w.rule_column_display != "" {
		n.column_tabbed = w.rule_column_display == "tabbed"
		n.column_raised = 0
	}
	if maximize, ok := w.rule_maximize.?; ok {
		n.column_maximize = maximize
		if maximize {
			n.column_full, n.column_cover = false, false
		}
		n.column_preset = nil
		n.column_revision += 1
		s.view.scroll.fill_after_removal = false
		s.view.scroll.reveal = true
	}
	return ""
}

apply_rule_effects :: proc(m: ^Manager, w: ^Window, r: Rule) -> string {
	// open-floating starts the window out of the strip. It does not change
	// manage, so a later float toggle can tile it again.
	if value, ok := r.open_floating.?; ok {
		w.floating = value
		if !value && w.opening.phase == .Excluded {
			w.opening.phase = .Admitted
		}
	}
	selector := fmt.tprintf("%d", w.id)
	target: ^Space
	follow := false
	if r.space != "" {
		text := r.space; follow = strings.has_prefix(text, "^"); if follow {
			text = text[1:]
		}
		target = select_space(m, text)
	} else if r.display != "" {
		text := r.display; follow = strings.has_prefix(text, "^"); if follow {
			text = text[1:]
		}
		if d := select_display(m, text); d != nil {
			target = space_by_id(m, d.active_space)
		}
	}
	if r.space != "" || r.display != "" {
		if target == nil {
			return "rule destination could not be located"
		}
		if target.id != w.space {
			if managed(w) &&
			   target.view.layout != .Float &&
			   !layout.can_add(&target.view, m.focused) {
				return "rule destination tiling tree is full"
			}
			if err := perform(m, {kind = .Space, window = w.id, space = target.id}); err != "" {
				return err
			}
			w.space, w.display = target.id, target.display
		}
		if follow {
			if err := perform(m, {kind = .Space_Focus, space = target.id}); err != "" {
				return err
			}
		}
	}
	if value, ok := r.sticky.?; ok {
		if err := perform(m, {kind = .Sticky, window = w.id, flag = value}); err != "" {
			return err
		}
		w.sticky = value
	}
	if value, ok := r.opacity.?; ok {
		if response := window_command(
			m,
			[]string{selector, "--opacity", fmt.tprintf("%v", value)},
		); response.failed {
			return response.text
		}
	}
	if r.sub_layer != "" {
		if response := window_command(m, []string{selector, "--sub-layer", r.sub_layer});
		   response.failed {
			return response.text
		}
	}
	if r.scratchpad != "" && scratchpad_by_label(m, r.scratchpad) == nil {
		if err := scratchpad_assign(m, w, r.scratchpad); err != "" {
			return err
		}
	}
	if r.grid != "" {
		if response := window_command(m, []string{selector, "--grid", r.grid}); response.failed {
			return response.text
		}
	}
	if value, ok := r.native_fullscreen.?; ok {
		if err := perform(m, {kind = .Fullscreen, window = w.id, flag = value}); err != "" {
			return err
		}
		w.fullscreen = value
	}
	if value, ok := r.mouse_follows_focus.?; ok {
		w.mouse_follows_focus = value
	}
	return ""
}

assignment :: proc(arg: string) -> (key, value: string, exclude, ok: bool) {
	at := strings.index_byte(arg, '=')
	if at < 1 {
		return
	}
	key, value = arg[:at], arg[at + 1:]
	if strings.has_suffix(key, "!") {
		key = key[:len(key) - 1]
		exclude = true
	}
	ok = true
	return
}

parse_rule :: proc(args: []string) -> (rule: Rule, err: string) {
	for arg in args {
		if arg == "--one-shot" {
			rule.one_shot = true; continue
		}
		key, value, exclude, ok := assignment(arg)
		if !ok {
			err = "expected key=value"
			break
		}
		f: ^Filter
		switch key {
		case "app":
			f = &rule.app
		case "title":
			f = &rule.title
		case "role":
			f = &rule.role
		case "subrole":
			f = &rule.subrole
		case "label":
			delete(rule.label)
			rule.label = strings.clone(value)
		case "space":
			delete(rule.space)
			rule.space = strings.clone(value)
		case "display", "grid", "scratchpad", "sub-layer":
			p := &rule.display
			switch key {
			case "grid":
				p = &rule.grid
			case "scratchpad":
				p = &rule.scratchpad
			case "sub-layer":
				p = &rule.sub_layer
			}
			delete(p^); p^ = strings.clone(value)
			if key == "sub-layer" &&
			   value != "below" &&
			   value != "normal" &&
			   value != "above" &&
			   value != "auto" {
				err = "invalid rule sub-layer"
			}
			if key == "grid" {
				values: [6]f64
				if !parse_numbers(value, values[:]) ||
				   values[0] <= 0 ||
				   values[1] <= 0 ||
				   values[2] < 0 ||
				   values[3] < 0 ||
				   values[4] <= 0 ||
				   values[5] <= 0 ||
				   values[2] + values[4] > values[1] ||
				   values[3] + values[5] > values[0] {
					err = "invalid rule grid"
				}
			}
		case "opacity":
			number, valid := strconv.parse_f64(value)
			if !valid || math.is_nan(number) || math.is_inf(number) || number < 0 || number > 1 {
				err = "invalid rule opacity"
			} else {
				rule.opacity = number
			}
		case "sticky", "native-fullscreen", "mouse_follows_focus":
			p := &rule.sticky
			if key == "native-fullscreen" {
				p = &rule.native_fullscreen
			}
			if key == "mouse_follows_focus" {
				p = &rule.mouse_follows_focus
			}
			if value != "on" && value != "off" {
				err = "rule boolean expects on or off"
			} else {
				p^ = value == "on"
			}
		case "manage":
			if value != "on" && value != "off" {
				err = "manage expects on or off"
			} else {
				rule.manage = value == "on"
			}
		case "open-floating", "open-maximized":
			p := &rule.open_floating
			if key == "open-maximized" {
				p = &rule.open_maximized
			}
			if value != "on" && value != "off" {
				err = "rule boolean expects on or off"
			} else {
				p^ = value == "on"
			}
		case "column-width":
			if _, valid := layout.scroll_parse_size(value); !valid {
				err = "column-width expects abs:pixels or ratio:fraction"
			} else {
				delete(rule.column_width)
				rule.column_width = strings.clone(value)
			}
		case "column-display":
			if value != "normal" && value != "tabbed" {
				err = "column-display expects normal or tabbed"
			} else {
				delete(rule.column_display)
				rule.column_display = strings.clone(value)
			}
		case "one-shot":
			if value != "on" && value != "off" {
				err = "one-shot expects on or off"
			} else {
				rule.one_shot = value == "on"
			}
		case:
			err = errorf("unsupported rule property '%s'", key)
		}
		if f != nil && !filter_set(f, value, exclude) {
			err = errorf("invalid regular expression '%s'", value)
		}
		if err != "" {
			break
		}
	}
	if err != "" {
		rule_destroy(&rule)
		rule = {}
	}
	return
}

SIGNAL_EVENTS :: []string {
	"application_launched",
	"application_terminated",
	"application_front_switched",
	"application_activated",
	"application_deactivated",
	"application_visible",
	"application_hidden",
	"window_created",
	"window_destroyed",
	"window_focused",
	"window_moved",
	"window_resized",
	"window_minimized",
	"window_deminimized",
	"window_title_changed",
	"space_created",
	"space_destroyed",
	"space_changed",
	"display_added",
	"display_removed",
	"display_moved",
	"display_resized",
	"display_changed",
	"mission_control_enter",
	"mission_control_exit",
	"dock_did_change_pref",
	"dock_did_restart",
	"menu_bar_hidden_changed",
	"system_woke",
}

parse_signal :: proc(args: []string) -> (s: Signal, err: string) {
	for arg in args {
		key, value, exclude, ok := assignment(arg)
		if !ok {
			err = "expected key=value"
			break
		}
		switch key {
		case "active":
			if value != "yes" && value != "no" {
				err = "active expects yes or no"
			} else {
				s.active = value == "yes"
			}
		case "label":
			delete(s.label)
			s.label = strings.clone(value)
		case "event":
			delete(s.event)
			s.event = strings.clone(value)
		case "action":
			delete(s.action)
			s.action = strings.clone(value)
		case "app":
			if !filter_set(&s.app, value, exclude) {
				err = "invalid app regex"
			}
		case "title":
			if !filter_set(&s.title, value, exclude) {
				err = "invalid title regex"
			}
		case:
			err = errorf("unsupported signal property '%s'", key)
		}
		if err != "" {
			break
		}
	}
	known := false
	for event in SIGNAL_EVENTS {
		if event == s.event {
			known = true
			break
		}
	}
	if !known {
		err = "unknown signal event"
	}
	if s.action == "" {
		err = "signal requires action"
	}
	if err != "" {
		signal_destroy(&s)
		s = {}
	}
	return
}

remove_rule :: proc(m: ^Manager, selector: string) -> bool {
	index, numeric := strconv.parse_int(selector)
	for &r, i in m.rules {
		if (numeric && i == index) || (!numeric && r.label == selector) {
			rule_destroy(&r)
			ordered_remove(&m.rules, i)
			return true
		}
	}
	return false
}

remove_signal :: proc(m: ^Manager, selector: string) -> bool {
	index, numeric := strconv.parse_int(selector)
	for &s, i in m.signals {
		if (numeric && i == index) || (!numeric && s.label == selector) {
			signal_destroy(&s)
			ordered_remove(&m.signals, i)
			return true
		}
	}
	return false
}

// Rule and signal commands
// ------------------------------------------------------------------------

rule_command :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("missing rule operation")
	}
	switch args[0] {
	case "--add":
		if len(args) < 2 {
			return failure("missing rule properties")
		}
		r, err := parse_rule(args[1:])
		if err != "" {
			return failure(err)
		}
		if r.label != "" {
			remove_rule(m, r.label)
		}
		append(&m.rules, r)
		return success()
	case "--remove":
		if len(args) != 2 {
			return failure("remove requires index or label")
		}
		if !remove_rule(m, args[1]) {
			return failure("rule not found")
		}
		return success()
	case "--list":
		Item :: struct {
			index:                            int,
			label, app, title, role, subrole: string,
			manage:                           Maybe(bool),
			space:                            string,
			display, grid, scratchpad:        string,
			sub_layer:                        string `json:"sub-layer"`,
			opacity:                          Maybe(f64),
			sticky, mouse_follows_focus:      Maybe(bool),
			native_fullscreen:                Maybe(bool) `json:"native-fullscreen"`,
			open_floating:                    Maybe(bool) `json:"open-floating"`,
			open_maximized:                   Maybe(bool) `json:"open-maximized"`,
			column_width:                     string `json:"column-width"`,
			column_display:                   string `json:"column-display"`,
			one_shot:                         bool `json:"one-shot"`,
		}
		items := make([dynamic]Item, 0, len(m.rules), context.temp_allocator)
		for r, i in m.rules {
			append(
				&items,
				Item {
					i,
					r.label,
					r.app.pattern,
					r.title.pattern,
					r.role.pattern,
					r.subrole.pattern,
					r.manage,
					r.space,
					r.display,
					r.grid,
					r.scratchpad,
					r.sub_layer,
					r.opacity,
					r.sticky,
					r.mouse_follows_focus,
					r.native_fullscreen,
					r.open_floating,
					r.open_maximized,
					r.column_width,
					r.column_display,
					r.one_shot,
				},
			)
		}
		return success(json_text(items))
	case "--apply":
		selected := -1
		temporary := false
		defer {
			if temporary {
				rule_destroy(&m.rules[selected])
				ordered_remove(&m.rules, selected)
			}
		}
		if len(args) > 1 {
			if strings.contains(args[1], "=") {
				rule, err := parse_rule(args[1:])
				if err != "" {
					return failure(err)
				}
				selected = len(m.rules)
				append(&m.rules, rule)
				temporary = true
			} else {
				if len(args) != 2 {
					return failure("apply expects a rule selector or properties")
				}
				index, numeric := strconv.parse_int(args[1])
				for rule, i in m.rules {
					if (numeric && i == index) || (!numeric && rule.label == args[1]) {
						selected = i; break
					}
				}
				if selected < 0 {
					return failure("rule not found")
				}
			}
		}
		for _, w in m.windows {
			if err := apply_rule_to_window(m, w, selected); err != "" {
				return failure(err)
			}
		}
		for s in m.spaces {
			if s.visible {
				if err := flush(m, s); err != "" {
					return failure(err)
				}
			}
		}
		return success()
	}
	return failure("unknown rule operation")
}

apply_rule_to_window :: proc(m: ^Manager, w: ^Window, selected: int = -1) -> string {
	return apply_rules(m, w, existing = true, selected = selected)
}

signal_command :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("missing signal operation")
	}
	switch args[0] {
	case "--add":
		s, err := parse_signal(args[1:])
		if err != "" {
			return failure(err)
		}
		if s.label != "" {
			remove_signal(m, s.label)
		}
		append(&m.signals, s)
		return success()
	case "--remove":
		if len(args) != 2 {
			return failure("remove requires index or label")
		}
		if !remove_signal(m, args[1]) {
			return failure("signal not found")
		}
		return success()
	case "--list":
		Item :: struct {
			index:                            int,
			label, event, action, app, title: string,
			active:                           Maybe(bool),
		}
		items := make([dynamic]Item, 0, len(m.signals), context.temp_allocator)
		for s, i in m.signals {
			append(
				&items,
				Item{i, s.label, s.event, s.action, s.app.pattern, s.title.pattern, s.active},
			)
		}
		return success(json_text(items))
	}
	return failure("unknown signal operation")
}

// User notifications
// ------------------------------------------------------------------------
// Shoji runs as a background agent, so failures are posted through the
// Notification Center like any other app. Posting is opt-in by macOS: the
// first use asks for permission. Without an app bundle, permission, or the
// framework, messages stay in the log only. Admission is bounded: identical
// messages are suppressed for NOTIFY_DEDUPE_WINDOW and at most
// NOTIFY_RATE_LIMIT messages are posted per NOTIFY_RATE_WINDOW.


NOTIFY_RATE_LIMIT :: 5
NOTIFY_RATE_WINDOW :: 10 * time.Minute
NOTIFY_DEDUPE_SLOTS :: 16
NOTIFY_DEDUPE_WINDOW :: time.Hour
NOTIFY_TEXT_LIMIT :: 400
USER_NOTIFICATIONS_PATH :: "/System/Library/Frameworks/UserNotifications.framework/UserNotifications"
// UNAuthorizationOptionSound | UNAuthorizationOptionAlert.
UN_AUTHORIZATION_SOUND_ALERT :: 2 | 4

Notify_Authorization :: enum i32 {
	Unknown,
	Granted,
	Denied,
}

Notify_Key :: struct {
	key: u64,
	at:  time.Time,
}

Notifier :: struct {
	available:           bool, // App bundle and framework present.
	authorization:       Notify_Authorization, // Written by the framework callback.
	center:              ^objc.Object,
	authorization_block: ^objc.Block,
	sent:                [NOTIFY_RATE_LIMIT]time.Time,
	sent_count:          int,
	recent:              [NOTIFY_DEDUPE_SLOTS]Notify_Key,
	recent_next:         int,
	suppressed:          int, // Messages kept out of Notification Center by the bounds.
	sequence:            u64,
}

@(default_calling_convention = "c")
foreign _ {
	objc_lookUpClass :: proc(name: cstring) -> rawptr ---
}

notify_key :: proc(title, body: string) -> u64 {
	return hash.fnv64a(transmute([]u8)title) ~ hash.fnv64a(transmute([]u8)body)
}

// Pure admission policy, separate from native posting for tests.
notifier_admit :: proc(n: ^Notifier, key: u64, now: time.Time) -> bool {
	for entry in n.recent {
		if entry.key == key && time.diff(entry.at, now) < NOTIFY_DEDUPE_WINDOW {
			n.suppressed += 1
			return false
		}
	}
	oldest := 0
	in_window := 0
	for i in 0 ..< n.sent_count {
		if time.diff(n.sent[i], now) < NOTIFY_RATE_WINDOW {
			in_window += 1
		}
		if time.diff(n.sent[i], n.sent[oldest]) > 0 {
			oldest = i
		}
	}
	if in_window >= NOTIFY_RATE_LIMIT {
		n.suppressed += 1
		return false
	}
	if n.sent_count < NOTIFY_RATE_LIMIT {
		n.sent[n.sent_count] = now
		n.sent_count += 1
	} else {
		n.sent[oldest] = now
	}
	n.recent[n.recent_next] = {key, now}
	n.recent_next = (n.recent_next + 1) % NOTIFY_DEDUPE_SLOTS
	return true
}

notify_authorization_result :: proc "c" (user: rawptr, granted: bool) {
	value := granted ? Notify_Authorization.Granted : Notify_Authorization.Denied
	sync.atomic_store((^Notify_Authorization)(user), value)
}

// Requests permission once. Only an app bundle has a notification identity;
// the framework raises an exception for a bare executable, so check first.
notifier_start :: proc(n: ^Notifier) {
	bundle := objc.Bundle_mainBundle()
	if bundle == nil || bundle->bundleIdentifier() == nil {
		return
	}
	path := bundle->bundlePath()
	if path == nil || !strings.has_suffix(string(path->UTF8String()), ".app") {
		return
	}
	if posix.dlopen(USER_NOTIFICATIONS_PATH, {.LAZY}) == nil {
		return
	}
	class := objc_lookUpClass("UNUserNotificationCenter")
	if class == nil {
		return
	}
	center := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(class),
		"currentNotificationCenter",
	)
	if center == nil {
		return
	}
	n.center = center
	n.authorization_block = objc.Block_createGlobalWithParam(
		&n.authorization,
		notify_authorization_result,
	)
	intrinsics.objc_send(
		nil,
		center,
		"requestAuthorizationWithOptions:completionHandler:",
		uint(UN_AUTHORIZATION_SOUND_ALERT),
		n.authorization_block,
	)
	n.available = true
}

notifier_stop :: proc(n: ^Notifier) {
	// The center may still invoke the authorization block; it is global and
	// points into the notifier, which lives for the daemon's lifetime.
	n.available = false
	n.center = nil
}

notify_string :: proc(text: string) -> ^objc.String {
	clipped := text[:min(len(text), NOTIFY_TEXT_LIMIT)]
	text_object := objc.String_alloc()->initWithOdinString(clipped)
	text_object->autorelease()
	return text_object
}

// Logs the message and, when admitted and permitted, posts it.
notify :: proc(n: ^Notifier, title, body: string, now: time.Time) {
	fmt.eprintf("shoji: %s: %s\n", title, body)
	if !n.available || sync.atomic_load(&n.authorization) == .Denied {
		return
	}
	if !notifier_admit(n, notify_key(title, body), now) {
		return
	}
	content_class := objc_lookUpClass("UNMutableNotificationContent")
	request_class := objc_lookUpClass("UNNotificationRequest")
	if content_class == nil || request_class == nil {
		return
	}
	content := intrinsics.objc_send(^objc.Object, (^objc.Object)(content_class), "new")
	if content == nil {
		return
	}
	defer intrinsics.objc_send(nil, content, "release")
	intrinsics.objc_send(nil, content, "setTitle:", notify_string(title))
	intrinsics.objc_send(nil, content, "setBody:", notify_string(body))
	n.sequence += 1
	identifier := notify_string(fmt.tprintf("tech.shoji.health.%d", n.sequence))
	request := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(request_class),
		"requestWithIdentifier:content:trigger:",
		identifier,
		content,
		rawptr(nil),
	)
	if request == nil {
		return
	}
	intrinsics.objc_send(
		nil,
		n.center,
		"addNotificationRequest:withCompletionHandler:",
		request,
		rawptr(nil),
	)
}

// Turns recorded transitions into notifications. Each is consumed once.
notify_payload_transition :: proc(n: ^Notifier, r: ^Addition_Reload, now: time.Time) {
	transition := r.transition
	r.transition = .None
	switch transition {
	case .None:
	case .Failed:
		body := health.bounded_get(&r.payload_health.cause)
		if report := health.bounded_get(&r.payload_health.crash_report); report != "" {
			body = fmt.tprintf("%s. Crash report: %s", body, report)
		}
		notify(n, "Shoji: Dock payload failed", body, now)
	case .Recovered:
		body :: "Native Space and window effects work again."
		notify(n, "Shoji: Dock payload recovered", body, now)
	}
}

notify_config_failures :: proc(n: ^Notifier, run: ^Config_Run, now: time.Time) {
	report := &run.report
	for run.notified < report.count {
		failure := &report.failures[run.notified]
		notify(n, "Shoji: configuration error", health.config_failure_text(failure), now)
		run.notified += 1
	}
}

// Native application notifications
// ------------------------------------------------------------------------

Workspace_Event :: enum {
	Wake,
	Dock_Restart,
	Dock_Pref,
	Menu_Bar,
	Display,
	Refresh,
}
Workspace_Events :: bit_set[Workspace_Event]
Workspace_State :: struct {
	listener:                        ^objc.Object,
	centers:                         [3]^objc.Object,
	mutex:                           sync.Mutex,
	pending:                         Workspace_Events,
	dock_pid, last_dock_pid:         i32,
	last_poll:                       time.Time,
	dock_element, dock_observer:     Ref,
	mission_active, desired_mission: bool,
}
workspace_listener_class: objc.Class
workspace_listener_states: map[rawptr]^State
workspace_registry_mutex: sync.Mutex

workspace_notification :: proc "c" (object, selector, notification: ^objc.Object) {
	context = runtime.default_context()
	sync.mutex_lock(&workspace_registry_mutex)
	defer sync.mutex_unlock(&workspace_registry_mutex)
	state := workspace_listener_states[rawptr(object)]
	if state == nil {
		return
	}
	name := objc_text(intrinsics.objc_send(^objc.Object, notification, "name"))
	workspace_record(state, name)
}

workspace_record :: proc(state: ^State, name: string) {
	w := &state.workspace_events
	sync.mutex_lock(&w.mutex); defer sync.mutex_unlock(&w.mutex)
	switch name {
	case "NSWorkspaceDidWakeNotification":
		w.pending += {.Wake}
	case "NSApplicationDockDidRestartNotification":
		w.pending += {.Dock_Restart}
	case "com.apple.dock.prefchanged":
		w.pending += {.Dock_Pref}
	case "AppleInterfaceMenuBarHidingChangedNotification":
		w.pending += {.Menu_Bar}
	case "NSWorkspaceActiveDisplayDidChangeNotification":
		w.pending += {.Display}
	case "NSWorkspaceActiveSpaceDidChangeNotification",
	     "NSWorkspaceDidHideApplicationNotification",
	     "NSWorkspaceDidUnhideApplicationNotification":
		w.pending += {.Refresh}
	case "AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop":
		w.desired_mission = true
	case "AXExposeExit":
		w.desired_mission = false
	case:
	}
}

workspace_start :: proc(state: ^State) -> bool {
	sync.mutex_lock(&workspace_registry_mutex)
	defer sync.mutex_unlock(&workspace_registry_mutex)
	if workspace_listener_class == nil {
		workspace_listener_class = objc.objc_allocateClassPair(
			objc.objc_lookUpClass("NSObject"),
			"ShojiWorkspaceObserver",
			0,
		)
		if workspace_listener_class == nil {
			return false
		}
		if !objc.class_addMethod(
			workspace_listener_class,
			objc.sel_registerName("notification:"),
			cast(objc.IMP)workspace_notification,
			"v@:@",
		) {
			return false
		}
		objc.objc_registerClassPair(workspace_listener_class)
	}
	if workspace_listener_states == nil {
		workspace_listener_states = make(map[rawptr]^State)
	}
	w := &state.workspace_events
	w.listener = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(workspace_listener_class),
		"new",
	)
	workspace_listener_states[rawptr(w.listener)] = state
	w.centers[0] = intrinsics.objc_send(^objc.Object, workspace(), "notificationCenter")
	w.centers[1] = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSNotificationCenter")),
		"defaultCenter",
	)
	w.centers[2] = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSDistributedNotificationCenter")),
		"defaultCenter",
	)
	names := [][]string {
		{
			"NSWorkspaceDidWakeNotification",
			"NSWorkspaceActiveDisplayDidChangeNotification",
			"NSWorkspaceActiveSpaceDidChangeNotification",
			"NSWorkspaceDidHideApplicationNotification",
			"NSWorkspaceDidUnhideApplicationNotification",
		},
		{"NSApplicationDockDidRestartNotification"},
		{"com.apple.dock.prefchanged", "AppleInterfaceMenuBarHidingChangedNotification"},
	}
	for group, i in names {
		for name in group {
			value := cf_string(name)
			intrinsics.objc_send(
				nil,
				w.centers[i],
				"addObserver:selector:name:object:",
				w.listener,
				objc.sel_registerName("notification:"),
				(^objc.Object)(value),
				(^objc.Object)(nil),
			)
			CFRelease(value)
		}
	}
	return true
}

workspace_unobserve_dock :: proc(state: ^State) {
	w := &state.workspace_events
	if w.dock_observer != nil {
		CFRunLoopRemoveSource(
			CFRunLoopGetMain(),
			AXObserverGetRunLoopSource(w.dock_observer),
			kCFRunLoopDefaultMode,
		)
		CFRelease(w.dock_observer); w.dock_observer = nil
	}
	if w.dock_element != nil {
		CFRelease(w.dock_element); w.dock_element = nil
	}
}

workspace_stop :: proc(state: ^State) {
	w := &state.workspace_events
	workspace_unobserve_dock(state)
	if w.listener != nil {
		for center in w.centers {intrinsics.objc_send(nil, center, "removeObserver:", w.listener)}
		sync.mutex_lock(&workspace_registry_mutex)
		delete_key(&workspace_listener_states, rawptr(w.listener))
		if len(workspace_listener_states) == 0 {
			delete(workspace_listener_states); workspace_listener_states = nil
		}
		sync.mutex_unlock(&workspace_registry_mutex)
		intrinsics.objc_send(nil, w.listener, "release")
		w.listener = nil
	}
}

mission_callback :: proc "c" (observer, element, notification: Ref, user: rawptr) {
	context = runtime.default_context()
	workspace_record((^State)(user), text(notification))
}

// Keep the last live PID across a poll that observes Dock absent.
workspace_set_dock_pid :: proc(state: ^State, pid: i32) {
	w := &state.workspace_events
	if pid == w.dock_pid {
		return
	}
	workspace_unobserve_dock(state)
	if pid != 0 {
		if w.last_dock_pid != 0 && pid != w.last_dock_pid {
			workspace_record(state, "NSApplicationDockDidRestartNotification")
		}
		w.last_dock_pid = pid
	}
	w.dock_pid = pid
	workspace_record(state, "AXExposeExit")
}

workspace_poll_dock :: proc() -> i32 {
	// Also safe when called by startup diagnostics outside the daemon loop.
	pool := pool_push(); defer pool_pop(pool)
	identifier := cf_string("com.apple.dock")
	defer CFRelease(identifier)
	apps := intrinsics.objc_send(
		^objc.Object,
		Running_Application,
		"runningApplicationsWithBundleIdentifier:",
		(^objc.Object)(identifier),
	)
	if intrinsics.objc_send(uint, apps, "count") != 1 {
		return 0
	}
	app := intrinsics.objc_send(^objc.Object, apps, "objectAtIndex:", uint(0))
	return intrinsics.objc_send(i32, app, "processIdentifier")
}

workspace_tick :: proc(state: ^State, detect_dock: bool = true) {
	w := &state.workspace_events
	now := time.now()
	if detect_dock && (w.last_poll == time.Time{} || time.diff(w.last_poll, now) >= time.Second) {
		w.last_poll = now
		pid := workspace_poll_dock()
		workspace_set_dock_pid(state, pid)
		if pid != 0 && w.dock_observer == nil {
			w.dock_element = AXUIElementCreateApplication(pid)
			if AXObserverCreate(pid, mission_callback, &w.dock_observer) == 0 {
				for name in ([]string {
						"AXExposeShowAllWindows",
						"AXExposeShowFrontWindows",
						"AXExposeShowDesktop",
						"AXExposeExit",
					}) {observe(state, w.dock_observer, w.dock_element, name)}
				CFRunLoopAddSource(
					CFRunLoopGetMain(),
					AXObserverGetRunLoopSource(w.dock_observer),
					kCFRunLoopDefaultMode,
				)
			} else {
				CFRelease(w.dock_element); w.dock_element = nil
			}
		}
	}
	sync.mutex_lock(&w.mutex)
	pending, mission := w.pending, w.desired_mission
	w.pending = {}
	sync.mutex_unlock(&w.mutex)
	if .Wake in pending {
		mouse_wake(state, now)
	}
	if mission != w.mission_active {
		w.mission_active = mission
		state.manager.suspended = mission
		state.dirty = true
		emit(state, Event{name = mission ? "mission_control_enter" : "mission_control_exit"})
	}
	names := [Workspace_Event]string {
		.Wake         = "system_woke",
		.Dock_Restart = "dock_did_restart",
		.Dock_Pref    = "dock_did_change_pref",
		.Menu_Bar     = "menu_bar_hidden_changed",
		.Display      = "display_changed",
		.Refresh      = "",
	}
	for event in pending {
		state.dirty = true
		// Display IDs are only known after refresh reconciles the active Space.
		if event != .Refresh && event != .Display {
			emit(state, Event{name = names[event]})
		}
	}
}

// Application polling policy
// ------------------------------------------------------------------------

// Query WindowServer once, rather than sending AXWindows to every menu-bar helper.
// Occluded windows are included; desktop elements and non-document levels are not.
accessory_window_owners :: proc() -> (owners: map[i32]bool, known: bool) {
	list := CGWindowListCopyWindowInfo(1 | 16, 0)
	if list == nil {
		return nil, false
	}
	defer CFRelease(list)
	owners = make(map[i32]bool, context.temp_allocator)
	for i in 0 ..< CFArrayGetCount(list) {
		entry := CFArrayGetValueAtIndex(list, i)
		if number(dictionary(entry, "kCGWindowLayer")) != 0 {
			continue
		}
		pid := i32(number(dictionary(entry, "kCGWindowOwnerPID")))
		if pid > 0 {
			owners[pid] = true
		}
	}
	return owners, true
}

poll_application_windows :: proc(
	pid: i32,
	activation_policy: int,
	frontmost_pid: i32,
	owners: map[i32]bool,
	owners_known: bool,
) -> bool {
	if activation_policy == 0 {
		return true
	}
	if activation_policy != 1 {
		return false
	}
	return !owners_known || pid == frontmost_pid || owners[pid]
}

// Opening notices
// ------------------------------------------------------------------------

// A space-blocked newcomer remains managed. The notice explains why no new
// tile has appeared, without changing another window's position or focus.
opening_notice_space :: proc(m: ^Manager, frontmost_pid: i32) -> ^Space {
	if frontmost_pid <= 0 {
		return nil
	}
	for _, w in m.windows {
		// A blocked background app must not leave its warning over another app.
		if w.pid != frontmost_pid {
			continue
		}
		if w.opening.phase == .Pending && w.opening.wait == .Space {
			if s := space_by_id(m, w.space); s != nil && s.visible {
				return s
			}
		}
	}
	return nil
}

native_frontmost_pid :: proc() -> i32 {
	front := intrinsics.objc_send(^objc.Object, workspace(), "frontmostApplication")
	return intrinsics.objc_send(i32, front, "processIdentifier")
}

opening_notice_tick :: proc(state: ^State, frontmost: proc() -> i32 = native_frontmost_pid) {
	if len(state.opening_windows) == 0 && state.opening_notice.id == 0 {
		return
	}
	pid := frontmost()
	blocked := opening_notice_space(&state.manager, pid)
	if blocked == nil {
		if state.opening_notice.id != 0 {
			surface_destroy(state, state.opening_notice)
			state.opening_notice = {}
		}
		return
	}
	if state.connection == 0 {
		return
	}
	frame := Rect {
		blocked.view.frame.x + max(0, blocked.view.frame.w - 330),
		blocked.view.frame.y + 12,
		316,
		48,
	}
	if state.opening_notice.id != 0 {
		if state.opening_notice.frame != frame &&
		   surface_update(state, state.opening_notice, frame) == "" {
			state.opening_notice.frame = frame
		}
		return
	}
	surface, err := surface_create(state, frame, 0, (1 << 1) | (1 << 3) | (1 << 9), 13, 1)
	if err != "" {
		return
	}
	CGContextSetRGBFillColor(surface.ctx, .98, .95, .86, 1)
	CGContextFillRect(surface.ctx, {0, 0, 316, 48})
	graphics := (^objc.Object)(objc.objc_lookUpClass("NSGraphicsContext"))
	native := intrinsics.objc_send(
		^objc.Object,
		graphics,
		"graphicsContextWithCGContext:flipped:",
		surface.ctx,
		bool(false),
	)
	intrinsics.objc_send(nil, graphics, "saveGraphicsState")
	intrinsics.objc_send(nil, graphics, "setCurrentContext:", native)
	label := cf_string("Needs more room for a new window")
	intrinsics.objc_send(
		nil,
		(^objc.Object)(label),
		"drawInRect:withAttributes:",
		Rect{12, 12, 292, 24},
		(^objc.Object)(nil),
	)
	CFRelease(label)
	intrinsics.objc_send(nil, graphics, "restoreGraphicsState")
	CGContextFlush(surface.ctx)
	if surface_update(state, surface, frame) != "" ||
	   SLSSetWindowLevel(state.connection, surface.id, 20) != 0 ||
	   SLSOrderWindow(state.connection, surface.id, 1, 0) != 0 {
		surface_destroy(state, surface); return
	}
	state.opening_notice = surface
}
