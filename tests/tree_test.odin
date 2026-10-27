package tests

import e "../src/engine"
import "core:testing"

assert_tree :: proc(t: ^testing.T, n: ^e.Node, parent: ^e.Node, seen: ^map[u32]bool) -> int {
	testing.expect(t, n != nil)
	if n == nil {
		return 0
	}
	testing.expect(t, n.parent == parent)
	testing.expect(t, n.frame.w >= 0 && n.frame.h >= 0)
	if e.leaf(n) {
		testing.expect(t, n.count >= 0 && n.count <= e.MAX_STACK)
		for i in 0 ..< n.count {
			id := n.windows[i]
			testing.expect(t, id != 0 && !seen^[id])
			seen^[id] = true
			in_order := false
			for j in 0 ..< n.count {
				if n.order[j] == id {
					in_order = true
				}
			}
			testing.expect(t, in_order)
		}
		return n.count
	}
	testing.expect(t, n.count == 0 && n.left != nil && n.right != nil)
	return assert_tree(t, n.left, n, seen) + assert_tree(t, n.right, n, seen)
}
@(test)
partition_matches_upstream_rounding :: proc(t: ^testing.T) {
	a, b := e.partition({10, 20, 1001, 601}, .Vertical, 0.5, 8)
	testing.expect_value(t, a, e.Rect{10, 20, 496, 601})
	testing.expect_value(t, b, e.Rect{515, 20, 496, 601})
	c, d := e.partition({0, 0, 800, 601}, .Horizontal, 0.3, 9)
	testing.expect_value(t, c.h, f64(177))
	testing.expect_value(t, d.h, f64(414))
	testing.expect_value(t, d.y, f64(187))
}
@(test)
insert_remove_preserves_parent_links :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 1920, 1080})
	defer e.view_destroy(&v)
	for id: u32 = 1; id <= 80; id += 1 {
		testing.expect(t, e.add(&v, id))
	}
	testing.expect(t, !e.add(&v, 7))
	testing.expect(t, !e.add(&v, 0))
	seen := make(map[u32]bool)
	defer delete(seen)
	testing.expect_value(t, assert_tree(t, v.root, nil, &seen), 80)
	for id: u32 = 2; id <= 80; id += 2 {
		testing.expect(t, e.remove(&v, id))
	}
	clear(&seen)
	testing.expect_value(t, assert_tree(t, v.root, nil, &seen), 40)
	for id: u32 = 1; id <= 80; id += 2 {
		testing.expect(t, e.remove(&v, id))
	}
	testing.expect(t, e.leaf(v.root) && v.root.count == 0)
	testing.expect(t, !e.remove(&v, 1))
}
@(test)
stack_limit_and_mru_order :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 100, 100}, .Stack)
	defer e.view_destroy(&v)
	for id: u32 = 1; id <= e.MAX_STACK; id += 1 {
		testing.expect(t, e.add(&v, id))
	}
	testing.expect(t, !e.add(&v, 33))
	testing.expect(t, e.leaf(v.root))
	e.focus_order(v.root, 7)
	testing.expect_value(t, v.root.order[0], u32(7))
	testing.expect(t, e.remove(&v, 7))
	testing.expect_value(t, v.root.count, 31)
	testing.expect(t, e.add(&v, 33))
	testing.expect_value(t, v.root.order[0], u32(33))
	seen := make(map[u32]bool)
	defer delete(seen)
	assert_tree(t, v.root, nil, &seen)
}
@(test)
rotation_and_mirror_are_reversible :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 1200, 800})
	defer e.view_destroy(&v)
	e.add(&v, 1)
	e.add(&v, 2)
	e.add(&v, 3)
	e.add(&v, 4)
	before: [4]e.Rect
	for i in 0 ..< 4 {
		before[i] = e.find(v.root, u32(i + 1)).frame
	}
	for _ in 0 ..< 4 {
		e.rotate(v.root, 90)
		e.view_update(&v)
	}
	for i in 0 ..< 4 {
		testing.expect_value(t, e.find(v.root, u32(i + 1)).frame, before[i])
	}
	e.mirror(v.root, .Vertical)
	e.mirror(v.root, .Vertical)
	e.view_update(&v)
	for i in 0 ..< 4 {
		testing.expect_value(t, e.find(v.root, u32(i + 1)).frame, before[i])
	}
}
@(test)
traversal_neighbors_and_padding :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 1000, 800})
	defer e.view_destroy(&v)
	v.padding = {10, 20, 30, 40}
	v.gap = 10
	e.add(&v, 1)
	e.add(&v, 2)
	e.view_update(&v)
	a, b := e.find(v.root, 1), e.find(v.root, 2)
	testing.expect_value(t, a.frame, e.Rect{30, 10, 460, 770})
	testing.expect_value(t, b.frame, e.Rect{500, 10, 460, 770})
	testing.expect(t, e.next(a) == b && e.previous(b) == a)
	testing.expect(t, e.next(b) == nil && e.previous(a) == nil)
	testing.expect(t, e.neighbor(v.root, a, .East) == b)
	testing.expect(t, e.neighbor(v.root, b, .West) == a)
	testing.expect(t, e.neighbor(v.root, a, .West) == nil)
}
@(test)
removing_zoom_target_clears_references :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 1000, 800})
	defer e.view_destroy(&v)
	e.add(&v, 1)
	e.add(&v, 2)
	e.add(&v, 3)
	n := e.find(v.root, 3)
	n.zoom = n.parent
	e.remove(&v, 2)
	n = e.find(v.root, 3)
	testing.expect(t, n.zoom == nil)
	seen := make(map[u32]bool)
	defer delete(seen)
	assert_tree(t, v.root, nil, &seen)
}
@(test)
randomized_tree_mutations :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 8192, 8192})
	defer e.view_destroy(&v)
	v.auto_balance = true
	active := make(map[u32]bool)
	defer delete(active)
	seen := make(map[u32]bool)
	defer delete(seen)
	rng: u32 = 4711
	for i in 0 ..< 1000 {
		rng = rng * 1664525 + 1013904223
		id := 1 + rng % 64
		if active[id] {
			testing.expect(t, e.remove(&v, id))
			delete_key(&active, id)
		} else {
			testing.expect(t, e.add(&v, id))
			active[id] = true
		}
		if i % 7 == 0 {
			e.rotate(v.root, 90)
		}
		if i % 11 == 0 {
			e.mirror(v.root, .Horizontal)
		}
		e.view_update(&v)
		clear(&seen)
		testing.expect_value(t, assert_tree(t, v.root, nil, &seen), len(active))
	}
}

@(test)
mirror_preserves_split_ratio :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 1000, 800})
	defer e.view_destroy(&v)
	e.add(&v, 1)
	e.add(&v, 2)
	v.root.ratio = 0.3
	e.mirror(v.root, .Vertical)
	e.view_update(&v)
	testing.expect_value(t, v.root.ratio, f64(0.3))
	testing.expect_value(t, e.find(v.root, 2).frame.w, f64(300))
}

@(test)
stack_inserts_after_most_recent_window :: proc(t: ^testing.T) {
	v: e.View
	e.view_init(&v, {0, 0, 1000, 800}, .Stack)
	defer e.view_destroy(&v)
	e.add(&v, 1)
	e.add(&v, 2)
	e.add(&v, 3)
	e.focus_order(v.root, 1)
	e.add(&v, 4)
	testing.expect_value(t, v.root.windows[0], u32(1))
	testing.expect_value(t, v.root.windows[1], u32(4))
	testing.expect_value(t, v.root.windows[2], u32(2))
	testing.expect_value(t, v.root.windows[3], u32(3))
}
