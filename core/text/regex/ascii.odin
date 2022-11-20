/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:fmt"

when false {
	printf :: fmt.printf
} else {
	printf :: proc(f: string, v: ..any) {}
}

Object_ASCII :: struct {
	type:  Operator_Type, /* Char, Star, etc. */
	char: u8,                /* The character itself. */
	class: Slice,         /* OR a string with characters in a class */
}

// options or stored class data we pass around
Info_ASCII :: struct {
	options: Options,
	classes: []u8,
}

/* Definitions: */

/*
	Public procedures
*/
compile_ascii :: proc(pattern: string) -> (
	objects: [MAX_REGEXP_OBJECTS + 1]Object_ASCII, 
	classes: [MAX_CHAR_CLASS_LEN]u8,
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
	ccl_buf_idx := u16(0)
	j:         int  /* index into re_compiled    */
	char:      u8

	for len(buf) > 0 {
		// range check j for max range
		if j + 1 > MAX_REGEXP_OBJECTS + 1 {
			err = .Pattern_Too_Long
			return
		}

		char = buf[0]

		switch char {
		/*
			Meta-characters:
		*/
		case '^': objects[j].type = .Begin
		case '$': objects[j].type = .End
		case '.': objects[j].type = .Dot
		case '*': objects[j].type = .Star
		case '+': objects[j].type = .Plus
		case '?': objects[j].type = .Question_Mark
		case '|':
			/*
				Branch is currently bugged
			*/
			err = .Operation_Unsupported
			return

		/*
			Escaped character-classes (\s \w ...):
		*/
		case '\\':
			/*
				Eat the escape character and decode the escaped character.
			*/
			if len(buf) <= 1 {
				/* '\\' as last char in pattern -> invalid regular expression. */
				err = .Pattern_Ended_Unexpectedly
				return
			}

			buf = buf[1:]
			char = buf[0]

			switch char {
			/*
				Meta-character:
			*/
			case 'd': objects[j].type = .Digit
			case 'D': objects[j].type = .Not_Digit
			case 'w': objects[j].type = .Alpha
			case 'W': objects[j].type = .Not_Alpha
			case 's': objects[j].type = .Whitespace
			case 'S': objects[j].type = .Not_Whitespace
			case:
				/*
					Escaped character, e.g. `\`, '.' or '$'
				*/
				objects[j].type   = .Char
				objects[j].char = char
			}

		case '[':
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
			char = buf[0]

			/*
				Remember where the rune buffer starts in `.classes`.
			*/
			begin := ccl_buf_idx

			switch char {
			case '^':
				/*
					Set object type to inverse and eat `^`.
				*/
				objects[j].type = .Inverse_Character_Class

				if len(buf) <= 1 {
					/* '^' as last char in pattern -> invalid regular expression. */
					err = .Pattern_Ended_Unexpectedly
					return
				}

				buf = buf[1:]
				char = buf[0]

			case:
				objects[j].type = .Character_Class
			}

			/*
				Copy characters inside `[...]` to buffer.
			*/
			for {
				if char == '\\' {
					if len(buf) == 0 {
						err = .Pattern_Ended_Unexpectedly  // Expected an escaped character
						return
					}

					if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
						err = .Character_Class_Buffer_Too_Small
						return
					}

					classes[ccl_buf_idx] = char
					ccl_buf_idx += 1

					if len(buf) <= 1 {
						/* '\\' as last char in pattern -> invalid regular expression. */
						err = .Pattern_Ended_Unexpectedly
						return
					}

					buf = buf[1:]
					char = buf[0]
				}

				if char == ']' {
					break;
				}

				if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
					err = .Character_Class_Buffer_Too_Small
					return
				}

				classes[ccl_buf_idx] = char
				ccl_buf_idx += 1				

				if len(buf) <= 1 {
					/* pattern ended before ']' -> invalid regular expression. */
					err = .Pattern_Ended_Unexpectedly
					return
				}

				buf = buf[1:]
				char = buf[0]
			}

			objects[j].class = Slice{begin, ccl_buf_idx - begin}

		case:
			// Other characters:
			objects[j].type   = .Char
			objects[j].char = char
		}

		// Advance pattern
		j += 1
		buf = buf[1:]
	}

	// Finish pattern with a Sentinel
	objects[j].type = .Sentinel
	return
}

match_string_ascii :: proc(
	pattern: string, 
	haystack: string, 
	options := DEFAULT_OPTIONS,
) -> (match: Match, err: Error) {
	objects, classes := compile_ascii(pattern) or_return
	info := Info_ASCII { options | { .ASCII_Only }, classes[:] }
	return match_compiled_ascii(objects[:], haystack, info)
}

match_compiled_ascii :: proc(
	pattern: []Object_ASCII, 
	haystack: string, 
	info: Info_ASCII,
) -> (match: Match, err: Error) {
	haystack := haystack
	buf      := transmute([]u8)haystack
	l := int(0)

	// Bail on empty pattern.
	if pattern[0].type != .Sentinel {
		if pattern[0].type == .Begin {
			err = match_pattern_ascii(pattern[1:], buf, &l, info)
			match = { 0, 0, l }
			return
		} else {
			for _, byte_idx in haystack {
				l = 0
				e := match_pattern_ascii(pattern, buf[byte_idx:], &l, info)

				// Either a match or an error, so return.
				if e != .No_Match {
					err = e
					// TODO maybe still track utf8 char offsets?
					match = { byte_idx, byte_idx, l }
					return
				}
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
match_dot_ascii :: proc(c: u8, match_newline: bool) -> bool {
	return match_newline || c != '\n' && c != '\r'
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
			/* Escape-char: Eat `\\` and match on next char. */
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
	object: Object_ASCII,
	char: u8, 
	info: Info_ASCII,
) -> bool {
	printf("[match 1] %c (%v)\n", char, object.type)
	#partial switch object.type {
	case .Sentinel:                return false
	case .Dot:                     return  match_dot_ascii(char, .Dot_Matches_Newline in info.options)
	case .Character_Class:         return  match_character_class_ascii(char, info.classes)
	case .Inverse_Character_Class: return !match_character_class_ascii(char, info.classes)
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
	p: Object_ASCII,
	pattern: []Object_ASCII, 
	buf: []u8,
	length: ^int, 
	info: Info_ASCII,
) -> (err: Error) {
	idx := 0
	prelen := length^

	for idx < len(buf) && match_one_ascii(p, buf[idx], info) {
		idx += 1
		length^ += 1
	}

	// run till last character
	for idx >= 0 {
		if match_pattern_ascii(pattern, buf[idx:], length, info) == .OK {
			return .OK
		}
		idx -= 1
		length^ -= 1
	}

	length^ = prelen
	return .No_Match
}

@(private="package")
match_plus_ascii :: proc(
	p: Object_ASCII,
	pattern: []Object_ASCII,
	buf: []u8, 
	length: ^int, 
	info: Info_ASCII,
) -> (err: Error) {
	idx := 0

	for idx < len(buf) && match_one_ascii(p, buf[idx], info) {
		idx += 1
		length^ += 1
	}

	// run till first character
	for idx > 0 {
		if match_pattern_ascii(pattern, buf[idx:], length, info) == .OK {
			return .OK
		}
		idx -= 1
		length^ -= 1
	}

	return .No_Match
}

@(private="package")
match_question_ascii :: proc(
	p: Object_ASCII,
	pattern: []Object_ASCII, 
	buf: []u8, 
	length: ^int, 
	info: Info_ASCII,
) -> (err: Error) {
	if p.type == .Sentinel {
		return .OK
	}

	if match_pattern_ascii(pattern, buf, length, info) == .OK {
		return .OK
	}

	// check first character
	if len(buf) > 0 && match_one_ascii(p, buf[0], info) {
		// check upcoming content
		if match_pattern_ascii(pattern, buf[1:], length, info) == .OK {
			length^ += 1
			return .OK
		}
	}

	return .No_Match
}

/* Iterative matching */
@(private="package")
match_pattern_ascii :: proc(
	pattern: []Object_ASCII, 
	buf: []u8, 
	length: ^int, 
	info: Info_ASCII,
) -> (err: Error) {
	// end early in case of empty pattern or buffer
	if len(buf) == 0 || len(pattern) == 0 {
		return .No_Match
	}

	pattern := pattern
	buf     := buf
	length_in := length^
	printf("[match] %v\n", string(buf))

	for {
		// NOTE(Skytrias): simple bounds checking
		p0 := len(pattern) > 0 ? pattern[0] : {}
		p1 := len(pattern) > 1 ? pattern[1] : {}
		
		if p0.type == .Sentinel || p1.type == .Question_Mark {
			c := 0 if len(buf) == 0 else buf[0]
			printf("[match ?] char: %c | TYPES: %v & %v\n", c, p0.type, p1.type)
			return match_question_ascii(p0, pattern[2:], buf, length, info)
		} else if p1.type == .Star {
			printf("[match *] char: %c\n", buf[0])
			return match_star_ascii(p0, pattern[2:], buf, length, info)
		} else if p1.type == .Plus {
			printf("[match +] char: %c\n", buf[0])
			return match_plus_ascii(p0, pattern[2:], buf, length, info)
		} else if p0.type == .End && p1.type == .Sentinel {
			if len(buf) == 0 {
				return .OK
			}
			return .No_Match
		}

		/*  Branching is not working properly
			else if (p1.type == BRANCH)
			{
			  return (matchpattern(pattern, text) || matchpattern(&pattern[2], text));
			}
		*/

		c := 0 if len(buf) == 0 else buf[0]
		if !match_one_ascii(p0, c, info) {
			break
		} 

		length^ += 1
		buf     = buf[1:]
		pattern = pattern[1:]
		printf("length: %v, len pattern %v\n", length^, len(pattern))
	}
	
	length^ = length_in
	return .No_Match
}

print_ascii :: proc(pattern: []Object_ASCII, classes: []u8) {
	for o in pattern {
		if o.type == .Sentinel {
			break
		} else if o.type == .Character_Class || o.type == .Inverse_Character_Class {
			fmt.printf("type: %v[ ", o.type)
			for i := o.class.start_idx; i < o.class.start_idx + o.class.length; i += 1 {
				fmt.printf("%c, ", classes[i])
			}
			fmt.printf("]\n")
		} else if o.type == .Char {
			fmt.printf("type: %v{{'%c'}}\n", o.type, o.char)
		} else {
			fmt.printf("type: %v\n", o.type)
		}
	}
}