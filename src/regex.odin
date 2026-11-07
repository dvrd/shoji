package shoji

import "core:strings"

foreign import libc "system:c"

// Darwin regular expressions
// ------------------------------------------------------------------------

// Darwin regex_t's public ABI; compiled expressions remain owned by libSystem.
// Matching uses the same REG_EXTENDED grammar as yabai.
POSIX_Regex :: struct {
	magic: i32,
	subexpressions: uint,
	end: cstring,
	guts: rawptr,
}
@(default_calling_convention = "c")
foreign libc {
	regcomp :: proc(expression: ^POSIX_Regex, pattern: cstring, flags: i32) -> i32 ---
	regexec :: proc(expression: ^POSIX_Regex, text: cstring, count: uint, matches: rawptr, flags: i32) -> i32 ---
	regfree :: proc(expression: ^POSIX_Regex) ---
}

filter_destroy :: proc(f: ^Filter) {
	if f.enabled {
		regfree(&f.expression)
	}
	delete(f.pattern)
	f^ = {}
}

filter_set :: proc(f: ^Filter, pattern: string, exclude: bool) -> bool {
	if strings.contains(pattern, "\x00") {
		return false
	}
	expression: POSIX_Regex
	if regcomp(
		   &expression,
		   strings.clone_to_cstring(pattern, context.temp_allocator),
		   1,
	   ) !=
	   0 {
		return false
	}
	filter_destroy(f)
	f^ = Filter{strings.clone(pattern), expression, true, exclude}
	return true
}

filter_matches :: proc(f: Filter, text: string) -> bool {
	if !f.enabled {
		return true
	}
	expression := f.expression
	matched :=
		regexec(
			&expression,
			strings.clone_to_cstring(text, context.temp_allocator),
			0,
			nil,
			0,
		) ==
		0
	return matched != f.exclude
}
