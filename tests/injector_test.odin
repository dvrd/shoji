package tests

import "base:intrinsics"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"
import inject "../src/inject"

bootstrap_failed_open :: proc "c" (path: cstring, mode: i32) -> rawptr {
	return nil
}
bootstrap_failed_reason :: proc "c" () -> cstring {
	return "test load rejected"
}

@(test)
loader_failure_waits_for_acknowledgment_before_final_data_access :: proc(
	t: ^testing.T,
) {
	data := inject.Bootstrap {
		open  = bootstrap_failed_open,
		error = bootstrap_failed_reason,
	}
	thread: posix.pthread_t
	if !testing.expect(
		t,
		posix.pthread_create(&thread, nil, inject.remote_worker, &data) == nil,
	) {
		return
	}
	defer {
		intrinsics.atomic_store_explicit(&data.seen, 1, .Release)
		posix.pthread_join(thread)
	}
	deadline := time.time_add(time.now(), time.Second)
	for intrinsics.atomic_load_explicit(&data.done, .Acquire) == 0 &&
	    time.diff(time.now(), deadline) > 0 {
		time.sleep(time.Millisecond)
	}
	testing.expect_value(
		t,
		intrinsics.atomic_load_explicit(&data.done, .Acquire),
		u32(1),
	)
	testing.expect_value(
		t,
		intrinsics.atomic_load_explicit(&data.worker_finished, .Acquire),
		u32(0),
	)
	testing.expect_value(t, string(data.reason), "test load rejected")
	intrinsics.atomic_store_explicit(&data.seen, 1, .Release)
	deadline = time.time_add(time.now(), time.Second)
	for intrinsics.atomic_load_explicit(&data.worker_finished, .Acquire) ==
		    0 &&
	    time.diff(time.now(), deadline) > 0 {
		time.sleep(time.Millisecond)
	}
	testing.expect_value(
		t,
		intrinsics.atomic_load_explicit(&data.worker_finished, .Acquire),
		u32(1),
	)
}

@(test)
injector_reclaims_failed_load_data_after_worker_finishes :: proc(
	t: ^testing.T,
) {
	// Exercise the real remote-thread and dlerror handshake against this process only.
	for _ in 0 ..< 8 {
		err := inject.inject_task(
			inject.mach_task_self(),
			"/nonexistent/shoji-missing-p1-test.dylib",
		)
		testing.expect(t, strings.contains(err, "shoji-missing-p1-test"), err)
	}
}
