package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Instruction :: struct {
	address:  u64,
	op:       string,
	operands: string,
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

hex_digit :: proc(value: rune) -> bool {
	return value >= '0' && value <= '9' || value >= 'a' && value <= 'f'
}

parse_instruction :: proc(line: string) -> (Instruction, bool) {
	trimmed := strings.trim_left(line, " \t")
	colon := strings.index_byte(trimmed, ':')
	if colon <= 0 {return {}, false}
	for c in trimmed[:colon] {if !hex_digit(c) {return {}, false}}
	address, ok := strconv.parse_u64(trimmed[:colon], 16)
	if !ok {return {}, false}
	fields := strings.fields(trimmed[colon + 1:])
	if len(fields) < 2 {return {}, false}
	op_index := -1
	for field, i in fields {
		encoded := len(field) == 2 || len(field) == 8
		if encoded {for c in field {if !hex_digit(c) {encoded = false;break}}}
		if !encoded {op_index = i;break}
	}
	if op_index < 0 {return {}, false}
	op := fields[op_index]
	position := strings.index(trimmed[colon + 1:], op)
	operands := strings.trim_space(trimmed[colon + 1 + position + len(op):])
	return Instruction{address, op, operands}, true
}

is_branch :: proc(op: string) -> bool {
	if op == "b" ||
	   op == "bl" ||
	   op == "cbz" ||
	   op == "cbnz" ||
	   op == "tbz" ||
	   op == "tbnz" {return true}
	return(
		strings.has_prefix(op, "b.") ||
		strings.has_prefix(op, "j") ||
		strings.has_prefix(op, "call") \
	)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: check_bootstrap BINARY...")
		os.exit(2)
	}
	for binary in os.args[1:] {
		args := [?]string {
			"xcrun",
			"llvm-objdump",
			"--disassemble",
			"--section=__shoji_boot",
			binary,
		}
		state, output_bytes, stderr, err := os.process_exec(
			os.Process_Desc{command = args[:]},
			context.allocator,
		)
		defer delete(output_bytes)
		defer delete(stderr)
		if err != nil || !state.success || state.exit_code != 0 {
			fail(
				"%s: llvm-objdump failed (status %d): %s",
				binary,
				state.exit_code,
				string(stderr),
			)
		}
		output := string(output_bytes)
		instructions := make([dynamic]Instruction)
		defer delete(instructions)
		for line in strings.split_lines_iterator(&output) {
			if instruction, parsed := parse_instruction(line);
			   parsed {append(&instructions, instruction)}
		}
		if len(instructions) == 0 {fail("%s: missing bootstrap instructions", binary)}
		if !strings.contains(output, "remote_worker") ||
		   !strings.contains(
				   output,
				   "remote_entry",
			   ) {fail("%s: missing bootstrap symbols", binary)}
		addresses := make(map[u64]bool)
		defer delete(addresses)
		for instruction in instructions {addresses[instruction.address] = true}
		for instruction in instructions {
			operands := instruction.operands
			if index := strings.index_byte(operands, '<'); index >= 0 {operands = operands[:index]}
			if index := strings.index_byte(operands, ';'); index >= 0 {operands = operands[:index]}
			if strings.contains(
				operands,
				"%rip",
			) {fail("%s: 0x%x: RIP-relative data", binary, instruction.address)}
			if instruction.op == "adr" ||
			   instruction.op ==
				   "adrp" {fail("%s: 0x%x: PC-relative data", binary, instruction.address)}
			if is_branch(instruction.op) &&
			   !strings.has_prefix(strings.trim_left(operands, " \t"), "*") {
				remaining := operands
				for {
					start := strings.index(remaining, "0x")
					if start < 0 {break}
					end := start + 2
					for end < len(remaining) && hex_digit(rune(remaining[end])) {end += 1}
					if end > start + 2 {
						target, parsed := strconv.parse_u64(remaining[start + 2:end], 16)
						if parsed &&
						   !addresses[target] {fail("%s: 0x%x: external branch 0x%x", binary, instruction.address, target)}
					}
					remaining = remaining[end:]
				}
			}
			if strings.has_prefix(instruction.op, "ldr") {
				comma := strings.index_byte(operands, ',')
				if comma >= 0 &&
				   strings.has_prefix(
					   strings.trim_left(operands[comma + 1:], " \t"),
					   "0x",
				   ) {fail("%s: literal load", binary)}
			}
		}
		fmt.printf(
			"%s: %d relocation-independent bootstrap instructions checked\n",
			binary,
			len(instructions),
		)
	}
}
