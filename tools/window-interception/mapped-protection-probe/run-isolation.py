#!/usr/bin/env python3
"""Coordinate the owned-process experiment; run only in the disposable guest."""

import queue
import subprocess
import sys
import threading


def start(binary, mode):
    process = subprocess.Popen(
        [binary, mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, bufsize=0,
    )
    lines = queue.Queue()

    def collect():
        for raw in iter(process.stdout.readline, b""):
            line = raw.decode("utf-8", "replace").rstrip("\n")
            print(f"{mode}: {line}", flush=True)
            lines.put(line)
        lines.put(None)

    threading.Thread(target=collect, daemon=True).start()
    return process, lines


def wait_for(lines, prefix):
    while True:
        line = lines.get(timeout=20)
        if line is None:
            raise RuntimeError(f"process exited before {prefix}")
        if line.startswith(prefix):
            return line


def send(process, command):
    process.stdin.write(command.encode("ascii"))
    process.stdin.flush()


def main():
    if len(sys.argv) not in (2, 3):
        raise ValueError("usage: run-isolation.py /absolute/path/to/probe [--patch | --patch-alias | --patch-alias-max]")
    patch_mode = sys.argv[2] if len(sys.argv) == 3 else "--patch"
    if patch_mode not in ("--patch", "--patch-alias", "--patch-alias-max"):
        raise ValueError("patch mode must be --patch, --patch-alias or --patch-alias-max")
    processes = []
    try:
        witness, witness_lines = start(sys.argv[1], "--witness")
        processes.append(witness)
        wait_for(witness_lines, "WITNESS_READY")
        send(witness, "B")
        wait_for(witness_lines, "WITNESS phase=B page_unchanged=true ")

        patcher, patch_lines = start(sys.argv[1], patch_mode)
        processes.append(patcher)
        wait_for(patch_lines, "PATCH_READY")
        send(patcher, "P")
        wait_for(patch_lines, "PATCHED alias_propagated=true")
        send(witness, "D")
        wait_for(witness_lines, "WITNESS phase=D page_unchanged=true ")
        send(patcher, "R")
        wait_for(patch_lines, "RESTORED page_unchanged=true")
        wait_for(patch_lines, "alias_release_code=0")
        wait_for(patch_lines, "PASS: controlled patch restored")
        send(witness, "A")
        wait_for(witness_lines, "WITNESS phase=A page_unchanged=true ")
        wait_for(witness_lines, "PASS: witness page unchanged")
        for process in processes:
            status = process.wait(timeout=20)
            print(f"{process.args[1]} exit={status}", flush=True)
            if status:
                raise RuntimeError("child failed")
        print("PASS: overlapping witness and controlled patch", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                # EOF asks the patcher to restore even on a controller failure.
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, queue.Empty, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
