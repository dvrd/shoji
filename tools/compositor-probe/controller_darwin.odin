package main

import e "../../src/engine"
import mac "../../src/macos"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

Reader :: struct {
	data: [dynamic]u8,
}
next_observation :: proc(
	r: ^Reader,
	pipe: ^os.File,
) -> (
	o: Observation,
	received, failed: bool,
) {
	for {
		for ch, i in r.data {
			if ch == '\n' {
				err := json.unmarshal(r.data[:i], &o)
				copy(r.data[:], r.data[i + 1:])
				resize(&r.data, len(r.data) - i - 1)
				if err != nil {
					delete(o.event); delete(o.phase); o = {}
				}
				return o, err == nil, err != nil
			}
		}
		available, err := os.pipe_has_data(pipe)
		if err != nil {
			return {}, false, true
		}
		if !available {
			return
		}
		buf: [2048]u8
		n, read_err := os.read(pipe, buf[:])
		if read_err != nil || n == 0 || len(r.data) + n > 16384 {
			return {}, false, true
		}
		append(&r.data, ..buf[:n])
	}
}

run :: proc() -> int {
	executable, path_err := os.get_executable_path(context.allocator)
	if path_err != nil {
		fmt.eprintln("Cannot resolve diagnostic executable:", path_err)
		return 3
	}
	defer delete(executable)
	dir, dir_err := os.make_directory_temp(
		"",
		"shoji-compositor-",
		context.allocator,
	)
	if dir_err != nil {
		fmt.eprintln(dir_err); return 3
	}
	defer delete(dir)
	fmt.eprintln("Evidence:", dir)
	file, file_err := os.create(fmt.tprintf("%s/observations.jsonl", dir))
	if file_err != nil {
		fmt.eprintln(file_err); return 3
	}; defer os.close(file)
	// Capture provenance without changing any security settings. A custom SIP
	// configuration cannot establish fully SIP-enabled compatibility.
	commands := [3][]string {
		{"/usr/bin/sw_vers"},
		{"/usr/bin/uname", "-m"},
		{"/usr/bin/csrutil", "status"},
	}
	for command, i in commands {
		state, stdout, stderr, exec_err := os.process_exec(
			{command = command},
			context.allocator,
		)
		_ = os.write_entire_file(fmt.tprintf("%s/host-%d.txt", dir, i), stdout)
		_ = os.write_entire_file(
			fmt.tprintf("%s/host-%d.err.txt", dir, i),
			stderr,
		)
		delete(stdout); delete(stderr)
		if exec_err != nil || !state.success {
			fmt.eprintln("Could not record provenance command:", command)
		}
	}
	// Spawn before initializing Cocoa in the controller: core:os uses fork/exec.
	out_r, out_w, err := os.pipe(); if err != nil {
		return 3
	}; defer os.close(out_r)
	in_r, in_w, in_err := os.pipe(); if in_err != nil {
		os.close(out_w); return 3
	}; defer os.close(in_w)
	child, spawn_err := os.process_start(
		{
			command = []string {
				executable,
				"--fixture",
				fmt.tprintf("%d", os.get_pid()),
			},
			stdin = in_r,
			stdout = out_w,
			stderr = os.stderr,
		},
	)
	os.close(in_r); os.close(out_w)
	if spawn_err != nil {
		fmt.eprintln("Cannot start disposable fixture:", spawn_err); return 3
	}
	defer {
		os.write(in_w, []u8{'Q'})
		_, wait_err := os.process_wait(child, 2 * time.Second)
		if wait_err != nil {
			_ = os.process_kill(child); _, _ = os.process_wait(child)
		}
	}
	mac.NSApplicationLoad()
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	connection := mac.SLSMainConnectionID()
	if connection == 0 {
		fmt.eprintln(
			"No WindowServer connection. Run this command in Terminal on the laptop.",
		); return 3
	}
	reader: Reader; defer delete(reader.data)
	began := time.now()
	phase := "waiting"
	positive, foreign_readback, owned_hit, foreign_hit: bool
	clicks: [2][2]int
	ready: Observation
	for time.diff(began, time.now()) < 40 * time.Second {
		o, received, failed := next_observation(&reader, out_r)
		if failed {
			fmt.eprintln(
				"Fixture closed or sent invalid output; no capability established.",
			); return 3
		}
		if !received {
			time.sleep(10 * time.Millisecond); continue
		}
		emit(o, file)
		defer delete(o.event)
		defer delete(o.phase)
		if o.event == "ready" {
			if phase != "waiting" || !valid_fixture(o, child.pid, connection) {
				fmt.eprintln("Fixture ownership check failed"); return 3
			}
			ready = o; ready.event = ""; ready.phase = ""
			phase = "owned_clip"
			fmt.eprintln(
				"OWNED control (10 seconds): right half should reveal BLUE. Click each half inside the fixture; clicks are logged.",
			)
			os.write(in_w, []u8{'P'})
		} else if o.event == "readback" {
			half := e.Rect{0, 0, ready.frame.w * 0.5, ready.frame.h}
			if phase == "owned_clip" &&
			   o.phase == phase &&
			   clip_matches(o, half) {
				positive = true
				owned_hit = hit_matches(o)
			}
			if phase == "foreign_clip" &&
			   o.phase == phase &&
			   clip_matches(o, half) {
				foreign_readback = true
				foreign_hit = hit_matches(o)
			}
		} else if o.event == "mouse_down" && o.phase == phase {
			p := phase == "owned_clip" ? 0 : 1
			if o.window == ready.window {
				clicks[p][0] += 1
			}
			if o.window == ready.background {
				clicks[p][1] += 1
			}
		} else if o.event == "restored" && o.phase == phase {
			if phase == "owned_clip" {
				if !positive {
					fmt.eprintln(
						"Owned positive control did not verify clipping; foreign mutation skipped.",
					); return 2
				}
				phase = "foreign_clip"; os.write(in_w, []u8{'F'})
			} else {
				fmt.eprintln(
					"Owned clip readback verified:",
					positive,
					"; foreign clip readback verified:",
					foreign_readback,
				)
				fmt.eprintln(
					"Visual clipping, shadows and click routing still require reviewing the experiment. This does not certify SIP-enabled behavior.",
				)
				fmt.eprintf(
					"Point-query routing: owned=%v foreign=%v\n",
					owned_hit,
					foreign_hit,
				)
				fmt.eprintf(
					"Click records (target/background): owned=%d/%d foreign=%d/%d\n",
					clicks[0][0],
					clicks[0][1],
					clicks[1][0],
					clicks[1][1],
				)
				return foreign_readback && foreign_hit ? 0 : 2
			}
		} else if o.event == "foreign_armed" && phase == "foreign_clip" {
			owner: i32
			if o.window != ready.window ||
			   SLSGetWindowOwner(connection, ready.window, &owner) != 0 ||
			   owner != ready.owner {
				fmt.eprintln("Foreign ownership changed; mutation skipped")
				return 3
			}
			half := e.Rect{0, 0, ready.frame.w * 0.5, ready.frame.h}
			region: mac.Ref
			if CGSNewRegionWithRect(&half, &region) != 0 || region == nil {
				return 3
			}
			code := SLSSetWindowClipShape(connection, ready.window, region)
			CGSReleaseRegion(region)
			emit(
				{
					event = "setter_return",
					phase = phase,
					pid = mac.getpid(),
					connection = connection,
					owner = owner,
					window = ready.window,
					code = code,
				},
				file,
			)
			fmt.eprintln(
				"FOREIGN test (10 seconds): does the right half reveal BLUE again? Click each half inside the fixture.",
			)
		} else if o.event == "geometry_unavailable" ||
		   o.event == "baseline_unverified" ||
		   o.event == "restore_unverified" ||
		   o.event == "window_creation_failed" ||
		   o.event == "no_windowserver" {
			fmt.eprintln(failure_message(o))
			return 3
		}
	}
	fmt.eprintln(
		"Timed out; disposing fixture windows. No capability established.",
	)
	return 3
}
