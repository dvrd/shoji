package engine

import "core:math"
import "core:strconv"
import "core:strings"
import "core:fmt"

// Layout tree
// ------------------------------------------------------------------------

Rect :: struct {
	x, y, w, h: f64,
}

Split :: enum {
	Auto,
	Vertical,
	Horizontal,
}

Layout :: enum {
	Float,
	BSP,
	Stack,
	Scroll,
}

Direction :: enum {
	North,
	East,
	South,
	West,
}

Padding :: struct {
	top, bottom, left, right: f64,
}

MAX_STACK :: 32
Node :: struct {
	parent, left, right, zoom: ^Node,
	frame:                     Rect,
	minimum:                   Rect,
	windows, order:            [MAX_STACK]u32,
	count:                     int,
	ratio:                     f64,
	column_width:              f64,
	column_observed: f64,
	column_revision: u64,
	column_size: Scroll_Size,
	column_resolved: f64,
	column_preset: Maybe(int),
	column_full, column_tabbed: bool,
	column_raised: u32,
	column_min, column_max: f64,
	row_heights: [MAX_STACK]f64,
	split:                     Split,
	insert_first:              Maybe(bool),
	insert_stack:              bool,
}

View :: struct {
	root:                                                    ^Node,
	layout:                                                  Layout,
	frame:                                                   Rect,
	padding:                                                 Padding,
	gap, ratio:                                              f64,
	split:                                                   Split,
	padding_enabled, gap_enabled, first_child, auto_balance: bool,
	balance_axis:                                            Split,
	zoom_persist:                                            bool,
	tab_indicator_top:                                       bool,
	tab_indicator_width:                                     f64,
	insertion:                                               u32,
	scroll:                                                  Scroll_State,
	scroll_options: Scroll_Options,
}

view_init :: proc(v: ^View, frame: Rect, layout: Layout = .BSP) {
	v^ = View {
		root            = new(Node),
		frame           = frame,
		layout          = layout,
		ratio           = 0.5,
		tab_indicator_width = 4,
		padding_enabled = true,
		gap_enabled     = true,
		scroll_options = scroll_options_defaults(),
	}
	v.root.frame = frame
}

node_destroy :: proc(n: ^Node) {
	if n == nil {
		return
	}
	node_destroy(n.left)
	node_destroy(n.right)
	free(n)
}

view_destroy :: proc(v: ^View) {
	node_destroy(v.root)
	v.root = nil
}

leaf :: proc(n: ^Node) -> bool {
	return n != nil && n.left == nil && n.right == nil
}

find :: proc(n: ^Node, id: u32) -> ^Node {
	if n == nil || id == 0 {
		return nil
	}
	for i in 0 ..< n.count {
		if n.windows[i] == id {
			return n
		}
	}
	if a := find(n.left, id); a != nil {
		return a
	}
	return find(n.right, id)
}

first :: proc(n: ^Node) -> ^Node {
	n := n
	for n != nil && n.left != nil {
		n = n.left
	}
	return n
}

last :: proc(n: ^Node) -> ^Node {
	n := n
	for n != nil && n.right != nil {
		n = n.right
	}
	return n
}

next :: proc(n: ^Node) -> ^Node {
	n := n
	for n != nil && n.parent != nil {
		p := n.parent
		if p.left == n {
			return first(p.right)
		}
		n = p
	}
	return nil
}

previous :: proc(n: ^Node) -> ^Node {
	n := n
	for n != nil && n.parent != nil {
		p := n.parent
		if p.right == n {
			return last(p.left)
		}
		n = p
	}
	return nil
}

clear_zoom :: proc(n: ^Node) {
	if n == nil {
		return
	}
	n.zoom = nil
	clear_zoom(n.left)
	clear_zoom(n.right)
}
// Preserve yabai's truncation and half-pixel rounding when partitioning a frame.
partition :: proc(r: Rect, split: Split, ratio, gap: f64) -> (a, b: Rect) {
	a, b = r, r
	if split == .Vertical {
		available := max(0, r.w - gap)
		a.w = math.floor(available * ratio)
		b.w = math.floor(available * (1 - ratio))
		b.x += math.floor(available * ratio + 0.5) + gap
	} else {
		available := max(0, r.h - gap)
		a.h = math.floor(available * ratio)
		b.h = math.floor(available * (1 - ratio))
		b.y += math.floor(available * ratio + 0.5) + gap
	}
	return
}

node_update :: proc(v: ^View, n: ^Node) {
	if n == nil || leaf(n) {
		return
	}
	if n.split == .Auto {
		n.split = v.split
		if n.split == .Auto {
			n.split = n.frame.w >= n.frame.h ? .Vertical : .Horizontal
		}
	}
	if n.ratio < 0.1 || n.ratio > 0.9 {
		n.ratio = v.ratio
	}
	gap := v.gap_enabled ? v.gap : 0
	ratio := n.ratio
	if v.layout == .BSP {
		available := n.split == .Vertical ? n.frame.w - gap : n.frame.h - gap
		a := n.split == .Vertical ? n.left.minimum.w : n.left.minimum.h
		b := n.split == .Vertical ? n.right.minimum.w : n.right.minimum.h
		if available > 0 && a + b <= available {ratio = clamp(ratio, a / available, 1 - b / available)}
	}
	n.left.frame, n.right.frame = partition(n.frame, n.split, ratio, gap)
	node_update(v, n.left)
	node_update(v, n.right)
}

view_update :: proc(v: ^View) {
	r := v.frame
	if v.padding_enabled {
		r.x += v.padding.left
		r.y += v.padding.top
		r.w = max(0, r.w - v.padding.left - v.padding.right)
		r.h = max(0, r.h - v.padding.top - v.padding.bottom)
	}
	v.root.frame = r
	if v.layout == .Scroll {
		if v.scroll.viewport != r {v.scroll.reveal = true}
		v.scroll.viewport = r;scroll_update(v);return
	}
	node_update(v, v.root)
}

stack_push :: proc(n: ^Node, id: u32) -> bool {
	if n == nil || !leaf(n) || n.count == MAX_STACK || id == 0 {
		return false
	}
	for i in 0 ..< n.count {
		if n.windows[i] == id {
			return false
		}
	}
	insert := n.count
	for i in 0 ..< n.count {
		if n.windows[i] == n.order[0] {
			insert = i + 1
			break
		}
	}
	for i := n.count; i > insert; i -= 1 {
		n.windows[i] = n.windows[i - 1]
	}
	n.windows[insert] = id
	for i := n.count; i > 0; i -= 1 {
		n.order[i] = n.order[i - 1]
	}
	n.order[0] = id
	n.count += 1
	return true
}

Zoom_Record :: struct {
	window:     u32,
	fullscreen: bool,
}

capture_zooms :: proc(v: ^View) -> [dynamic]Zoom_Record {
	result := make([dynamic]Zoom_Record, context.temp_allocator)
	if !v.zoom_persist {return result}
	for n := first(v.root); n != nil; n = next(n) {
		if n.zoom == nil {continue}
		for i in 0 ..< n.count {append(&result, Zoom_Record{n.windows[i], n.zoom == v.root})}
	}
	return result
}

restore_zooms :: proc(v: ^View, records: []Zoom_Record) {
	if !v.zoom_persist {return}
	for record in records {
		if n := find(v.root, record.window);
		   n != nil {n.zoom = record.fullscreen ? v.root : n.parent}
	}
}

add :: proc(v: ^View, id: u32, insertion: u32 = 0) -> bool {
	if id == 0 || find(v.root, id) != nil || v.layout == .Float {
		return false
	}
	zooms := capture_zooms(v)
	defer restore_zooms(v, zooms[:])
	n := find(v.root, insertion)
	if n == nil {
		n = find(v.root, v.insertion)
	}
	if n == nil {
		if v.layout == .Scroll {n = find(v.root, v.scroll.focused)}
	}
	if n == nil {
		n = minimum_depth(v.root)
	}
	if v.layout == .Scroll {scroll_before_add(v, id)}
	if n.count == 0 || v.layout == .Stack || n.insert_stack {
		if n.count == 0 && v.layout == .Scroll {
			n.column_tabbed = v.scroll_options.default_tabbed
		}
		ok := stack_push(n, id)
		if ok {
			n.insert_stack = false
			v.insertion = 0
		}
		return ok
	}
	old := new(Node)
	fresh := new(Node)
	old^ = Node {
		parent  = n,
		windows = n.windows,
		order   = n.order,
		count   = n.count,
		column_width = n.column_width,
		column_revision = n.column_revision,
		column_size = n.column_size,
		column_resolved = n.column_resolved,
		column_preset = n.column_preset,
		column_full = n.column_full,
		column_tabbed = n.column_tabbed,
	}
	fresh^ = Node {
		parent = n,
		count  = 1,
		column_tabbed = v.layout == .Scroll && v.scroll_options.default_tabbed,
	}
	fresh.windows[0] = id
	fresh.order[0] = id
	n.left, n.right = old, fresh
	if n.insert_first.? or_else (v.layout != .Scroll && v.first_child) {
		n.left, n.right = fresh, old
	}
	n.insert_first = nil
	n.count = 0
	n.zoom = nil
	if v.auto_balance {
		balance(v.root, v.balance_axis)
	}
	view_update(v)
	v.insertion = 0
	return true
}

can_add :: proc(v: ^View, insertion: u32 = 0) -> bool {
	if v.layout == .Float {return false}
	n := find(v.root, insertion)
	if n == nil {n = find(v.root, v.insertion)}
	if n == nil {n = minimum_depth(v.root)}
	return n != nil && (!(v.layout == .Stack || n.insert_stack) || n.count < MAX_STACK)
}

remove :: proc(v: ^View, id: u32) -> bool {
	n := find(v.root, id)
	if n == nil {
		return false
	}
	if v.layout == .Scroll {scroll_before_remove(v, id)}
	zooms := capture_zooms(v)
	defer restore_zooms(v, zooms[:])
	if v.insertion == id {
		v.insertion = 0
	}
	for list in ([2]^[MAX_STACK]u32{&n.windows, &n.order}) {
		for i in 0 ..< n.count {
			if list[i] == id {
				for j in i ..< n.count - 1 {
					list[j] = list[j + 1]
				}
				list[n.count - 1] = 0
				break
			}
		}
	}
	n.count -= 1
	if n.count > 0 || n.parent == nil {
		return true
	}
	clear_zoom(v.root)
	p := n.parent
	sibling := p.left == n ? p.right : p.left
	parent, frame := p.parent, p.frame
	p^ = sibling^
	p.parent = parent
	p.frame = frame
	if p.left != nil {
		p.left.parent = p
		p.right.parent = p
	}
	free(sibling)
	free(n)
	if v.auto_balance {
		balance(v.root, v.balance_axis)
	}
	view_update(v)
	return true
}

swap :: proc(a, b: ^Node) -> bool {
	if !leaf(a) || !leaf(b) || a == b {
		return false
	}
	a.windows, b.windows = b.windows, a.windows
	a.order, b.order = b.order, a.order
	a.count, b.count = b.count, a.count
	a.zoom, b.zoom = nil, nil
	return true
}

rotate :: proc(n: ^Node, degrees: int) {
	if n == nil || leaf(n) {
		return
	}
	if (degrees == 90 && n.split == .Vertical) ||
	   (degrees == 270 && n.split == .Horizontal) ||
	   degrees == 180 {
		n.left, n.right = n.right, n.left
		n.ratio = 1 - n.ratio
	}
	if degrees != 180 {
		n.split = n.split == .Vertical ? .Horizontal : .Vertical
	}
	rotate(n.left, degrees)
	rotate(n.right, degrees)
}

mirror :: proc(n: ^Node, axis: Split) {
	if n == nil || leaf(n) {
		return
	}
	if n.split == axis {
		n.left, n.right = n.right, n.left
	}
	mirror(n.left, axis)
	mirror(n.right, axis)
}

equalize :: proc(n: ^Node, axis: Split = .Auto, ratio: f64 = 0.5) {
	if n == nil || leaf(n) {
		return
	}
	if axis == .Auto || axis == n.split {
		n.ratio = ratio
	}
	equalize(n.left, axis, ratio)
	equalize(n.right, axis, ratio)
}

balance :: proc(n: ^Node, axis: Split = .Auto) -> (counts: [2]int) {
	if n == nil {
		return
	}
	if leaf(n) {
		if n.parent != nil {
			counts[n.parent.split == .Vertical ? 0 : 1] = 1
		}
		return
	}
	a, b := balance(n.left, axis), balance(n.right, axis)
	counts = [2]int{a[0] + b[0], a[1] + b[1]}
	index := n.split == .Vertical ? 0 : 1
	if (axis == .Auto || axis == n.split) && counts[index] > 0 {
		n.ratio = f64(a[index]) / f64(counts[index])
		counts[index] -= 1
	}
	if n.parent != nil {
		counts[n.parent.split == .Vertical ? 0 : 1] += 1
	}
	return
}

focus_order :: proc(n: ^Node, id: u32) {
	if n == nil {
		return
	}
	for i in 0 ..< n.count {
		if n.order[i] == id {
			for j := i; j > 0; j -= 1 {
				n.order[j] = n.order[j - 1]
			}
			n.order[0] = id
			return
		}
	}
}

frame_for :: proc(n: ^Node) -> Rect {
	return n.zoom != nil ? n.zoom.frame : n.frame
}

neighbor :: proc(root, source: ^Node, direction: Direction) -> ^Node {
	if source == nil {
		return nil
	}
	a := source.frame
	best: ^Node
	distance := math.INF_F64
	for n := first(root); n != nil; n = next(n) {
		if n == source || n.count == 0 {
			continue
		}
		b := n.frame
		dx := b.x + b.w / 2 - a.x - a.w / 2
		dy := b.y + b.h / 2 - a.y - a.h / 2
		eligible := false
		switch direction {
		case .North:
			eligible = dy < 0 && b.x < a.x + a.w && b.x + b.w > a.x
		case .South:
			eligible = dy > 0 && b.x < a.x + a.w && b.x + b.w > a.x
		case .East:
			eligible = dx > 0 && b.y < a.y + a.h && b.y + b.h > a.y
		case .West:
			eligible = dx < 0 && b.y < a.y + a.h && b.y + b.h > a.y
		}
		d := dx * dx + dy * dy
		if eligible && d < distance {
			best = n
			distance = d
		}
	}
	return best
}

minimum_depth :: proc(root: ^Node) -> ^Node {
	if root == nil {
		return nil
	}
	queue := make([dynamic]^Node, 0, 16, context.temp_allocator)
	append(&queue, root)
	for i := 0; i < len(queue); i += 1 {
		n := queue[i]
		if leaf(n) {
			return n
		}
		append(&queue, n.left, n.right)
	}
	return nil
}

// BSP constraints
// ------------------------------------------------------------------------

// Cache constraints on a candidate tree. The requested ratio is retained;
// node_update derives the closest feasible partition for the current bounds.
bsp_measure :: proc(m: ^Manager, n: ^Node, gap: f64) {
	if n == nil {return}
	n.minimum = {}
	if leaf(n) {
		for i in 0 ..< n.count {
			if w := m.windows[n.windows[i]]; w != nil {
				n.minimum.w = max(n.minimum.w, max(w.min_width, w.opening.minimum.w))
				n.minimum.h = max(n.minimum.h, max(w.min_height, w.opening.minimum.h))
			}
		}
		return
	}
	bsp_measure(m, n.left, gap);bsp_measure(m, n.right, gap)
	a, b := n.left.minimum, n.right.minimum
	if n.split == .Vertical {n.minimum = {w = a.w + b.w + gap, h = max(a.h, b.h)}}
	else {n.minimum = {w = max(a.w, b.w), h = a.h + b.h + gap}}
}

bsp_constraints :: proc(m: ^Manager, v: ^View) -> bool {
	view_update(v)
	bsp_measure(m, v.root, v.gap_enabled ? v.gap : 0)
	return v.root.minimum.w <= v.root.frame.w && v.root.minimum.h <= v.root.frame.h
}

// Scroll layout and viewport
// ------------------------------------------------------------------------

// The tree supplies column membership and ordering. Split ratios are unused:
// widths and viewport position are independent of BSP partition geometry.
Scroll_State :: struct {
	motion: Scroll_Motion,
	dragging: bool,
	geometry_enabled, geometry_active: bool,
	geometry_began: f64,
	viewport: Rect,
	offset, content_width: f64,
	focused: u32,
	reveal: bool,
	centered: bool,
	// Anchor by window identity, so resizing or removing earlier columns does
	// not move the active column on screen. offset remains the queryable camera.
	anchor: u32,
	anchor_x: f64,
	initialized: bool,
	opened, return_to: u32,
	return_x: f64,
}

scroll_gap :: proc(v: ^View) -> f64 { return v.gap_enabled ? v.gap : 0 }

tab_indicator_gutter :: proc(v: ^View, n: ^Node) -> f64 {
	return n != nil && n.column_tabbed && n.count > 1 && n.zoom == nil ? v.tab_indicator_width + 5 : 0
}

scroll_update :: proc(v: ^View) {
	r := v.scroll.viewport
	gap := scroll_gap(v)
	width := max(1, r.w)
	if !v.scroll.initialized {
		v.scroll.offset = -gap
		v.scroll.initialized = true
	}
	total: f64
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		// Existing drag/warp callers may assign a pixel width directly.
		if n.column_width > 0 && n.column_width != n.column_resolved {
			n.column_size = {.Fixed, n.column_width}
			n.column_preset = nil
		}
		size :=
			n.column_size.kind == .Default \
				? v.scroll_options.default_width \
				: n.column_size
		requested :=
			n.column_full \
				? max(1, width - 2 * gap) \
				: scroll_size_value(v, size)
		n.column_width = clamp(
			requested,
			max(1, n.column_min),
			max(
				max(1, n.column_min),
				n.column_max > 0 ? n.column_max : 100000,
			),
		)
		if find(v.root, v.scroll.anchor) == n &&
		   n.column_resolved != n.column_width {
			v.scroll.reveal = true
		}
		n.column_resolved = n.column_width
		if n.column_observed > 0 {n.column_width, n.column_resolved = n.column_observed, n.column_observed}
		total += n.column_width + gap
	}
	v.scroll.content_width = max(0, total - gap)
	anchor := find(v.root, v.scroll.anchor)
	logical_x: f64
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		if n == anchor {
			offset := logical_x - v.scroll.anchor_x
			if !v.scroll.geometry_enabled && v.scroll.motion.initialized && v.scroll.motion.anchor == v.scroll.anchor {
				shift := offset - v.scroll.offset
				v.scroll.motion.position += shift; v.scroll.motion.from += shift; v.scroll.motion.target += shift
			}
			v.scroll.offset = offset; break
		}
		logical_x += n.column_width + gap
	}
	x := r.x - v.scroll.offset
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		n.frame = {x, r.y + gap, n.column_width, max(1, r.h - 2 * gap)}
		x += n.column_width + gap
	}
}

scroll_anchor :: proc(v: ^View, window: u32) {
	if n := find(v.root, window); n != nil {
		v.scroll.anchor = window
		v.scroll.anchor_x = n.frame.x - v.scroll.viewport.x
	}
}

scroll_pan :: proc(v: ^View, offset: f64) {
	gap := scroll_gap(v)
	v.scroll.anchor = 0
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.offset = clamp(
		offset,
		-gap,
		max(-gap, v.scroll.content_width - v.scroll.viewport.w + gap),
	)
	scroll_update(v)
	scroll_anchor(v, v.scroll.focused)
}

scroll_before_add :: proc(v: ^View, id: u32) {
	v.scroll.opened = id
	v.scroll.return_to = v.scroll.focused
	if n := find(v.root, v.scroll.focused); n != nil {
		v.scroll.return_x = n.frame.x - v.scroll.viewport.x
	}
}

scroll_before_remove :: proc(v: ^View, id: u32) {
	n := find(v.root, id)
	if n == nil {
		return
	}
	if n.count > 1 {
		if v.scroll.anchor == id {
			for i in 0 ..< n.count {
				if n.windows[i] != id {
					v.scroll.anchor = n.windows[i]; break
				}
			}
		}
		return
	}
	if v.scroll.opened == id &&
	   v.scroll.focused == id &&
	   find(v.root, v.scroll.return_to) != nil {
		v.scroll.anchor = v.scroll.return_to
		v.scroll.anchor_x = v.scroll.return_x
		v.scroll.focused = v.scroll.return_to
		v.scroll.reveal = true
	} else if find(v.root, v.scroll.anchor) == n {
		target := next(n)
		if target == nil {
			target = previous(n)
		}
		v.scroll.anchor = 0
		if target != nil {
			scroll_anchor(v, target.order[0])
		}
	}
	if v.scroll.opened == id || v.scroll.return_to == id {
		v.scroll.opened, v.scroll.return_to = 0, 0
	}
}

scroll_reveal :: proc(v: ^View, window: u32, center: bool = false) {
	center := center
	n := find(v.root, window)
	if n == nil {
		return
	}
	v.scroll.centered = center
	r := v.scroll.viewport
	if v.scroll_options.center == .Always ||
	   (v.scroll_options.center_single && first(v.root) == last(v.root)) {
		center = true
	}
	if v.scroll_options.center == .On_Overflow {
		old := find(v.root, v.scroll.focused)
		if old != nil && old != n {
			neighbor := old.frame.x < n.frame.x ? previous(n) : next(n)
			if neighbor != nil &&
			   neighbor.column_width + n.column_width + 3 * scroll_gap(v) >
				   r.w {
				center = true
			}
		}
	}
	center = center && n.frame.w < r.w
	padding := min(scroll_gap(v), max(0, (r.w - n.frame.w) * 0.5))
	if v.scroll.focused != window && v.scroll.opened != window {
		v.scroll.opened, v.scroll.return_to = 0, 0
	}
	v.scroll.anchor = 0
	if center {
		v.scroll.offset += n.frame.x + n.frame.w * 0.5 - (r.x + r.w * 0.5)
	} else if n.frame.w >= r.w {
		v.scroll.offset += n.frame.x - r.x
	} else if n.frame.x < r.x + padding {
		v.scroll.offset += n.frame.x - r.x - padding
	} else if n.frame.x + n.frame.w > r.x + r.w - padding {
		v.scroll.offset += n.frame.x + n.frame.w - r.x - r.w + padding
	}
	scroll_update(v)
	scroll_anchor(v, window)
}

scroll_window_frame :: proc(
	v: ^View,
	n: ^Node,
	window: u32,
	park: bool = true,
	camera: Maybe(f64) = nil,
) -> Rect {
	r := frame_for(n)
	if position, current := camera.?; current {r.x += v.scroll.offset - position}
	if n.zoom != nil {
		return v.scroll.viewport
	}
	// Retain a visible edge to avoid requesting entirely off-screen placement.
	// This is parking, not clipping: horizontal adjacent displays may show it.
	if park {
		r = scroll_park_frame(v, r)
	}
	if gutter := tab_indicator_gutter(v, n); gutter > 0 {
		if v.tab_indicator_top {
			gutter = min(gutter, max(0, r.h - 1))
			r.y += gutter; r.h -= gutter
		} else {
			gutter = min(gutter, max(0, r.w - 1))
			r.x += gutter; r.w -= gutter
		}
	}
	if n.count > 1 && !n.column_tabbed {
		gap := min(scroll_gap(v), max(0, r.h / f64(n.count)))
		for i in 0 ..< n.count {
			if n.windows[i] == window {
				for j in 0 ..< i { r.y += n.row_heights[j] + gap }
				r.h = max(1, n.row_heights[i])
				break
			}
		}
	}
	return r
}

scroll_park_frame :: proc(v: ^View, frame: Rect) -> Rect {
	r := frame
	sliver := min(32, v.scroll.viewport.w, r.w)
	r.x = clamp(r.x, v.scroll.viewport.x - r.w + sliver, v.scroll.viewport.x + v.scroll.viewport.w - sliver)
	return r
}

scroll_direction :: proc(
	m: ^Manager,
	s: ^Space,
	w: ^Window,
	direction: string,
) -> ^Window {
	n := find(s.view.root, w.id)
	if n == nil {
		return nil
	}
	if n.column_tabbed && s.view.tab_indicator_top {
		if direction == "east" || direction == "west" {
			for i in 0 ..< n.count {
				if n.windows[i] == w.id {
					j := direction == "east" ? i + 1 : i - 1
					if j >= 0 && j < n.count { return m.windows[n.windows[j]] }
					break
				}
			}
		} else {
			return nil
		}
	}
	if direction == "east" || direction == "west" {
		target := direction == "east" ? next(n) : previous(n)
		if target != nil && target.count > 0 {
			return m.windows[target.order[0]]
		}
		return nil
	}
	for i in 0 ..< n.count {
		if n.windows[i] != w.id {
			continue
		}
		j := direction == "south" ? i + 1 : i - 1
		if j >= 0 && j < n.count {
			return m.windows[n.windows[j]]
		}
	}
	return nil
}

scroll_set_width :: proc(v: ^View, window: u32, operand: string) -> string {
	n := find(v.root, window)
	if n == nil {
		return "window is not in a scrolling column"
	}
	parts := strings.split(operand, ":", context.temp_allocator)
	if len(parts) != 2 {
		return "column-width expects abs:pixels, rel:pixels, or ratio:fraction"
	}
	value, ok := strconv.parse_f64(parts[1])
	if !ok || math.is_nan(value) || math.is_inf(value) {
		return "invalid column width"
	}
	switch parts[0] {
	case "abs":
	case "rel":
		value += n.column_width
	case "ratio":
		size, valid := scroll_parse_size(operand)
		if !valid {
			return "invalid proportional column width"
		}
		n.column_size = size; n.column_preset = nil; n.column_full = false
		n.column_revision += 1
		v.scroll.reveal = true; return ""
	case:
		return "column-width expects abs, rel, or ratio"
	}
	if value <= 0 || value > 100000 {
		return "column width must be positive and at most 100000"
	}
	n.column_size = {.Fixed, value}
	n.column_revision += 1
	n.column_preset = nil
	n.column_full = false
	v.scroll.reveal = true
	return ""
}

// Column and row sizing
// ------------------------------------------------------------------------

Scroll_Size :: struct {
	kind: enum {
		Default,
		Fixed,
		Proportion,
	},
	value: f64,
}
Scroll_Options :: struct {
	center: enum {
		Never,
		Always,
		On_Overflow,
	},
	center_single: bool,
	default_tabbed: bool,
	warp_pointer: bool,
	default_width: Scroll_Size,
	presets: [16]Scroll_Size,
	preset_count: int,
	height_presets: [16]Scroll_Size,
	height_preset_count: int,
}
scroll_options_defaults :: proc() -> Scroll_Options {
	o := Scroll_Options {
		default_width = {.Proportion, 0.5},
		preset_count  = 3,
	}
	o.presets[0] = {.Proportion, 1.0 / 3}
	o.presets[1] = {.Proportion, 0.5}
	o.presets[2] = {.Proportion, 2.0 / 3}
	o.height_presets = o.presets
	o.height_preset_count = o.preset_count
	return o
}
scroll_size_value :: proc(v: ^View, size: Scroll_Size) -> f64 {
	if size.kind == .Proportion {
		return max(
			1,
			(v.scroll.viewport.w - scroll_gap(v)) * size.value - scroll_gap(v),
		)
	}
	return max(1, size.value)
}
scroll_parse_size :: proc(text: string) -> (Scroll_Size, bool) {
	p := strings.split(text, ":", context.temp_allocator)
	if len(p) != 2 {
		return {}, false
	}
	n, ok := strconv.parse_f64(p[1])
	if !ok || math.is_nan(n) || math.is_inf(n) || n <= 0 || n > 100000 {
		return {}, false
	}
	if p[0] == "abs" {
		return {.Fixed, n}, true
	}
	if p[0] == "ratio" && n <= 100 {
		return {.Proportion, n}, true
	}
	return {}, false
}
scroll_size_text :: proc(size: Scroll_Size) -> string {
	return fmt.tprintf(
		"%s:%g",
		size.kind == .Proportion ? "ratio" : "abs",
		size.value,
	)
}

scroll_config :: proc(
	m: ^Manager,
	s: ^Space,
	name, value: string,
	setting: bool,
) -> Response {
	o := s != nil ? s.view.scroll_options : m.scroll_options
	switch name {
	case "scroll_default_column_display":
		if !setting { return success(o.default_tabbed ? "tabbed" : "normal") }
		if value != "normal" && value != "tabbed" {
			return failure("scroll_default_column_display expects normal or tabbed")
		}
		o.default_tabbed = value == "tabbed"
	case "scroll_center_focused_column":
		names := [3]string{"never", "always", "on-overflow"}
		if !setting {
			return success(names[int(o.center)])
		}
		valid := false
		for x, i in names {
			if value == x {
				o.center = type_of(o.center)(i); valid = true
			}
		}
		if !valid {
			return failure(
				"scroll_center_focused_column expects never, always, or on-overflow",
			)
		}
	case "scroll_center_single_column", "scroll_warp_pointer":
		flag := name == "scroll_warp_pointer" ? &o.warp_pointer : &o.center_single
		if !setting {
			return success(flag^ ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_center_single_column expects on or off")
		}
		flag^ = value == "on"
	case "scroll_default_column_width":
		if !setting {
			return success(scroll_size_text(o.default_width))
		}
		size, ok := scroll_parse_size(value)
		if !ok {
			return failure("expected positive abs:pixels or ratio:fraction")
		}
		o.default_width = size
	case "scroll_width_presets", "scroll_height_presets":
		presets :=
			name == "scroll_width_presets" ? &o.presets : &o.height_presets
		count :=
			name == "scroll_width_presets" \
				? &o.preset_count \
				: &o.height_preset_count
		if !setting {
			parts := make([]string, count^, context.temp_allocator)
			for i in 0 ..< count^ { parts[i] = scroll_size_text(presets[i]) }
			return success(strings.join(parts, ",", context.temp_allocator))
		}
		parts := strings.split(value, ",", context.temp_allocator)
		if len(parts) == 0 || len(parts) > len(o.presets) {
			return failure("expected 1 to 16 size presets")
		}
		for x, i in parts {
			size, ok := scroll_parse_size(x)
			if !ok {
				return failure(
					"size presets expect comma-separated abs:pixels or ratio:fraction",
				)
			}
			presets[i] = size
		}
		count^ = len(parts)
	}
	if s != nil {
		s.view.scroll_options = o
		if name == "scroll_width_presets" {
			for n := first(s.view.root);
			    n != nil;
			    n = next(n) { n.column_preset = nil }
		}
		if name == "scroll_height_presets" {
			for _, w in m.windows {
				if w.space == s.id {
					w.row_preset = nil
				}
			}
		}
		mark_space_override(s, name)
		s.view.scroll.reveal = true
		return result(flush(m, s))
	}
	m.scroll_options = o
	for space in m.spaces {
		if space.overrides[name] {
			continue
		}
		// Copy only the changed option so unrelated per-Space settings survive.
		switch name {
		case "scroll_default_column_display":
			space.view.scroll_options.default_tabbed = o.default_tabbed
		case "scroll_center_focused_column":
			space.view.scroll_options.center = o.center
		case "scroll_center_single_column":
			space.view.scroll_options.center_single = o.center_single
		case "scroll_warp_pointer":
			space.view.scroll_options.warp_pointer = o.warp_pointer
		case "scroll_default_column_width":
			space.view.scroll_options.default_width = o.default_width
		case "scroll_width_presets":
			space.view.scroll_options.presets = o.presets
			space.view.scroll_options.preset_count = o.preset_count
		case "scroll_height_presets":
			space.view.scroll_options.height_presets = o.height_presets
			space.view.scroll_options.height_preset_count =
				o.height_preset_count
		}
		if name == "scroll_width_presets" {
			for n := first(space.view.root);
			    n != nil;
			    n = next(n) { n.column_preset = nil }
		}
		if name == "scroll_height_presets" {
			for _, w in m.windows {
				if w.space == space.id {
					w.row_preset = nil
				}
			}
		}
		space.view.scroll.reveal = true
		if space.visible {
			if err := flush(m, space); err != "" {
				return failure(err)
			}
		}
	}
	return success()
}

scroll_cycle_width :: proc(v: ^View, n: ^Node, reverse: bool) {
	count := v.scroll_options.preset_count
	index := reverse ? count - 1 : 0
	if old, ok := n.column_preset.?; ok && old < count {
		index = (old + (reverse ? count - 1 : 1)) % count
	} else {
		for step in 0 ..< count {
			i := reverse ? count - 1 - step : step
			width := scroll_size_value(v, v.scroll_options.presets[i])
			if reverse \
				   ? width + 1 < n.column_width \
				   : n.column_width + 1 < width {
				index = i; break
			}
		}
	}
	n.column_size = v.scroll_options.presets[index]
	n.column_revision += 1
	n.column_preset = index
	n.column_full = false
	v.scroll.reveal = true
}

scroll_constraints :: proc(m: ^Manager, v: ^View) {
	for n := first(v.root); n != nil; n = next(n) {
		n.column_min, n.column_max = 1, 100000
		for i in 0 ..< n.count {
			if w := m.windows[n.windows[i]]; w != nil {
				n.column_min = max(n.column_min, max(w.min_width, w.opening.minimum.w))
				if w.max_width > 0 {
					n.column_max = min(n.column_max, w.max_width)
				}
			}
		}
		gutter := v.tab_indicator_top ? f64(0) : tab_indicator_gutter(v, n)
		n.column_min += gutter
		if n.column_max < 100000 { n.column_max += gutter }
		n.column_max = max(n.column_min, n.column_max)
	}
}

// Allocate fixed rows first, then water-fill automatic rows around their
// minimums. Round cumulative edges, rather than each height independently.
scroll_rows :: proc(m: ^Manager, v: ^View, use_feedback: bool = false) {
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		gap := min(scroll_gap(v), max(0, n.frame.h / f64(n.count)))
		remaining := max(1, n.frame.h - gap * f64(n.count - 1))
		pending: [MAX_STACK]bool
		weights: [MAX_STACK]f64
		minima: [MAX_STACK]f64
		weight_sum: f64
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			minima[i] = max(1, max(w.min_height, w.opening.minimum.h))
			if use_feedback && w.size_feedback.height_valid && !n.column_tabbed && n.zoom == nil {
				n.row_heights[i] = w.size_feedback.accepted.h
				remaining -= n.row_heights[i]
			} else if w.row_fixed > 0 {
				other_min: f64
				for j in 0 ..< n.count {
					if j != i {
						if other := m.windows[n.windows[j]]; other != nil {
							other_min += max(1, other.min_height)
						}
					}
				}
				height := clamp(
					w.row_fixed,
					minima[i],
					max(minima[i], remaining - other_min),
				)
				if w.max_height > 0 {
					height = max(minima[i], min(height, w.max_height))
				}
				n.row_heights[i] = height
				remaining -= height
			} else {
				weights[i] = w.row_weight > 0 ? w.row_weight : 1
				pending[i] = true
				weight_sum += weights[i]
			}
		}
		for _ in 0 ..< n.count {
			changed := false
			for i in 0 ..< n.count {
				if pending[i] &&
				   weight_sum > 0 &&
				   remaining * weights[i] / weight_sum < minima[i] {
					n.row_heights[i] = minima[i]
					remaining -= minima[i]; weight_sum -= weights[i]
					pending[i] = false; changed = true
				}
			}
			if !changed {
				break
			}
		}
		for i in 0 ..< n.count {
			if pending[i] {
				n.row_heights[i] = max(
					minima[i],
					weight_sum > 0 \
						? remaining * weights[i] / weight_sum \
						: minima[i],
				)
			}
		}
		position: f64
		for i in 0 ..< n.count {
			next_position := position + n.row_heights[i]
			n.row_heights[i] = max(
				1,
				math.round(next_position) - math.round(position),
			)
			position = next_position
		}
		if n.count == 1 {
			if w := m.windows[n.windows[0]]; w != nil && w.row_fixed == 0 {
				w.row_weight = 1
			}
		}
	}
}

scroll_set_row :: proc(
	m: ^Manager,
	v: ^View,
	w: ^Window,
	operand: string,
) -> string {
	n := find(v.root, w.id)
	if n == nil {
		return "window is not in a scrolling column"
	}
	if operand == "auto" {
		w.row_revision += 1
		w.row_fixed, w.row_weight = 0, 1; w.row_preset = nil; return ""
	}
	parts := strings.split(operand, ":", context.temp_allocator)
	if len(parts) != 2 {
		return(
			"row-height expects auto, abs:pixels, rel:pixels, ratio:fraction, or weight:value" \
		)
	}
	value, ok := strconv.parse_f64(parts[1])
	if !ok || math.is_nan(value) || math.is_inf(value) {
		return "invalid row height"
	}
	switch parts[0] {
	case "weight":
		if value <= 0 || value > 100000 {
			return "row weight must be positive and at most 100000"
		}
		w.row_revision += 1
		w.row_fixed, w.row_weight = 0, value; w.row_preset = nil; return ""
	case "abs":
	case "rel":
		value += w.frame.h
	case "ratio":
		value = max(
			1,
			(v.scroll.viewport.h - scroll_gap(v)) * value - scroll_gap(v),
		)
	case:
		return "invalid row height mode"
	}
	if value <= 0 || value > 100000 {
		return "row height must be positive and at most 100000"
	}
	// Only one fixed row per column; previous fixed rows become automatic,
	// retaining their apparent height as a weight relative to other auto rows.
	unit_height := f64(1)
	for i in 0 ..< n.count {
		if other := m.windows[n.windows[i]];
		   other != nil && other.row_fixed == 0 {
			unit_height =
				max(1, other.frame.h) /
				(other.row_weight > 0 ? other.row_weight : 1)
			break
		}
	}
	for i in 0 ..< n.count {
		if other := m.windows[n.windows[i]];
		   other != nil && other.id != w.id && other.row_fixed > 0 {
			other.row_weight = max(1, other.frame.h) / unit_height
			other.row_fixed = 0
			other.row_preset = nil
		}
	}
	w.row_fixed = value
	w.row_revision += 1
	w.row_preset = nil
	return ""
}

scroll_cycle_height :: proc(
	m: ^Manager,
	v: ^View,
	w: ^Window,
	reverse: bool,
) -> string {
	count := v.scroll_options.height_preset_count
	index := reverse ? count - 1 : 0
	if old, ok := w.row_preset.?; ok && old < count {
		index = (old + (reverse ? count - 1 : 1)) % count
	} else {
		for step in 0 ..< count {
			i := reverse ? count - 1 - step : step
			size := v.scroll_options.height_presets[i]
			height :=
				size.kind == .Proportion \
					? max(
						1,
						(v.scroll.viewport.h - scroll_gap(v)) * size.value -
						scroll_gap(v),
					) \
					: size.value
			if reverse ? height + 1 < w.frame.h : w.frame.h + 1 < height {
				index = i; break
			}
		}
	}
	size := v.scroll_options.height_presets[index]
	if err := scroll_set_row(m, v, w, scroll_size_text(size)); err != "" {
		return err
	}
	w.row_preset = index
	return ""
}

// Column transfers
// ------------------------------------------------------------------------

scroll_append_row :: proc(n: ^Node, id: u32) {
	// Consume appends after the last row, independently of the active row.
	n.windows[n.count] = id
	n.order[n.count] = id
	n.count += 1
}

scroll_transfer :: proc(
	m: ^Manager,
	s: ^Space,
	w: ^Window,
	operation, direction: string,
) -> string {
	v := &s.view
	n := find(v.root, w.id)
	if n == nil {
		return "window is not in a scrolling column"
	}
	west := direction == "west"
	if operation == "--consume" ||
	   (operation == "--consume-or-expel" && n.count == 1) {
		donor, destination := next(n), n
		moved := u32(0)
		if operation == "--consume" {
			if donor == nil {
				return ""
			}
			moved = donor.windows[0]
		} else {
			destination = west ? previous(n) : next(n)
			if destination == nil {
				return ""
			}
			donor = n
			moved = w.id
		}
		if destination.count == MAX_STACK {
			return "target column is full"
		}
		anchor := destination.windows[0]
		remove(v, moved)
		destination = find(v.root, anchor)
		scroll_append_row(destination, moved)
		if m.focused == moved {
			focus_order(destination, moved)
		}
	} else {
		if n.count <= 1 {
			return ""
		}
		moved := operation == "--expel" ? n.windows[n.count - 1] : w.id
		anchor := n.windows[0] == moved ? n.windows[1] : n.windows[0]
		if operation == "--expel" && m.focused == moved {
			fallback := n.windows[n.count - 2]
			if err := perform(m, {kind = .Focus, window = fallback});
			   err != "" {
				return err
			}
			focus_window(m, fallback)
		}
		size, width, full := n.column_size, n.column_width, n.column_full
		remove(v, moved)
		source := find(v.root, anchor)
		source.insert_first = operation == "--consume-or-expel" && west
		source.insert_stack = false
		add(v, moved, anchor)
		placed := find(v.root, moved)
		placed.column_size, placed.column_full = size, full
		placed.column_width, placed.column_resolved = width, width
	}
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.reveal = true
	return flush(m, s)
}

scroll_move_column :: proc(v: ^View, n: ^Node, west: bool) {
	other := west ? previous(n) : next(n)
	if other == nil {
		return
	}
	swap(n, other)
	n.column_size, other.column_size = other.column_size, n.column_size
	n.column_width, other.column_width = other.column_width, n.column_width
	n.column_resolved, other.column_resolved =
		other.column_resolved, n.column_resolved
	n.column_preset, other.column_preset = other.column_preset, n.column_preset
	n.column_revision, other.column_revision = other.column_revision, n.column_revision
	n.column_full, other.column_full = other.column_full, n.column_full
	n.column_tabbed, other.column_tabbed = other.column_tabbed, n.column_tabbed
	n.column_raised, other.column_raised = 0, 0
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.reveal = true
}
