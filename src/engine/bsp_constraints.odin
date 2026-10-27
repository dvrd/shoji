package engine

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
