package experimental

import "base:intrinsics"

foreign import system "system:System"

@(default_calling_convention = "c")
foreign system {
	@(link_name = "task_threads") barrier_task_threads :: proc(task: u32, threads: ^[^]u32, count: ^u32) -> i32 ---
	@(link_name = "thread_info") barrier_thread_info :: proc(thread, flavor: u32, info: rawptr, count: ^u32) -> i32 ---
	@(link_name = "thread_get_state") barrier_thread_get_state :: proc(thread, flavor: u32, state: rawptr, count: ^u32) -> i32 ---
	@(link_name = "thread_suspend") barrier_thread_suspend :: proc(thread: u32) -> i32 ---
	@(link_name = "thread_resume") barrier_thread_resume :: proc(thread: u32) -> i32 ---
	@(link_name = "mach_thread_self") barrier_mach_thread_self :: proc() -> u32 ---
	@(link_name = "mach_port_deallocate") barrier_mach_port_deallocate :: proc(task, name: u32) -> i32 ---
	@(link_name = "usleep") barrier_usleep :: proc(microseconds: u32) -> i32 ---
}

BARRIER_MAX_THREADS :: 256
barrier_last_run_state, barrier_last_suspend_count: i32
barrier_last_count: u32
barrier_last_failure: u32
barrier_last_pc, barrier_nearest_pc: u64
Barrier_Thread_Info :: struct {
	id, handle, queue: u64,
}
Barrier_ARM_State :: struct {
	x: [29]u64,
	fp, lr, sp, pc: u64,
	cpsr, flags: u32,
}
Barrier_Basic_Info :: struct {
	user_seconds, user_microseconds, system_seconds, system_microseconds: i32,
	cpu_usage, policy, run_state, flags, suspend_count, sleep_time: i32,
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

barrier_thread_stopped :: proc(thread: u32) -> bool {
	info: Barrier_Basic_Info
	count := u32(size_of(info) / 4)
	if barrier_thread_info(thread, 3, &info, &count) == 0 && count == size_of(info) / 4 {
		barrier_last_run_state = info.run_state
		barrier_last_suspend_count = info.suspend_count
		return barrier_run_state_parked(info.run_state, info.suspend_count)
	}
	return false
}

// Mach thread run states (mach/thread_info.h).
TH_STATE_RUNNING :: 1
TH_STATE_STOPPED :: 2
TH_STATE_WAITING :: 3
TH_STATE_UNINTERRUPTIBLE :: 4
TH_STATE_HALTED :: 5

// A suspended thread is parked once it is off-core: stopped, or blocked in
// the kernel. Blocked threads check their suspension before returning to
// user space, so they cannot execute user code until resumed. Uninterruptible
// waits must count: WindowServer keeps a thread in one (GPU/IOKit) for long
// periods, and requiring STOPPED made every barrier attempt fail (status 5,
// failure 8). Only RUNNING may still be executing user instructions.
barrier_run_state_parked :: proc "contextless" (run_state, suspend_count: i32) -> bool {
	if suspend_count <= 0 {return false}
	switch run_state {
	case TH_STATE_STOPPED, TH_STATE_WAITING, TH_STATE_UNINTERRUPTIBLE, TH_STATE_HALTED:
		return true
	}
	return false
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

pc_in_range :: proc(pc, start, size: u64) -> bool {
	if size == 0 || start > max(u64) - size {return true}
	masked := pc & 0x0000ffffffffffff
	return (pc >= start && pc - start < size) || (masked >= start && masked - start < size)
}

barrier_has_pc_in_range :: proc(state: ^Execution_Barrier, start, size: u64) -> (inside, checked: bool) {
	if state == nil || !state.active || state.count == 0 || state.count > BARRIER_MAX_THREADS {return true, false}
	barrier_nearest_pc = max(u64)
	for index in 0 ..< state.count {
		if !state.suspended[index] {continue}
		thread_state: Barrier_ARM_State
		count := u32(size_of(thread_state) / 4)
		if barrier_thread_get_state(state.threads[index], 6, &thread_state, &count) != 0 ||
		   count != size_of(thread_state) / 4 {return true, false}
		pc := thread_state.pc & 0x0000ffffffffffff
		barrier_last_pc = pc
		distance := pc >= start ? pc - start : start - pc
		if distance < barrier_nearest_pc {barrier_nearest_pc = distance}
		if pc_in_range(thread_state.pc, start, size) {return true, true}
	}
	return false, true
}

enter_execution_barrier_avoiding :: proc(state: ^Execution_Barrier, deallocate: Deallocate, start, size: u64, attempts: int) -> bool {
	if state == nil || attempts <= 0 {return false}
	for _ in 0 ..< attempts {
		if !enter_execution_barrier(state, deallocate) {return false}
		inside, checked := barrier_has_pc_in_range(state, start, size)
		if checked && !inside {
			for _ in 0 ..< 10_000 {intrinsics.cpu_relax()}
			inside, checked = barrier_has_pc_in_range(state, start, size)
			if checked && !inside {return true}
		}
		if !leave_execution_barrier(state) {return false}
	}
	return false
}

enter_execution_barrier :: proc(state: ^Execution_Barrier, deallocate: Deallocate) -> bool {
	if state == nil || state.active || deallocate == nil {return false}
	state^ = {}
	barrier_last_count = 0
	barrier_last_failure = 0
	self := hook_mach_task_self()
	current := barrier_mach_thread_self()
	if current == 0 {barrier_last_failure = 1; return false}
	current_id, current_ok := barrier_thread_id(current)
	port_code := barrier_mach_port_deallocate(self, current)
	if !current_ok || port_code != 0 {barrier_last_failure = 2; return false}

	threads: [^]u32
	count: u32
	if barrier_task_threads(self, &threads, &count) != 0 {barrier_last_failure = 3; return false}
	barrier_last_count = count
	state.task, state.threads, state.count, state.active = self, threads, count, true
	state.deallocate = deallocate
	if count == 0 || count > BARRIER_MAX_THREADS {
		for index in 0 ..< count {barrier_mach_port_deallocate(self, threads[index])}
		deallocate(self, u64(uintptr(threads)), u64(count) * size_of(u32))
		state^ = {}
		barrier_last_failure = 4
		return false
	}
	current_matches := 0
	for index in 0 ..< count {
		id, ok := barrier_thread_id(threads[index])
		if !ok {
			barrier_last_failure = 5
			leave_execution_barrier(state)
			return false
		}
		state.ids[index] = id
		if id == current_id {current_matches += 1}
	}
	if current_matches != 1 {
		barrier_last_failure = 6
		leave_execution_barrier(state)
		return false
	}
	for index in 0 ..< count {
		if state.ids[index] == current_id {continue}
		if barrier_thread_suspend(threads[index]) != 0 {
			barrier_last_failure = 7
			leave_execution_barrier(state)
			return false
		}
		state.suspended[index] = true
		stopped := false
		for _ in 0 ..< 200 {
			if barrier_thread_stopped(threads[index]) {stopped = true; break}
			barrier_usleep(100)
		}
		if !stopped {
			barrier_last_failure = 8
			leave_execution_barrier(state)
			return false
		}
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
		barrier_last_failure = 9
		leave_execution_barrier(state)
		return false
	}
	return true
}
