package engine

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
