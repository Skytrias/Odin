/*
	Copyright 2021-2022 Jeroen van Rijn  <nom@duclavier.com>
	Copyright      2022 Michael Kutowski <skytrias@protonmail.com>
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

Object_UTF8 :: struct {
	type:  Operator_Type, /* Char, Star, etc. */
	char:  rune,          /* The character itself. */
	class: []rune,        /* OR a string with characters in a class */
}

Info_UTF8 :: struct {
	classes: []rune,
	vtable: Vtable_UTF8,
}

Vtable_UTF8 :: struct {
	match_alpha: proc(r: rune) -> bool,
	match_digit: proc(r: rune) -> bool,
	match_whitespace: proc(r: rune) -> bool,
	match_dot: proc(r: rune) -> bool,
}

/*
	Public procedures
*/
compile_utf8 :: proc(pattern: string) -> (
	objects: [MAX_REGEXP_OBJECTS + 1]Object_UTF8, 
	classes: [MAX_CHAR_CLASS_LEN]rune,
	err: Error,
) {
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

	buf := transmute([]u8)pattern
	ccl_buf_idx := int(0)
	j:         int  /* index into re_compiled    */
	char:      rune
	rune_size: int 

	for len(buf) > 0 {
		char, rune_size = utf8.decode_rune(buf)

		switch char {
			/* '\\' as last char in pattern -> invalid regular expression. */
			case utf8.RUNE_ERROR: {
				err = .Rune_Error
				return
			}

			/*
				Meta-characters:
			*/
			case '^': objects[j].type = .Begin
			case '$': objects[j].type = .End
			case '.': objects[j].type = .Dot
			case '*': objects[j].type = .Star
			case '+': objects[j].type = .Plus
			case '?': objects[j].type = .Question_Mark
			case '|': {
				/*
					Branch is currently bugged
				*/
				err = .Operation_Unsupported
				return
			}

			/*
				Escaped character-classes (\s \w ...):
			*/
			case '\\': {
				/*
				Eat the escape character and decode the escaped character.
				*/
				buf = buf[1:]
				char, rune_size = utf8.decode_rune(buf)

				switch char {
					/* '\\' as last char in pattern -> invalid regular expression. */
					case utf8.RUNE_ERROR: {
						err = .Pattern_Ended_Unexpectedly
						return
					}

					/*
						Meta-character:
					*/
					case 'd': objects[j].type = .Digit
					case 'D': objects[j].type = .Not_Digit
					case 'w': objects[j].type = .Alpha
					case 'W': objects[j].type = .Not_Alpha
					case 's': objects[j].type = .Whitespace
					case 'S': objects[j].type = .Not_Whitespace
					case: {
						/*
							Escaped character, e.g. `\`, '.' or '$'
						*/
						objects[j].type = .Char
						objects[j].char = char
					}
				}
			}

			case '[': {
				/*
					Character class:
				*/

				/*
					Eat the `[` and decode the next character.
				*/
				if len(buf) <= 1 {
					/* '['' as last char in pattern -> invalid regular expression. */
					err = .Pattern_Ended_Unexpectedly
					return
				}

				buf = buf[1:]
				char, rune_size = utf8.decode_rune(buf)

				/*
					Remember where the rune buffer starts in `.classes`.
				*/
				begin := ccl_buf_idx

				switch char {
					case utf8.RUNE_ERROR: {
						err = .Rune_Error
						return
					}

					case '^': {
						/*
							Set object type to inverse and eat `^`.
						*/
						objects[j].type = .Inverse_Character_Class

						if len(buf) <= rune_size {
							err = .Pattern_Ended_Unexpectedly
							return
						}

						buf = buf[rune_size:]
						char, rune_size = utf8.decode_rune(buf)
					}
					
					case: {
						objects[j].type = .Character_Class
					}
				}

				/*
					Copy characters inside `[...]` to buffer.
				*/
				for {
					if char == utf8.RUNE_ERROR {
						err = .Rune_Error
						return
					}

					if char == '\\' {
						if len(buf) <= 1 {
							err = .Pattern_Ended_Unexpectedly  // Expected an escaped character
							return
						}

						if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
							err = .Character_Class_Buffer_Too_Small
							return
						}

						classes[ccl_buf_idx] = char
						ccl_buf_idx += 1

						if len(buf) <= rune_size {
							err = .Pattern_Ended_Unexpectedly
							return
						}
 
						buf = buf[1:]
						char, rune_size = utf8.decode_rune(buf)				
					}

					if char == ']' {
						break
					}

					if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
						err = .Character_Class_Buffer_Too_Small
						return
					}

					classes[ccl_buf_idx] = char
					ccl_buf_idx += 1				

					if len(buf) <= rune_size {
						err = .Pattern_Ended_Unexpectedly
						return
					}

					buf = buf[rune_size:]
					char, rune_size = utf8.decode_rune(buf)				
				}

				objects[j].class = classes[begin:ccl_buf_idx]
			}

			case: {
				/*
					Other characters:
				*/
				objects[j].type = .Char
				objects[j].char = char
			}
		}

		/*
			Advance pattern
		*/
		j  += 1
		buf = buf[rune_size:]
	}

	/*
		Finish pattern with a Sentinel
	*/
	objects[j].type = .Sentinel

	return
}

info_init_utf8 :: proc(
	classes: []rune, 
	options: Options,
) -> Info_UTF8 {
	return {
		classes,
		{
			(.ASCII_Alpha_Match in options) ? __match_alpha_utf8_through_ascii : __match_alpha_utf8,
			(.ASCII_Digit_Match in options) ? __match_digit_utf8_through_ascii : __match_digit_utf8,
			(.ASCII_Whitespace_Match in options) ? __match_whitespace_utf8_through_ascii : __match_whitespace_utf8,
			(.Dot_Matches_Newline in options) ? __match_dot_utf8_match_newline : __match_dot_utf8,
		},
	}
}

match_string_utf8 :: proc(
	pattern: string, 
	haystack: string, 
	options := DEFAULT_OPTIONS,
) -> (match: Match, err: Error) {
	if .ASCII_Only in options {
		err = .Incompatible_Option
		return
	}
	
	objects, classes := compile_utf8(pattern) or_return
	info := info_init_utf8(classes[:], options)
	return match_compiled_utf8(objects[:], haystack, info)
}

match_compiled_utf8 :: proc(
	pattern: []Object_UTF8, 
	haystack: string, 
	info: Info_UTF8,
) -> (match: Match, err: Error) {
	l := int(0)

	if pattern[0].type != .Sentinel {
		if pattern[0].type == .Begin {
			err = match_pattern_utf8(pattern[1:], haystack, &l, info)
			match = { 0, 0, l }
			return
		} else {
			byte_idx := 0
			char_idx := 0

			for byte_idx < len(haystack) {
				l = 0
				e := match_pattern_utf8(pattern, haystack[byte_idx:], &l, info)

				if e != .No_Match {
					match = { byte_idx, char_idx, l }
					err = e
					return
				}

				c, rune_size := utf8.decode_rune(haystack[byte_idx:])
				if c == utf8.RUNE_ERROR {
					printf("ERRR\n")
					err = .Rune_Error
					return
				}
				
				printf("\tSTEP RUNE: %v\tsize: %v\n", c, rune_size)
				byte_idx += rune_size
				char_idx += 1
			}
		}
	}

	err = .No_Match
	return
}

/*
	Private functions:
*/
@(private="package")
__match_digit_utf8 :: proc(r: rune) -> bool {
	return unicode.is_number(r)
}

@(private="package")
__match_digit_utf8_through_ascii :: proc(r: rune) -> bool {
	return '0' <= r && r <= '9'
}

@(private="package")
__match_alpha_utf8 :: proc(r: rune) -> bool {
	return unicode.is_alpha(r)
}

@(private="package")
__match_alpha_utf8_through_ascii :: proc(r: rune) -> bool {
	return ('A' <= r && r <= 'Z') || ('a' <= r && r <= 'z')
}

@(private="package")
__match_whitespace_utf8 :: proc(r: rune) -> bool {
	return unicode.is_space(r)
}

@(private="package")
__match_whitespace_utf8_through_ascii :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x85, 0xa0: return true
	case:                                               return false
	}
}

@(private="package")
__match_dot_utf8 :: proc(r: rune) -> bool {
	return r != '\n' && r != '\r'
}

@(private="package")
__match_dot_utf8_match_newline :: proc(r: rune) -> bool {
	return utf8.rune_size(r) > 0 
}

@(private="package")
match_alphanum_utf8 :: proc(r: rune, info: Info_UTF8) -> bool {
	return r == '_' || info.vtable.match_alpha(r) || info.vtable.match_digit(r)
}

@(private="package")
match_range_utf8 :: proc(r: rune, range: []rune) -> bool {
	if len(range) < 3 {
		return false
	}

	return range[1] == '-' && r >= range[0] && r <= range[2]
}

@(private="package")
is_meta_character_utf8 :: proc(r: rune) -> (match_size: int) {
	return 1 if (r == 's') || (r == 'S') || (r == 'w') || (r == 'W') || (r == 'd') || (r == 'D') else 0
}

@(private="package")
match_meta_character_utf8 :: proc(
	r: rune, 
	meta: rune,
	info: Info_UTF8,
) -> bool {
	switch meta {
	case 'd': return info.vtable.match_digit(r)
	case 'D': return !info.vtable.match_digit(r)
	case 'w': return match_alphanum_utf8(r, info)
	case 'W': return !match_alphanum_utf8(r, info)
	case 's': return info.vtable.match_whitespace(r)
	case 'S': return !info.vtable.match_whitespace(r)
	case:     return r == meta
	}
}

@(private="package")
match_character_class_utf8 :: proc(
	r: rune, 
	info: Info_UTF8,
) -> bool {
	class := info.classes

	for len(class) > 0 {
		if match_range_utf8(r, class) {
			return true
		} else if class[0] == '\\' {
			/* Escape-char: Eat `\\` and match on next char. */
			class = class[1:]
			if len(class) == 0 {
				return false
			}

			if match_meta_character_utf8(r, class[0], info) {
				return true
			} else if r == class[0] && is_meta_character_utf8(r) > 0 {
				return true
			}
		} else if r == class[0] {
			if r == '-' && len(class) == 1 {
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
match_one_utf8 :: proc(
	object: Object_UTF8, 
	r: rune,
	info: Info_UTF8,
) -> bool {
	printf("[match 1] %c (%v)\n", r, object.type)

	#partial switch object.type {
	case .Sentinel:
		return false
	case .Dot:
		return info.vtable.match_dot(r)
	case .Character_Class:
		return match_character_class_utf8(r, info)
	case .Inverse_Character_Class: 
		return !match_character_class_utf8(r, info)
	case .Digit:
		return info.vtable.match_digit(r)
	case .Not_Digit:
		return !info.vtable.match_digit(r)
	case .Alpha:
		return  match_alphanum_utf8(r, info)
	case .Not_Alpha:
		return !match_alphanum_utf8(r, info)
	case .Whitespace:
		return  info.vtable.match_whitespace(r)
	case .Not_Whitespace:
		return !info.vtable.match_whitespace(r)
	case:
		return object.char == r
	}

	return false
}

@(private="package")
match_star_utf8 :: proc(
	p: Object_UTF8,
	pattern: []Object_UTF8, 
	haystack: string,
	length: ^int, 
	info: Info_UTF8,
) -> (err: Error) {
	count := 0
	prelen := length^
	temp_haystack := haystack

	// run through temp haystack and compare by one
	for len(temp_haystack) > 0 {
		c, rune_size := utf8.decode_rune(temp_haystack[:])
		
		if c == utf8.RUNE_ERROR {
			return .Rune_Error
		}

		if !match_one_utf8(p, c, info) {
			break
		}

		temp_haystack = temp_haystack[rune_size:]
		count += 1
		length^ += 1
	}

	// run through the string in reverse (decode utf8 in reverse)
	haystack_front := haystack[:len(haystack) - len(temp_haystack)]
	for count >= 0 {
		if match_pattern_utf8(pattern, temp_haystack, length, info) == .OK {
			return .OK
		}

		// read rune from the last front rune
		c, rune_size := utf8.decode_last_rune_in_string(haystack_front)

		// error early
		if c == utf8.RUNE_ERROR {
			return .Rune_Error
		}

		// reverse decrease the end of the front string
		temp_haystack = haystack[len(haystack_front):]
		haystack_front = haystack_front[:len(haystack_front) - rune_size]
		
		count -= 1
		length^ -= 1
	}

	length^ = prelen
	return .No_Match
}

@(private="package")
match_plus_utf8 :: proc(
	p: Object_UTF8,
	pattern: []Object_UTF8,
	haystack: string, 
	length: ^int, 
	info: Info_UTF8,
) -> (err: Error) {
	count := 0
	temp_haystack := haystack

	// run through temp haystack and compare by one
	for len(temp_haystack) > 0 {
		c, rune_size := utf8.decode_rune(temp_haystack[:])
		
		if c == utf8.RUNE_ERROR {
			return .Rune_Error
		}

		if !match_one_utf8(p, c, info) {
			break
		}

		temp_haystack = temp_haystack[rune_size:]
		count += 1
		length^ += 1
	}

	// run through the string in reverse (decode utf8 in reverse)
	haystack_front := haystack[:len(haystack) - len(temp_haystack)]
	for count > 0 {
		if match_pattern_utf8(pattern, temp_haystack, length, info) == .OK {
			return .OK
		}

		// read rune from the last front rune
		c, rune_size := utf8.decode_last_rune_in_string(haystack_front)

		// error early
		if c == utf8.RUNE_ERROR {
			return .Rune_Error
		}

		// reverse decrease the end of the front string
		temp_haystack = haystack[len(haystack_front):]
		haystack_front = haystack_front[:len(haystack_front) - rune_size]
		
		count -= 1
		length^ -= 1
	}

	return .No_Match
}

@(private="package")
match_question_utf8 :: proc(
	p: Object_UTF8,
	pattern: []Object_UTF8, 
	haystack: string, 
	length: ^int, 
	info: Info_UTF8,
) -> (err: Error) {
	if p.type == .Sentinel {
		return .OK
	}

	if match_pattern_utf8(pattern, haystack, length, info) == .OK {
		return .OK
	}

	// check first character
	if len(haystack) > 0 {
		c, rune_size := utf8.decode_rune(haystack[:])

		// check first rune
		if !match_one_utf8(p, c, info) {
			return .No_Match
		}

		// check upcoming content
		if match_pattern_utf8(pattern, haystack[rune_size:], length, info) == .OK {
			length^ += 1
			return .OK
		}
	}

	return .No_Match
}

match_pattern_utf8 :: proc(
	pattern: []Object_UTF8, 
	haystack: string, 
	length: ^int,
	info: Info_UTF8,
) -> (err: Error) {
	// end early in case of empty pattern or buffer
	if len(haystack) == 0 || len(pattern) == 0 {
		return .No_Match
	}

	pattern := pattern
	haystack := haystack
	length_in := length^
	printf("[match] %v\n", haystack)

	for {
		// NOTE(Skytrias): simple bounds checking
		p0 := len(pattern) > 0 ? pattern[0] : {}
		p1 := len(pattern) > 1 ? pattern[1] : {}
		
		// fetch the next rune, available for printing
		c: rune
		rune_size: int
		if len(haystack) == 0 {
			c = 0
		} else {
			c, rune_size = utf8.decode_rune(haystack[:])
			
			if c == utf8.RUNE_ERROR {
				printf("ERR1\n")
				return .Rune_Error
			}
		}
		printf("\t\tRUNE %v -> %v\n", c, rune_size)

		if p0.type == .Sentinel || p1.type == .Question_Mark {
			printf("[match ?] char: %v | TYPES: %v & %v\n", c, p0.type, p1.type)
			return match_question_utf8(p0, pattern[2:], haystack, length, info)
		} else if p1.type == .Star {
			printf("[match *] char: %v\n", c)
			return match_star_utf8(p0, pattern[2:], haystack, length, info)
		} else if p1.type == .Plus {
			printf("[match +] char: %v\n", c)
			return match_plus_utf8(p0, pattern[2:], haystack, length, info)
		} else if p0.type == .End && p1.type == .Sentinel {
			if len(haystack) == 0 {
				return .OK
			}

			return .No_Match
		}

		if !match_one_utf8(p0, c, info) {
			break
		} 

		// advance by the next rune
		haystack = haystack[rune_size:]
		pattern = pattern[1:]
		length^ += 1
		printf("[LEN]: %v\n", length^)
	}
	
	length^ = length_in
	return .No_Match
}

print_utf8 :: proc(pattern: []Object_UTF8, classes: []rune) {
	for o in pattern {
		if o.type == .Sentinel {
			break
		} else if o.type == .Character_Class || o.type == .Inverse_Character_Class {
			fmt.printf("type: %v%v\n", o.type, o.class)
		} else if o.type == .Char {
			fmt.printf("type: %v{{'%c'}}\n", o.type, o.char)
		} else {
			fmt.printf("type: %v\n", o.type)
		}
	}
}