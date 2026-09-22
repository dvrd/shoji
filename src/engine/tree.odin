package engine

import "core:math"

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
	frame: Rect,
	windows, order: [MAX_STACK]u32,
	count: int,
	ratio: f64,
	split: Split,
	insert_first: Maybe(bool),
	insert_stack: bool,
}

View :: struct {
	root: ^Node,
	layout: Layout,
	frame: Rect,
	padding: Padding,
	gap, ratio: f64,
	split: Split,
	padding_enabled, gap_enabled, first_child, auto_balance: bool,
	insertion: u32,
}

view_init :: proc(v: ^View, frame: Rect, layout: Layout = .BSP) {
	v^ = View {
		root            = new(Node),
		frame           = frame,
		layout          = layout,
		ratio           = 0.5,
		padding_enabled = true,
		gap_enabled     = true,
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
	n.left.frame, n.right.frame = partition(n.frame, n.split, n.ratio, gap)
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

add :: proc(v: ^View, id: u32, insertion: u32 = 0) -> bool {
	if id == 0 || find(v.root, id) != nil || v.layout == .Float {
		return false
	}
	n := find(v.root, insertion)
	if n == nil {
		n = find(v.root, v.insertion)
	}
	if n == nil {
		n = minimum_depth(v.root)
	}
	if n.count == 0 || v.layout == .Stack || n.insert_stack {
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
	}
	fresh^ = Node {
		parent = n,
		count  = 1,
	}
	fresh.windows[0] = id
	fresh.order[0] = id
	n.left, n.right = old, fresh
	if n.insert_first.? or_else v.first_child {
		n.left, n.right = fresh, old
	}
	n.insert_first = nil
	n.count = 0
	n.zoom = nil
	if v.auto_balance {
		balance(v.root)
	}
	view_update(v)
	v.insertion = 0
	return true
}

remove :: proc(v: ^View, id: u32) -> bool {
	n := find(v.root, id)
	if n == nil {
		return false
	}
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
		balance(v.root)
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
