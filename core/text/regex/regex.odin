/*
	Copyright 2021-2022 Jeroen van Rijn  <nom@duclavier.com>
	Copyright      2022 Michael Kutowski <skytrias@protonmail.com>
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:mem"
import "core:fmt"

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

/* Definitions: */

MAX_REGEXP_OBJECTS :: #config(REGEX_MAX_REGEXP_OBJECTS, 30) /* Max number of regex symbols in expression. */
MAX_CHAR_CLASS_LEN :: #config(REGEX_MAX_CHAR_CLASS_LEN, 40) /* Max length of character-class buffer in.   */

DEFAULT_OPTIONS    :: Options {}

Option :: enum u8 {
	Dot_Matches_Newline,    /* `.` should match newline as well                                              */
	Case_Insensitive,       /* Case-insensitive match, e.g. [a] matches [aA], can work with Unicode options  */

	ASCII_Only,             /* Accept ASCII haystacks and patterns only to speed things up                   */
	ASCII_Alpha_Match,      /* `\w` uses `core:unicode` to determine if rune is a letter                     */
	ASCII_Digit_Match,      /* `\d` uses `core:unicode` to determine if rune is a digit                      */
	ASCII_Whitespace_Match, /* `\s` uses `core:unicode` to determine if rune is whitespace                   */
}
Options :: bit_set[Option; u8]

// All possible errors that can occur when compiling regex patterns
// and while searching for matches
Error :: enum u8 {
	OK = 0,
	No_Match,

	Pattern_Empty,
	Pattern_Too_Long,
	Pattern_Ended_Unexpectedly,
	Character_Class_Buffer_Too_Small,
	Operation_Unsupported,
	Rune_Error,
	Incompatible_Option,
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

// match a string based on the wanted options
match_string :: proc(
	pattern: string, 
	haystack: string, 
	options := DEFAULT_OPTIONS,
) -> (match: Match, err: Error) {
	if .ASCII_Only in options {
		regexp := Regexp {
			buffer = make([dynamic]byte, 0, mem.Kilobyte * 1),
		}

		compile_ascii(&regexp, pattern) or_return
		walk := walk_init(&regexp, haystack)
		return match_compiled_ascii(&walk)
	} else {
		objects, classes := compile_utf8(pattern) or_return
		info := info_init_utf8(classes[:], options)
		return match_compiled_utf8(objects[:], haystack, info)
	}
}

print :: proc(pattern: $T) {
	when T == Compiled_UTF8 {
		print_utf8(pattern)
	} else when T == Compiled_ASCII {
		print_ascii(pattern)
	} else {
		if p, ok := pattern.(Compiled_UTF8); ok {
			print_utf8(p)
		} else if p, ok := pattern.(Compiled_ASCII); ok {
			print_ascii(p)
		} else {
			unreachable()
		}
	}
}
