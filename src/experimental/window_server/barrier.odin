package experimental


foreign import system "system:System"

@(default_calling_convention = "c")
foreign system {
	@(link_name = "task_threads") barrier_task_threads :: proc(task: u32, threads: ^[^]u32, count: ^u32) -> i32 ---
	@(link_name = "thread_info") barrier_thread_info :: proc(thread, flavor: u32, info: rawptr, count: ^u32) -> i32 ---
	@(link_name = "thread_suspend") barrier_thread_suspend :: proc(thread: u32) -> i32 ---
	@(link_name = "thread_resume") barrier_thread_resume :: proc(thread: u32) -> i32 ---
	@(link_name = "mach_thread_self") barrier_mach_thread_self :: proc() -> u32 ---
	@(link_name = "mach_port_deallocate") barrier_mach_port_deallocate :: proc(task, name: u32) -> i32 ---
}

BARRIER_MAX_THREADS :: 128
Barrier_Thread_Info :: struct {
	id, handle, queue: u64,
}
Execution_Barrier :: struct {
	task: u32,
	threads: [^]u32,
	count: u32,
	ids: [BARRIER_MAX_THREADS]u64,
	suspended, released: [BARRIER_MAX_THREADS]bool,
	active: bool,
	deallocate: Deallocate,
}

barrier_thread_id :: proc(thread: u32) -> (id: u64, ok: bool) {
	info: Barrier_Thread_Info
	count := u32(size_of(info) / 4)
	if barrier_thread_info(thread, 4, &info, &count) != 0 || count != size_of(info) / 4 {
		return 0, false
	}
	return info.id, info.id != 0
}

leave_execution_barrier :: proc(state: ^Execution_Barrier) -> bool {
	if state == nil {return false}
	if !state.active {return true}
	success := true
	for index in 0 ..< state.count {
		if state.released[index] {continue}
		if state.suspended[index] {
			if barrier_thread_resume(state.threads[index]) != 0 {
				success = false
				continue
			}
			state.suspended[index] = false
		}
		if barrier_mach_port_deallocate(state.task, state.threads[index]) != 0 {
			success = false
			continue
		}
		state.released[index] = true
	}
	if !success {return false}
	address := u64(uintptr(state.threads))
	size := u64(state.count) * size_of(u32)
	if state.deallocate(state.task, address, size) != 0 {return false}
	state^ = {}
	return true
}

enter_execution_barrier :: proc(state: ^Execution_Barrier, deallocate: Deallocate) -> bool {
	if state == nil || state.active || deallocate == nil {return false}
	state^ = {}
	self := hook_mach_task_self()
	current := barrier_mach_thread_self()
	if current == 0 {return false}
	current_id, current_ok := barrier_thread_id(current)
	port_code := barrier_mach_port_deallocate(self, current)
	if !current_ok || port_code != 0 {return false}

	threads: [^]u32
	count: u32
	if barrier_task_threads(self, &threads, &count) != 0 {return false}
	state.task, state.threads, state.count, state.active = self, threads, count, true
	state.deallocate = deallocate
	if count == 0 || count > BARRIER_MAX_THREADS {
		for index in 0 ..< count {barrier_mach_port_deallocate(self, threads[index])}
		deallocate(self, u64(uintptr(threads)), u64(count) * size_of(u32))
		state^ = {}
		return false
	}
	current_matches := 0
	for index in 0 ..< count {
		id, ok := barrier_thread_id(threads[index])
		if !ok {
			leave_execution_barrier(state)
			return false
		}
		state.ids[index] = id
		if id == current_id {current_matches += 1}
	}
	if current_matches != 1 {
		leave_execution_barrier(state)
		return false
	}
	for index in 0 ..< count {
		if state.ids[index] == current_id {continue}
		if barrier_thread_suspend(threads[index]) != 0 {
			leave_execution_barrier(state)
			return false
		}
		state.suspended[index] = true
	}

	verification: [^]u32
	verification_count: u32
	valid := barrier_task_threads(self, &verification, &verification_count) == 0 &&
		verification_count == count
	if valid {
		for index in 0 ..< verification_count {
			id, ok := barrier_thread_id(verification[index])
			matches := 0
			if ok {
				for expected in state.ids[:count] {
					if expected == id {matches += 1}
				}
			}
			if matches != 1 {valid = false}
		}
	}
	if verification != nil {
		for index in 0 ..< verification_count {
			if barrier_mach_port_deallocate(self, verification[index]) != 0 {valid = false}
		}
		if deallocate(self, u64(uintptr(verification)), u64(verification_count) * size_of(u32)) != 0 {
			valid = false
		}
	}
	if !valid {
		leave_execution_barrier(state)
		return false
	}
	return true
}
