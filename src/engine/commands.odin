package engine

import "core:strings"
import "core:math"
import "core:strconv"
import "core:encoding/json"

// Message framing
// ------------------------------------------------------------------------

MAX_MESSAGE :: 1024 * 1024
// The yabai client sends a little-endian i32 byte count followed by NUL-separated argv
// and a final extra NUL. Both supported macOS architectures are little-endian.
encode_message :: proc(args: []string) -> ([]u8, bool) {
	size := 1
	if len(args) == 0 {
		return nil, false
	}
	for arg in args {
		if strings.contains(arg, "\x00") {
			return nil, false
		}
		size += len(arg) + 1
		if size > MAX_MESSAGE {
			return nil, false
		}
	}
	data := make([]u8, size + 4)
	for i in 0 ..< 4 {
		data[i] = u8(u32(size) >> uint(8 * i))
	}
	offset := 4
	for arg in args {
		copy(data[offset:], transmute([]u8)arg)
		offset += len(arg) + 1
	}
	return data, true
}

decode_message :: proc(data: []u8) -> (args: [dynamic]string, ok: bool) {
	if len(data) < 6 || len(data) > MAX_MESSAGE + 4 {
		return
	}
	size := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	if int(size) != len(data) - 4 || data[len(data) - 1] != 0 || data[len(data) - 2] != 0 {
		return
	}
	begin := 4
	for i in 4 ..< len(data) - 1 {
		if data[i] == 0 {
			append(&args, string(data[begin:i]))
			begin = i + 1
		}
	}
	if len(args) == 0 || len(args[0]) == 0 {
		delete(args)
		return nil, false
	}
	return args, true
}

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

layout_name :: proc(layout: Layout) -> string {
	switch layout {
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

parse_layout :: proc(text: string) -> (Layout, bool) {
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
	if text == "recent" {return display_by_id(m, m.last_display)}
	if text == "mouse" {return display_by_id(m, m.mouse_display)}
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
		if origin == nil {return nil}
		ox, oy := origin.frame.x + origin.frame.w / 2, origin.frame.y + origin.frame.h / 2
		best: ^Display
		best_score := math.inf_f64(1)
		for &candidate in m.displays {
			if candidate.id == origin.id {continue}
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
			if major <= 0 {continue}
			// Prefer the closest display in the requested direction, then the
			// one most aligned with that direction.
			score := major * 10000 + math.abs(minor)
			if score < best_score {best, best_score = &candidate, score}
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
	}
	return failure(errorf("unknown command domain '%s'", args[0]))
}

// Queries
// ------------------------------------------------------------------------

Window_JSON :: struct {
	opening_state: string `json:"opening-state"`,
	resize_transitioning: bool `json:"resize-transitioning"`,
	size_request_pending: bool `json:"size-request-pending"`,
	width_adjusted: bool `json:"width-adjusted"`,
	height_adjusted: bool `json:"height-adjusted"`,
	accepted_width: f64 `json:"accepted-width"`,
	accepted_height: f64 `json:"accepted-height"`,
	layout_frame: Rect `json:"layout-frame"`,
	column_index: int `json:"column-index"`,
	column_tabbed: bool `json:"column-tabbed"`,
	column_active: bool `json:"column-active"`,
	column_full: bool `json:"column-full-width"`,
	column_width_request: f64 `json:"column-width-request"`,
	column_width_proportional: bool `json:"column-width-proportional"`,
	row_height_request: f64 `json:"row-height-request"`,
	row_weight: f64 `json:"row-weight"`,
	id:                   u32,
	pid:                  i32,
	app, title:           string,
	scratchpad:           string,
	frame:                Rect,
	role, subrole:        string,
	root_window:          bool `json:"root-window"`,
	display:              u32,
	space:                u32,
	level:                int,
	sub_level:            int `json:"sub-level"`,
	layer:                string,
	sub_layer:            string `json:"sub-layer"`,
	opacity:              f64,
	split_type:           string `json:"split-type"`,
	split_child:          string `json:"split-child"`,
	stack_index:          int `json:"stack-index"`,
	can_move:             bool `json:"can-move"`,
	can_resize:           bool `json:"can-resize"`,
	has_focus:            bool `json:"has-focus"`,
	has_shadow:           bool `json:"has-shadow"`,
	has_parent_zoom:      bool `json:"has-parent-zoom"`,
	has_fullscreen_zoom:  bool `json:"has-fullscreen-zoom"`,
	has_ax_reference:     bool `json:"has-ax-reference"`,
	is_native_fullscreen: bool `json:"is-native-fullscreen"`,
	is_visible:           bool `json:"is-visible"`,
	is_minimized:         bool `json:"is-minimized"`,
	is_hidden:            bool `json:"is-hidden"`,
	is_floating:          bool `json:"is-floating"`,
	is_sticky:            bool `json:"is-sticky"`,
	is_grabbed:           bool `json:"is-grabbed"`,
}

Space_JSON :: struct {
	scroll_resizing: bool `json:"scroll-resizing"`,
	scroll_position: f64 `json:"scroll-position"`,
	scroll_velocity: f64 `json:"scroll-velocity"`,
	scroll_animating: bool `json:"scroll-animating"`,
	scroll_interacting: bool `json:"scroll-interacting"`,
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
		opening_state = w.opening.phase == .Pending ? (w.opening.wait == .Space ? "needs-more-room" : (w.opening.wait == .Backend ? "waiting-for-backend" : "preparing")) : (w.opening.phase == .Opening ? "opening" : "settled"),
		resize_transitioning = w.resize_transitioning,
		size_request_pending = w.size_feedback.pending,
		width_adjusted = w.size_feedback.width_valid,
		height_adjusted = w.size_feedback.height_valid,
		accepted_width = w.size_feedback.width_valid ? w.size_feedback.accepted.w : 0,
		accepted_height = w.size_feedback.height_valid ? w.size_feedback.accepted.h : 0,
		id                   = w.id,
		pid                  = w.pid,
		app                  = w.app,
		title                = w.title,
		frame                = w.frame,
		role                 = w.role,
		subrole              = w.subrole,
		root_window          = w.root_window.? or_else true,
		is_grabbed           = w.grabbed,
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
		if n := find(s.view.root, w.id); n != nil {
			if s.view.layout == .Scroll {
				result.layout_frame = size_feedback_frame(w, scroll_window_frame(&s.view, n, w.id, false))
				result.column_tabbed, result.column_active, result.column_full = n.column_tabbed, n.order[0] == w.id, n.column_full
				size := n.column_size.kind == .Default ? s.view.scroll_options.default_width : n.column_size
				result.column_width_request, result.column_width_proportional = size.value, size.kind == .Proportion
				result.row_height_request, result.row_weight = w.row_fixed, w.row_weight > 0 ? w.row_weight : 1
				for column := first(s.view.root); column != nil; column = next(column) {result.column_index += 1; if column == n {break}}
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
		scroll_resizing = s.view.scroll.geometry_active,
		scroll_position = m.scroll_animate && s.view.scroll.motion.initialized ? s.view.scroll.motion.position : s.view.scroll.offset,
		scroll_velocity = s.view.scroll.motion.velocity,
		scroll_animating = s.view.scroll.motion.active,
		scroll_interacting = s.view.scroll.dragging,
		scroll_offset = s.view.scroll.offset,
		scroll_width = s.view.scroll.content_width,
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
	if n := first(s.view.root); n != nil && n.count > 0 {
		result.first_window = n.windows[0]
	}
	if n := last(s.view.root); n != nil && n.count > 0 {
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
	if len(args) < 2 || strings.has_prefix(args[1], "--") {return query_full(m, args)}
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
	if err != nil {return failure("could not inspect query schema")}
	object := shape.(json.Object)
	for field in fields {
		if _, exists := object[field];
		   !exists {return failure(errorf("unknown query property '%s'", field))}
	}
	clean := make([dynamic]string, 0, len(args) - 1, context.temp_allocator)
	append(&clean, args[0]);append(&clean, ..args[2:])
	response := query_full(m, clean[:])
	if response.failed {return response}
	value, parse_err := json.parse(
		response.text,
		parse_integers = true,
		allocator = context.temp_allocator,
	)
	if parse_err != nil {return failure("could not parse query output")}
	projected := project_query(value, fields)
	data, marshal_err := json.unparse(projected, allocator = context.temp_allocator)
	if marshal_err != nil {return failure("could not encode projected query")}
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
	if op == "--destroy" && operand != "" {s = select_space(m, operand)}
	if op == "--create" && operand != "" {
		if d := select_display(m, operand);
		   d !=
		   nil {s = space_by_id(m, d.active_space)} else {return failure("could not locate display")}
	}
	if s == nil {
		return failure("could not locate space")
	}
	switch op {
	case "--scroll":
		if s.view.layout != .Scroll {return failure("scroll requires scroll layout")}
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 2 {return failure("scroll expects abs:pixels or rel:pixels")}
		value, ok := strconv.parse_f64(parts[1])
		if !ok || math.is_nan(value) || math.is_inf(value) {return failure("invalid scroll offset")}
		switch parts[0] {
		case "abs":
		case "rel": value += s.view.scroll.offset
		case: return failure("scroll expects abs or rel")
		}
		scroll_pan(&s.view, value)
		s.view.scroll.centered = false
		s.view.scroll.focused = m.focused;s.view.scroll.reveal = false
	case "--layout":
		layout, ok := parse_layout(operand)
		if !ok {
			return failure("invalid layout")
		}
		set_layout(m, s, layout)
		s.overrides["layout"] = true
	case "--rotate":
		if s.view.layout == .Scroll {return failure("rotation is unavailable in scroll layout")}
		angle, ok := strconv.parse_int(operand)
		if !ok || (angle != 90 && angle != 180 && angle != 270) {
			return failure("rotate expects 90, 180, or 270")
		}
		rotate(s.view.root, angle)
	case "--mirror":
		if s.view.layout == .Scroll {return failure("mirroring is unavailable in scroll layout")}
		if operand != "x-axis" && operand != "y-axis" {
			return failure("mirror expects x-axis or y-axis")
		}
		mirror(s.view.root, operand == "x-axis" ? .Horizontal : .Vertical)
	case "--balance", "--equalize":
		if s.view.layout == .Scroll {return failure("balance/equalize split ratios are unavailable in scroll layout")}
		axis: Split
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
			balance(s.view.root, axis)
		} else {
			equalize(s.view.root, axis, s.view.ratio)
		}
	case "--label":
		delete(s.label)
		s.label = strings.clone(operand)
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
		p := Padding{values[0], values[1], values[2], values[3]}
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
		if s == target {return success()}
		if s.display !=
		   target.display {return failure("space --move requires the same display; use --display")}
		if s.fullscreen ||
		   target.fullscreen {return failure("cannot reorder native fullscreen spaces")}
		if s.index < target.index {return result(move_space_after(m, s, target))}
		previous := previous_space_on_display(m, target)
		if previous != nil {return result(move_space_after(m, s, previous))}
		return result(move_space_pair(m, s, target, target, s))
	case "--swap", "--switch":
		target := select_space(m, operand)
		if op == "--switch" {s = select_space(m, "")}
		if target == nil || s == nil {return failure("could not locate target space")}
		if s == target {return success()}
		if s.fullscreen ||
		   target.fullscreen {return failure("cannot swap native fullscreen spaces")}
		if op == "--switch" &&
		   s.display ==
			   target.display {return result(perform(m, {kind = .Space_Focus, space = target.id}))}
		if s.display != target.display {
			if err := swap_space_windows(m, s, target); err != "" {return failure(err)}
		} else {
			earlier, later := s, target
			if earlier.index > later.index {earlier, later = later, earlier}
			previous := previous_space_on_display(m, later)
			if previous == earlier {previous = later}
			if err := move_space_pair(m, later, earlier, earlier, previous); err != "" {return failure(err)}
		}
		if op == "--switch" {return result(perform(m, {kind = .Space_Focus, space = target.id}))}
		return success()
	case "--display":
		d := select_display(m, operand)
		if d == nil {return failure("could not locate display")}
		if s.display == d.id {return success()}
		if s.fullscreen {return failure("cannot move a native fullscreen space")}
		return result(perform(m, {kind = .Space_Move, space = s.id, destination = d.active_space}))
	case:
		return failure(errorf("unsupported space operation '%s'", op))
	}
	return result(flush(m, s))
}

previous_space_on_display :: proc(m: ^Manager, target: ^Space) -> ^Space {
	previous: ^Space
	for s in m.spaces {if s == target {return previous};if s.display == target.display {previous = s}}
	return nil
}

move_space_pair :: proc(m: ^Manager, first, first_anchor, second, second_anchor: ^Space) -> string {
	original := make([dynamic]^Space, context.temp_allocator)
	for space in m.spaces {if space.display == first.display {append(&original, space)}}
	if err := move_space_after(m, first, first_anchor); err != "" {return err}
	if err := move_space_after(m, second, second_anchor); err != "" {
		// Rebuild the original adjacency through real backend moves. Updating only
		// the array would conceal the partial reorder that already reached Dock.
		for i in 1 ..< len(original) {
			space, anchor := original[i], original[i - 1]
			if previous_space_on_display(m, space) == anchor {continue}
			if rollback := move_space_after(m, space, anchor); rollback != "" {
				return errorf("%s; rollback failed: %s", err, rollback)
			}
		}
		return err
	}
	return ""
}

move_space_after :: proc(m: ^Manager, s, anchor: ^Space) -> string {
	if s == nil || anchor == nil || s == anchor {return "invalid space move"}
	if err := perform(m, {kind = .Space_Move, space = s.id, destination = anchor.id});
	   err != "" {return err}
	from, to := -1, -1
	for space, i in m.spaces {if space == s {from = i};if space == anchor {to = i}}
	if from > to {to += 1}
	if from < to {for j := from; j < to; j += 1 {m.spaces[j] = m.spaces[j + 1]}}
	if from > to {for j := from; j > to; j -= 1 {m.spaces[j] = m.spaces[j - 1]}}
	m.spaces[to] = s
	for &d in m.displays {clear(&d.spaces)}
	for space, i in m.spaces {
		space.index = u32(i + 1)
		if d := display_by_id(m, space.display); d != nil {append(&d.spaces, space.id)}
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
		if w.space == a.id {append(&moves, Space_Window_Move{w, a, b, false})}
		if w.space == b.id {append(&moves, Space_Window_Move{w, b, a, false})}
	}
	err := ""
	for &move in moves {
		if error := perform(m, {kind = .Space, window = move.window.id, space = move.target.id});
		   error != "" {err = error;break}
		move.moved = true
	}
	if err != "" {
		for &move in moves {
			if move.moved {
				if rollback := perform(
					m,
					{kind = .Space, window = move.window.id, space = move.source.id},
				);
				rollback ==
				"" {move.moved = false} else {err = errorf("%s; rollback failed: %s", err, rollback)}
			}
		}
	}
	for move in moves {
		if !move.moved {continue}
		move.window.space, move.window.display = move.target.id, move.target.display
		if err != "" {
			remove(&move.source.view, move.window.id)
			if layout_admitted(move.window) {add(&move.target.view, move.window.id)}
		}
	}
	if err != "" {return err}
	// The windows and their complete virtual desktop move together. Keep native
	// Space identity and destination geometry, including when one side is empty.
	a_frame, b_frame := a.view.frame, b.view.frame
	a.view, b.view = b.view, a.view
	a.view.frame, b.view.frame = a_frame, b_frame
	a.overrides, b.overrides = b.overrides, a.overrides
	a.label, b.label = b.label, a.label
	if err := flush(m, a); err != "" {return err}
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
		if s == nil {return failure("could not locate space")}
		if s.display != d.id {return failure("space must belong to the selected display")}
		return result(perform(m, Action{kind = .Space_Focus, space = s.id}))
	}
	if args[0] == "--focus" {
		return result(
			perform(m, Action{kind = .Display_Focus, display = d.id, space = d.active_space}),
		)
	}
	return failure("unsupported display operation")
}
