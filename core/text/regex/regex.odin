/*
	Copyright 2021-2022 Jeroen van Rijn  <nom@duclavier.com>
	Copyright      2022 Michael Kutowski <skytrias@protonmail.com>
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:mem"
import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

/*
	Mini regex-module inspired by Rob Pike's regex code described in:
		http://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html

	Supports:
	---------
	'.'        Dot, matches any character
	'^'        Start anchor, matches beginning of string
	'$'        End anchor, matches end of string
	'*'        Asterisk, match zero or more (greedy)
	'+'        Plus, match one or more (greedy)
	'?'        Question, match zero or one (non-greedy)
	'[abc]'    Character class, match if one of {'a', 'b', 'c'}
	'[^abc]'   Inverted class, match if NOT one of {'a', 'b', 'c'} -- NOTE: feature is currently broken!
	'[a-zA-Z]' Character ranges, the character set of the ranges { a-z | A-Z }
	'\s'       Whitespace, \t \f \r \n \v and spaces
	'\S'       Non-whitespace
	'\w'       Alphanumeric, [a-zA-Z0-9_]
	'\W'       Non-alphanumeric
	'\d'       Digits, [0-9]
	'\D'       Non-digits
*/

when false {
	printf :: fmt.printf
} else {
	printf :: proc(f: string, v: ..any) {}
}

MAX_REGEXP_OBJECTS :: #config(REGEX_MAX_REGEXP_OBJECTS, 30) /* Max number of regex symbols in expression. */
MAX_CHAR_CLASS_LEN :: #config(REGEX_MAX_CHAR_CLASS_LEN, 40) /* Max length of character-class buffer in.   */

DEFAULT_OPTIONS    :: Options {}

Option :: enum u8 {
	Dot_Matches_Newline,    /* `.` should match newline as well                                              */
	Case_Insensitive,       /* Case-insensitive match, e.g. [a] matches [aA], can work with Unicode options  */
}
Options :: bit_set[Option; u8]

// All possible errors that can occur when compiling regex patterns
// and while searching for matches
Error :: enum u8 {
	OK = 0,
	No_Match,

	Pattern_Empty,
	Pattern_Ended_Unexpectedly,
	Operation_Unsupported,
	Rune_Error,
}

/* Internal definitions: */

Operator_Type :: enum u8 {
	Sentinel,
	Dot,
	Begin,
	End,
	Question_Mark,
	Star,
	Plus,
	Char,
	Character_Class,
	Inverse_Character_Class,
	Digit,
	Not_Digit,
	Alpha,
	Not_Alpha,
	Whitespace,
	Not_Whitespace,
	Branch, // TODO support branching
}

// Small sized slice to view into class data
Slice :: struct {
	start_idx: u16,
	length:    u16,
}

// Match of a regex pattern match
Match :: struct {
	// position of the match in bytes
	byte_offset: int,
	
	// position of the match in characters
	char_offset: int,
	
	// length of the match in characters
	length: int,
}

Regexp :: struct {
	objects: [dynamic]Object,
	classes: [dynamic]rune,
	match_newline: bool,
}

Object :: struct {
	type:  Operator_Type, /* Char, Star, etc. */
	char:  rune,          /* The character itself. */
	class: []rune,        /* OR a string with characters in a class */
}

regexp_init :: proc() -> Regexp {
	return {
		objects = make([dynamic]Object, 0, 30),
		classes = make([dynamic]rune, 0, 40),
	}
}

regexp_destroy :: proc(regexp: Regexp) {
	delete(regexp.objects)
	delete(regexp.classes)
}

read_rune :: proc(buf: string) -> (char: rune, rune_size: int, err: Error) {
	char, rune_size = utf8.decode_rune(buf)
	if char == utf8.RUNE_ERROR {
		err = .Rune_Error
	}
	return
}

read_last_rune :: proc(buf: string) -> (char: rune, rune_size: int, err: Error) {
	char, rune_size = utf8.decode_last_rune(buf)
	if char == utf8.RUNE_ERROR {
		err = .Rune_Error
	}
	return
}

// Public procedures
compile :: proc(regexp: ^Regexp, pattern: string) -> (err: Error) {
	/*
		The sizes of the two static arrays substantiate the static RAM usage of this package.
		MAX_REGEXP_OBJECTS is the max number of symbols in the expression.
		MAX_CHAR_CLASS_LEN determines the size of buffer for runes in all char-classes in the expression.

		TODO(Jeroen): Use a state machine design to handle escaped characters and character classes as part of the main switch?
	*/

	push_type :: proc(objects: ^[dynamic]Object, type: Operator_Type) {
		append(objects, Object { type = type })
	}

	push_char :: proc(objects: ^[dynamic]Object, r: rune) {
		append(objects, Object { type = .Char, char = r })
	}

	push_class :: proc(objects: ^[dynamic]Object, inverted: bool) -> ^[]rune {
		type: Operator_Type = inverted ? .Inverse_Character_Class : .Character_Class
		append(objects, Object { type = type })
		obj := &objects[len(objects) - 1]
		return &obj.class
	}

	if pattern == "" {
		err = .Pattern_Empty
		return
	}

	// clear previous data
	objects := &regexp.objects
	clear(objects)
	classes := &regexp.classes
	clear(classes)

	buf := pattern
	ccl_buf_idx := int(0)
	char: rune
	rune_size: int 

	for len(buf) > 0 {
		char, rune_size = read_rune(buf) or_return

		switch char {
			// Meta-characters:
			case '^': push_type(objects, .Begin)
			case '$': push_type(objects, .End)
			case '.': push_type(objects, .Dot)
			case '*': push_type(objects, .Star)
			case '+': push_type(objects, .Plus)
			case '?': push_type(objects, .Question_Mark)
			case '|': {
				// Branch is currently bugged
				err = .Operation_Unsupported
				return
			}

			//  Escaped character-classes (\s \w ...):
			case '\\': {
				// Eat the escape character and decode the escaped character.
				buf = buf[1:]

				// dont let buf be empty by now
				if len(buf) == 0 {
					err = .Pattern_Ended_Unexpectedly
					return
				}

				char, rune_size = read_rune(buf) or_return

				switch char {
					// Meta-character:
					case 'd': push_type(objects, .Digit)
					case 'D': push_type(objects, .Not_Digit)
					case 'w': push_type(objects, .Alpha)
					case 'W': push_type(objects, .Not_Alpha)
					case 's': push_type(objects, .Whitespace)
					case 'S': push_type(objects, .Not_Whitespace)
					case: {
						// Escaped character, e.g. `\`, '.' or '$'
						push_char(objects, char)
					}
				}
			}

			case '[': {
				// Character class:

				// Eat the `[` and decode the next character.
				if len(buf) <= 1 {
					// '['' as last char in pattern -> invalid regular expression.
					err = .Pattern_Ended_Unexpectedly
					return
				}

				buf = buf[1:]
				char, rune_size = read_rune(buf) or_return

				// Remember where the rune buffer starts in `.classes`.
				classes_begin := len(classes)
				inverted: bool

				if char == '^' {
					// Set object type to inverse and eat `^`.
					inverted = true

					if len(buf) <= rune_size {
						err = .Pattern_Ended_Unexpectedly
						return
					}

					buf = buf[rune_size:]
					char, rune_size = read_rune(buf) or_return
				}

				class := push_class(objects, inverted)

				// Copy characters inside `[...]` to buffer.
				for {
					if char == '\\' {
						if len(buf) <= 1 {
							err = .Pattern_Ended_Unexpectedly  // Expected an escaped character
							return
						}

						append(classes, char)

						if len(buf) <= rune_size {
							err = .Pattern_Ended_Unexpectedly
							return
						}
 
						buf = buf[1:]
						char, rune_size = read_rune(buf) or_return
					}

					if char == ']' {
						break
					}

					append(classes, char)
					ccl_buf_idx += 1				

					if len(buf) <= rune_size {
						err = .Pattern_Ended_Unexpectedly
						return
					}

					buf = buf[rune_size:]
					char, rune_size = read_rune(buf) or_return
				}

				class^ = classes[classes_begin:]
			}

			case: {
				// Other characters
				push_char(objects, char)
			}
		}

		// Advance pattern
		buf = buf[rune_size:]
	}

	// Finish pattern with a Sentinel
	push_type(objects, .Sentinel)

	return
}

match_string :: proc(
	regexp: ^Regexp,
	pattern: string, 
	haystack: string, 
	options := DEFAULT_OPTIONS,
) -> (match: Match, err: Error) {
	compile(regexp, pattern) or_return
	return match_compiled(regexp, haystack)
}

match_compiled :: proc(
	regexp: ^Regexp,
	haystack: string, 
) -> (match: Match, err: Error) {
	pattern := regexp.objects[:]

	if len(pattern) > 0 {
		if pattern[0].type == .Begin {
			length: int
			err = match_pattern(pattern[1:], haystack, &length)
			match = { 0, 0, length }
			return
		} else {
			byte_idx := 0
			char_idx := 0

			for byte_idx < len(haystack) {
				length := 0
				e := match_pattern(pattern, haystack[byte_idx:], &length)

				if e != .No_Match {
					match = { byte_idx, char_idx, length }
					err = e
					return
				}

				char, rune_size := read_rune(haystack[byte_idx:]) or_return
				
				printf("\tSTEP RUNE: %v\tsize: %v\n", char, rune_size)
				byte_idx += rune_size
				char_idx += 1
			}
		}
	}

	err = .No_Match
	return
}

@(private="package")
match_digit :: proc(r: rune) -> bool {
	return unicode.is_number(r)
}

@(private="package")
match_alpha :: proc(r: rune) -> bool {
	return unicode.is_alpha(r)
}

@(private="package")
match_whitespace :: proc(r: rune) -> bool {
	return unicode.is_space(r)
}

@(private="package")
match_dot :: proc(r: rune) -> bool {
	return r != '\n' && r != '\r'
}

@(private="package")
match_alphanum :: proc(r: rune) -> bool {
	return r == '_' || unicode.is_alpha(r) || unicode.is_digit(r)
}

@(private="package")
match_range :: proc(r: rune, range: []rune) -> bool {
	if len(range) < 3 {
		return false
	}

	return range[1] == '-' && r >= range[0] && r <= range[2]
}

@(private="package")
is_meta_character :: proc(r: rune) -> (match_size: int) {
	return 1 if (r == 's') || (r == 'S') || (r == 'w') || (r == 'W') || (r == 'd') || (r == 'D') else 0
}

@(private="package")
match_meta_character :: proc(
	r: rune, 
	meta: rune,
) -> bool {
	switch meta {
	case 'd': return unicode.is_digit(r)
	case 'D': return !unicode.is_digit(r)
	case 'w': return match_alphanum(r)
	case 'W': return !match_alphanum(r)
	case 's': return unicode.is_space(r)
	case 'S': return !unicode.is_space(r)
	case:     return r == meta
	}
}

@(private="package")
match_character_class :: proc(
	r: rune, 
	class: []rune,
) -> bool {
	class := class

	for len(class) > 0 {
		if match_range(r, class) {
			return true
		} else if class[0] == '\\' {
			/* Escape-char: Eat `\\` and match on next char. */
			class = class[1:]
			if len(class) == 0 {
				return false
			}

			if match_meta_character(r, class[0]) {
				return true
			} else if r == class[0] && is_meta_character(r) > 0 {
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
match_one :: proc(
	object: Object, 
	r: rune,
) -> bool {
	printf("[match 1] %c (%v)\n", r, object.type)

	#partial switch object.type {
	case .Sentinel:
		return false
	case .Dot:
		// TODO match newline
		return match_dot(r)
	case .Character_Class:
		return match_character_class(r, object.class)
	case .Inverse_Character_Class: 
		return !match_character_class(r, object.class)
	case .Digit:
		return unicode.is_digit(r)
	case .Not_Digit:
		return !unicode.is_digit(r)
	case .Alpha:
		return  match_alphanum(r)
	case .Not_Alpha:
		return !match_alphanum(r)
	case .Whitespace:
		return  unicode.is_space(r)
	case .Not_Whitespace:
		return !unicode.is_space(r)
	case:
		return object.char == r
	}

	return false
}

@(private="package")
match_star :: proc(
	p: Object,
	pattern: []Object, 
	haystack: string,
	length: ^int, 
) -> (err: Error) {
	count := 0
	prelen := length^
	temp_haystack := haystack

	// run through temp haystack and compare by one
	for len(temp_haystack) > 0 {
		char, rune_size := read_rune(temp_haystack[:]) or_return

		if !match_one(p, char) {
			break
		}

		temp_haystack = temp_haystack[rune_size:]
		count += 1
		length^ += 1
	}

	// run through the string in reverse (decode utf8 in reverse)
	haystack_front := haystack[:len(haystack) - len(temp_haystack)]
	for count >= 0 {
		if match_pattern(pattern, temp_haystack, length) == .OK {
			return .OK
		}

		// read rune from the last front rune
		_, rune_size := read_last_rune(haystack_front) or_return

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
match_plus :: proc(
	p: Object,
	pattern: []Object,
	haystack: string, 
	length: ^int, 
) -> (err: Error) {
	count := 0
	temp_haystack := haystack

	// run through temp haystack and compare by one
	for len(temp_haystack) > 0 {
		char, rune_size := read_rune(temp_haystack[:]) or_return

		if !match_one(p, char) {
			break
		}

		temp_haystack = temp_haystack[rune_size:]
		count += 1
		length^ += 1
	}

	// run through the string in reverse (decode utf8 in reverse)
	haystack_front := haystack[:len(haystack) - len(temp_haystack)]
	for count > 0 {
		if match_pattern(pattern, temp_haystack, length) == .OK {
			return .OK
		}

		// read rune from the last front rune
		_, rune_size := read_last_rune(haystack_front) or_return

		// reverse decrease the end of the front string
		temp_haystack = haystack[len(haystack_front):]
		haystack_front = haystack_front[:len(haystack_front) - rune_size]
		
		count -= 1
		length^ -= 1
	}

	return .No_Match
}

@(private="package")
match_question :: proc(
	p: Object,
	pattern: []Object, 
	haystack: string, 
	length: ^int, 
) -> (err: Error) {
	if match_pattern(pattern, haystack, length) == .OK {
		return .OK
	}

	// check first character
	if len(haystack) > 0 {
		char, rune_size := read_rune(haystack[:]) or_return

		// check first rune
		if !match_one(p, char) {
			return .No_Match
		}

		// check upcoming content
		if match_pattern(pattern, haystack[rune_size:], length) == .OK {
			length^ += 1
			return .OK
		}
	}

	return .No_Match
}

match_pattern :: proc(
	pattern: []Object, 
	haystack: string, 
	length: ^int,
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
		char: rune
		rune_size: int
		if len(haystack) != 0 {
			char, rune_size = read_rune(haystack[:]) or_return
		}
		printf("\t\tRUNE %v -> %v\n", char, rune_size)

		if p0.type == .Sentinel {
			err = .OK
			return
		} else if p1.type == .Question_Mark {
			if len(pattern) > 2 {
				printf("[match ?] char: %v | TYPES: %v & %v\n", char, p0.type, p1.type)
				return match_question(p0, pattern[2:], haystack, length)
			}
		} else if p1.type == .Star {
			if len(pattern) > 2 {
				printf("[match *] char: %v\n", char)
				return match_star(p0, pattern[2:], haystack, length)
			}
		} else if p1.type == .Plus {
			if len(pattern) > 2 {
				printf("[match +] char: %v\n", char)
				return match_plus(p0, pattern[2:], haystack, length)
			}
		} else if p0.type == .End && p1.type == .Sentinel {
			if len(haystack) == 0 {
				return .OK
			}

			return .No_Match
		}

		if !match_one(p0, char) {
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

print :: proc(pattern: []Object, classes: []rune) {
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