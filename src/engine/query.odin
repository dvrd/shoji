package engine

import "core:encoding/json"
import "core:strings"

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
