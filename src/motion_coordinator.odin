package shoji


// The owner serializes access. The coordinator stores no native references and
// cannot cancel an AX call already in progress; callers must reconcile its
// completion against the generation returned by motion_complete.
Motion_Target :: struct {window: u32, space: u64, generation: u64}
Motion_Request_Kind :: enum {Position, Focus}
Motion_Request :: struct {kind: Motion_Request_Kind, target: Motion_Target, frame: Rect, revision: u64}
Motion_Entry :: struct {target: Motion_Target, frame: Rect, revision: u64, pending: bool}
Motion_Coordinator :: struct {
	entries: map[u32]Motion_Entry,
	next_generation, next_revision: u64,
	focus: Motion_Request,
	focus_pending, in_flight, stopping: bool,
	active: Motion_Request,
}

motion_coordinator_destroy :: proc(q: ^Motion_Coordinator) {delete(q.entries); q^ = {}}
motion_coordinator_stop :: proc(q: ^Motion_Coordinator) {
	q.stopping = true
	q.focus_pending = false
	for _, &entry in q.entries {entry.pending = false}
}
motion_coordinator_idle :: proc(q: ^Motion_Coordinator) -> bool {return !q.in_flight}
motion_register :: proc(q: ^Motion_Coordinator, window: u32, space: u64) -> Motion_Target {
	if q.stopping {return {}}
	if q.entries == nil {q.entries = make(map[u32]Motion_Entry)}
	if q.focus_pending && q.focus.target.window == window {q.focus_pending = false}
	q.next_generation += 1
	target := Motion_Target{window, space, q.next_generation}
	q.entries[window] = {target = target}
	return target
}
motion_matches :: proc(q: ^Motion_Coordinator, target: Motion_Target) -> bool {
	entry, found := q.entries[target.window]
	return found && entry.target == target
}
motion_unregister :: proc(q: ^Motion_Coordinator, target: Motion_Target) {
	if !motion_matches(q, target) {return}
	delete_key(&q.entries, target.window)
	if q.focus_pending && q.focus.target == target {q.focus_pending = false}
}
motion_invalidate_space :: proc(q: ^Motion_Coordinator, space: u64) {
	ids: [dynamic]u32; defer delete(ids)
	for id, entry in q.entries {if entry.target.space == space {append(&ids, id)}}
	for id in ids {delete_key(&q.entries, id)}
	if q.focus_pending && q.focus.target.space == space {q.focus_pending = false}
}
motion_queue_position :: proc(q: ^Motion_Coordinator, target: Motion_Target, frame: Rect) -> bool {
	if q.stopping || !motion_matches(q, target) {return false}
	q.next_revision += 1
	entry := q.entries[target.window]
	entry.frame, entry.revision, entry.pending = frame, q.next_revision, true
	q.entries[target.window] = entry
	return true
}
motion_queue_focus :: proc(q: ^Motion_Coordinator, target: Motion_Target) -> bool {
	if q.stopping || !motion_matches(q, target) {return false}
	q.next_revision += 1
	q.focus = {kind = .Focus, target = target, revision = q.next_revision}
	q.focus_pending = true
	return true
}
motion_take :: proc(q: ^Motion_Coordinator) -> (Motion_Request, bool) {
	if q.stopping || q.in_flight {return {}, false}
	job: Motion_Request
	if q.focus_pending {
		job = q.focus; q.focus_pending = false
	} else {
		found := false
		selected: u32
		for id, value in q.entries {
			if value.pending && (!found || value.revision < job.revision) {
				job = {kind = .Position, target = value.target, frame = value.frame, revision = value.revision}
				selected, found = id, true
			}
		}
		if !found {return {}, false}
		entry := q.entries[selected]; entry.pending = false; q.entries[selected] = entry
	}
	q.active, q.in_flight = job, true
	return job, true
}
motion_request_current :: proc(q: ^Motion_Coordinator, job: Motion_Request) -> bool {
	if q.stopping || !q.in_flight || q.active != job || !motion_matches(q, job.target) {return false}
	if job.kind == .Focus {return q.focus.revision == job.revision}
	return q.entries[job.target.window].revision == job.revision
}
motion_complete :: proc(q: ^Motion_Coordinator, job: Motion_Request, success: bool) -> bool {
	current := motion_request_current(q, job)
	if q.in_flight && q.active == job {q.in_flight = false}
	return success && current
}
