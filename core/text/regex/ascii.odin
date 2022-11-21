/*
	Copyright 2021-2022 Jeroen van Rijn  <nom@duclavier.com>
	Copyright      2022 Michael Kutowski <skytrias@protonmail.com>
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:mem"
import "core:fmt"

when true {
	printf :: fmt.printf
} else {
	printf :: proc(f: string, v: ..any) {}
}

// memory layout:
// Operator_Type + upcoming dynamic data
Regexp :: struct {
	buffer: [dynamic]byte,
}

// object read from regexp buffer, type is always filled out, rest is optional
Regexp_Object_ASCII :: struct {
	type: Operator_Type,
	char: u8,
	class: []u8, 
}

Regexp_Walk :: struct {
	// static
	exp: ^Regexp,
	haystack: string,

	// changing content
	temp: []byte, // regex buffer
	buf: string, // haystack buffer

	// result
	length: int,
}

// Public procedures
compile_ascii :: proc(
	regexp: ^Regexp,
	pattern: string,
) -> (err: Error) {
	push_type :: #force_inline proc(buffer: ^[dynamic]byte, type: Operator_Type) {
		append(buffer, transmute(u8) type)
	}

	push_type_char :: #force_inline proc(buffer: ^[dynamic]byte, c: u8) {
		append(buffer, transmute(u8) Operator_Type.Char)
		append(buffer, c)
	}

	push_length :: #force_inline proc(buffer: ^[dynamic]byte) -> (res: ^u16) {
		old := len(buffer)
		resize(buffer, old + 2)
		res = cast(^u16) &buffer[old]
		return
	}

	/*
		The sizes of the two static arrays substantiate the static RAM usage of this package.
		MAX_REGEXP_OBJECTS is the max number of symbols in the expression.
		MAX_CHAR_CLASS_LEN determines the size of buffer for runes in all char-classes in the expression.

		TODO(Jeroen): Use a state machine design to handle escaped characters and character classes as part of the main switch?
	*/

	if pattern == "" {
		err = .Pattern_Empty
		return
	}

	// set & clear buffer
	b := &regexp.buffer
	clear(b)
	
	buf := transmute([]u8)pattern
	char: u8

	for len(buf) > 0 {
		char = buf[0]

		switch char {
		// Meta-characters:
		case '^': push_type(b, .Begin)
		case '$': push_type(b, .End)
		case '.': push_type(b, .Dot)
		case '*': push_type(b, .Star)
		case '+': push_type(b, .Plus)
		case '?': push_type(b, .Question_Mark)
		case '|':
			// Branch is currently bugged
			err = .Operation_Unsupported
			return

		// Escaped character-classes (\s \w ...):
		case '\\':
			// Eat the escape character and decode the escaped character.
			if len(buf) <= 1 {
				// '\\' as last char in pattern -> invalid regular expression.
				err = .Pattern_Ended_Unexpectedly
				return
			}

			buf = buf[1:]
			char = buf[0]

			switch char {
			// Meta-character:
			case 'd': push_type(b, .Digit)
			case 'D': push_type(b, .Not_Digit)
			case 'w': push_type(b, .Alpha)
			case 'W': push_type(b, .Not_Alpha)
			case 's': push_type(b, .Whitespace)
			case 'S': push_type(b, .Not_Whitespace)
			case:
				// Escaped character, e.g. `\`, '.' or '$'
				push_type_char(b, char)
			}

		case '[':
			// Character class:

			// Eat the `[` and decode the next character.
			if len(buf) <= 1 {
				// '['' as last char in pattern -> invalid regular expression.
				err = .Pattern_Ended_Unexpectedly
				return
			}

			buf = buf[1:]
			char = buf[0]

			switch char {
			case '^':
				// Set object type to inverse and eat `^`.
				push_type(b, .Inverse_Character_Class)

				if len(buf) <= 1 {
					// '^' as last char in pattern -> invalid regular expression.
					err = .Pattern_Ended_Unexpectedly
					return
				}

				buf = buf[1:]
				char = buf[0]

			case:
				push_type(b, .Character_Class)
			}

			length := push_length(b)

			// Copy characters inside `[...]` to buffer.
			for {
				if char == '\\' {
					if len(buf) == 0 {
						err = .Pattern_Ended_Unexpectedly  // Expected an escaped character
						return
					}

					append(b, char)
					length^ += 1

					if len(buf) <= 1 {
						// '\\' as last char in pattern -> invalid regular expression.
						err = .Pattern_Ended_Unexpectedly
						return
					}

					buf = buf[1:]
					char = buf[0]
				}

				if char == ']' {
					break
				}

				length^ += 1
				append(b, char)

				if len(buf) <= 1 {
					// pattern ended before ']' -> invalid regular expression.
					err = .Pattern_Ended_Unexpectedly
					return
				}

				buf = buf[1:]
				char = buf[0]
			}

		case:
			// Other characters
			push_type_char(b, char)
		}

		// Advance pattern
		buf = buf[1:]
	}

	// Finish pattern with a Sentinel
	push_type(b, .Sentinel)
	return
}

walk_init :: proc(exp: ^Regexp, haystack: string) -> Regexp_Walk {
	return {
		exp = exp,
		temp = exp.buffer[:],
		
		haystack = haystack,
		buf = haystack,
	}
}

// query data from a byte section and return result and the size it took up
walk_obj_ascii :: proc(data: []byte) -> (
	res: Regexp_Object_ASCII,
	size: int,
) {
	res.type = transmute(Operator_Type) data[0]
	size = 1

	#partial switch res.type {
		case .Char: {
			res.char = data[1]
			size = 2
		}

		case .Character_Class, .Inverse_Character_Class: {
			// read length out
			length := (cast(^u16) &data[1])^
			// rest of the buffer 
			res.class = data[3:3 + length]
			// increase size by length
			size = 3 + int(length)
		}
	}

	return
}

walk_advance :: proc(walk: ^Regexp_Walk) {
	// TODO optimize
	_, size := walk_obj_ascii(walk.temp)
	walk.temp = walk.temp[size:]
}

match_string_ascii :: proc(
	pattern: string, 
	haystack: string, 
	options := DEFAULT_OPTIONS,
) -> (match: Match, err: Error) {
	regexp := Regexp {
		buffer = make([dynamic]byte, 0, mem.Kilobyte * 1),
	}
	// TODO revisit deletion
	defer delete(regexp.buffer)
	compile_ascii(&regexp, pattern) or_return
	walk := walk_init(&regexp, haystack)
	return match_compiled_ascii(&walk)
}

match_compiled_ascii :: proc(walk: ^Regexp_Walk) -> (match: Match, err: Error) {
	start, size := walk_obj_ascii(walk.temp)

	// Bail on empty pattern.
	if start.type != .Sentinel {
		if start.type == .Begin {
			walk_advance(walk)
			err = match_pattern_ascii(walk)
			match = { 0, 0, walk.length }
			return
		} else {
			old_pattern := walk.temp

			for i in 0..<len(walk.haystack) {
				// reset every step while advancing haystack
				walk.length = 0
				walk.temp = old_pattern
				walk.buf = walk.haystack[i:]
				
				e := match_pattern_ascii(walk)

				// Either a match or an error, so return.
				if e != .No_Match {
					err = e
					// TODO maybe still track utf8 char offsets?
					match = { i, i, walk.length }
					return
				}
			}
		}
	}

	err = .No_Match
	return
}

@(private="package")
match_digit_ascii :: proc(c: u8) -> bool {
	return '0' <= c && c <= '9'
}

@(private="package")
match_alpha_ascii :: proc(c: u8) -> bool {
	return ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z')
}

@(private="package")
match_whitespace_ascii :: proc(c: u8) -> bool {
	switch c {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x85, 0xa0: return true
	case:                                               return false
	}
}

@(private="package")
match_alphanum_ascii :: proc(c: u8) -> bool {
	return c == '_' || match_alpha_ascii(c) || match_digit_ascii(c)
}

@(private="package")
match_range_ascii :: proc(c: u8, range: []u8) -> bool {
	if len(range) < 3 {
		return false
	}
	return range[1] == '-' && c >= range[0] && c <= range[2]
}

@(private="package")
__match_dot_ascii :: proc(c: u8) -> bool {
	return c != '\n' && c != '\r'
}

__match_dot_ascii_match_newline :: proc(c: u8) -> bool {
	return true
}

@(private="package")
is_meta_character_ascii :: proc(c: u8) -> bool {
	return (c == 's') || (c == 'S') || (c == 'w') || (c == 'W') || (c == 'd') || (c == 'D')
}

@(private="package")
match_meta_character_ascii :: proc(c, meta: u8) -> bool {
	switch meta {
	case 'd': return  match_digit_ascii     (c)
	case 'D': return !match_digit_ascii     (c)
	case 'w': return  match_alphanum_ascii  (c)
	case 'W': return !match_alphanum_ascii  (c)
	case 's': return  match_whitespace_ascii(c)
	case 'S': return !match_whitespace_ascii(c)
	case:     return  c == meta
	}
}

@(private="package")
match_character_class_ascii :: proc(c: u8, class: []u8) -> bool {
	class := class

	for len(class) > 0 {
		if match_range_ascii(c, class) {
			return true
		} else if class[0] == '\\' {
			// Escape-char: Eat `\\` and match on next char.
			class = class[1:]
			if len(class) == 0 {
				return false
			}

			if match_meta_character_ascii(c, class[0]) {
				return true
			} else if c == class[0] && !is_meta_character_ascii(c) {
				return true
			}
		} else if c == class[0] {
			if c == '-' && len(class) == 1 {
				return true
			} else {
				return true
			}
		}

		class = class[1:]
	}
	return false
}

@(private="package")
match_one_ascii :: proc(
	object: Regexp_Object_ASCII,
	char: u8,
) -> bool {
	printf("[match 1] %c (%v)\n", char, object.type)
	#partial switch object.type {
	case .Sentinel:                return false
	case .Dot:                     return __match_dot_ascii(char)
	case .Character_Class:         return  match_character_class_ascii(char, object.class)
	case .Inverse_Character_Class: return !match_character_class_ascii(char, object.class)
	case .Digit:                   return  match_digit_ascii(char)
	case .Not_Digit:               return !match_digit_ascii(char)
	case .Alpha:                   return  match_alphanum_ascii(char)
	case .Not_Alpha:               return !match_alphanum_ascii(char)
	case .Whitespace:              return  match_whitespace_ascii(char)
	case .Not_Whitespace:          return !match_whitespace_ascii(char)
	case:                          return object.char == char
	}
}

@(private="package")
match_star_ascii :: proc(
	walk: ^Regexp_Walk,
	p: Regexp_Object_ASCII,
) -> (err: Error) {
	idx := 0
	old_length := walk.length

	for idx < len(walk.buf) && match_one_ascii(p, walk.buf[idx]) {
		idx += 1
		walk.length += 1
	}

	temp_buf := walk.buf

	// run till last character
	for idx >= 0 {
		walk.buf = temp_buf[idx:]

		if match_pattern_ascii(walk) == .OK {
			return .OK
		}

		idx -= 1
		walk.length -= 1
	}

	walk.length = old_length
	return .No_Match
}

@(private="package")
match_plus_ascii :: proc(
	walk: ^Regexp_Walk,
	p: Regexp_Object_ASCII,
) -> (err: Error) {
	idx := 0

	for idx < len(walk.buf) && match_one_ascii(p, walk.buf[idx]) {
		idx += 1
		walk.length += 1
	}

	temp_buf := walk.buf

	// run till first character
	for idx > 0 {
		walk.buf = temp_buf[idx:]

		if match_pattern_ascii(walk) == .OK {
			return .OK
		}

		idx -= 1
		walk.length -= 1
	}

	return .No_Match
}

@(private="package")
match_question_ascii :: proc(
	walk: ^Regexp_Walk,
	p: Regexp_Object_ASCII,
) -> (err: Error) {
	if p.type == .Sentinel {
		return .OK
	}

	if match_pattern_ascii(walk) == .OK {
		return .OK
	}

	// check first character
	if len(walk.buf) > 0 && match_one_ascii(p, walk.buf[0]) {
		// check upcoming content
		walk.buf = walk.buf[1:]

		if match_pattern_ascii(walk) == .OK {
			walk.length += 1
			return .OK
		}
	}

	return .No_Match
}

// Iterative matching
// NOTE(Skytrias): resets internal content back to the default
@(private="package")
match_pattern_ascii :: proc(walk: ^Regexp_Walk) -> (err: Error) {
	// end early in case of empty pattern or buffer
	if len(walk.buf) == 0 || len(walk.temp) == 0 {
		return .No_Match
	}

	printf("[match] %v\n", walk.buf)

	for {
		p0, p1: Regexp_Object_ASCII
		p0_size, p1_size: int
		 
		if len(walk.temp) > 0 {
		 	p0, p0_size = walk_obj_ascii(walk.temp)
		}

		// query next one
		if len(walk.temp) > 1 {
			p1, p1_size = walk_obj_ascii(walk.temp[p0_size:])
		}
		
		if p0.type == .Sentinel || p1.type == .Question_Mark {
			c := 0 if len(walk.buf) == 0 else walk.buf[0]
			walk.temp = walk.temp[p0_size + p1_size:]
			printf("[match ?] char: %c | TYPES: %v & %v\n", c, p0.type, p1.type)
			return match_question_ascii(walk, p0)
		} else if p1.type == .Star {
			walk.temp = walk.temp[p0_size + p1_size:]
			printf("[match *] char: %c\n", walk.buf[0])
			return match_star_ascii(walk, p0)
		} else if p1.type == .Plus {
			walk.temp = walk.temp[p0_size + p1_size:]
			printf("[match +] char: %c\n", walk.buf[0])
			return match_plus_ascii(walk, p0)
		} else if p0.type == .End && p1.type == .Sentinel {
			if len(walk.buf) == 0 {
				return .OK
			}
			return .No_Match
		}

		c := 0 if len(walk.buf) == 0 else walk.buf[0]
		if !match_one_ascii(p0, c) {
			break
		} 

		walk.length += 1
		walk.buf = walk.buf[1:]
		walk.temp = walk.temp[p0_size:]
		printf("length: %v, len pattern %v\n", walk.length, len(walk.temp))
	}
	
	return .No_Match
}

// print_ascii :: proc(pattern: []Object_ASCII, classes: []u8) {
// 	for o in pattern {
// 		if o.type == .Sentinel {
// 			break
// 		} else if o.type == .Character_Class || o.type == .Inverse_Character_Class {
// 			fmt.printf("type: %v[ ", o.type)
// 			for i := o.class.start_idx; i < o.class.start_idx + o.class.length; i += 1 {
// 				fmt.printf("%c, ", classes[i])
// 			}
// 			fmt.printf("]\n")
// 		} else if o.type == .Char {
// 			fmt.printf("type: %v{{'%c'}}\n", o.type, o.char)
// 		} else {
// 			fmt.printf("type: %v\n", o.type)
// 		}
// 	}
// }