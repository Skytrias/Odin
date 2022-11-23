/*
	Copyright      2022 Michael Kutowski <skytrias@protonmail.com>
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package text_core_test_regex

import "core:os"
import "core:fmt"
import "core:mem"
import "core:text/regex"
import "core:testing"

TEST_count := 0
TEST_fail := 0

when ODIN_TEST {
	expect  :: testing.expect
	log     :: testing.log
} else {
	expect  :: proc(t: ^testing.T, condition: bool, message: string, loc := #caller_location) {
		TEST_count += 1
		if !condition {
			TEST_fail += 1
			fmt.printf("%v %v\n", loc, message)
			return
		}
	}
	log     :: proc(t: ^testing.T, v: any, loc := #caller_location) {
		fmt.printf("%v ", loc)
		fmt.printf("log: %v\n", v)
	}
}

Test_Entry :: struct {
	pattern: string,
	haystack: string,
	match: regex.Match,
	err: regex.Error,
}

regexp: regex.Regexp

ASCII_Simple_Cases := [?]Test_Entry {
	// empty pattern/haystack
	{ "", "test", {}, .Pattern_Empty },
	{ "test", "", {}, .No_Match },

	// simple
	{ "foobar", "foobar", { 0, 0, 6 }, .OK },
	{ "foobar", "fooba", {}, .No_Match },
	
	// short
	{ "2", "2", { 0, 0, 1 }, .OK },
	{ "1", "1", { 0, 0, 1 }, .OK },
	
	// character classes
	{ "[Ss]imple", "Simple", { 0, 0, 6 }, .OK },
	{ "[Hh]ello [Ww]orld", "Hello World", { 0, 0, 11 }, .OK },
	{ "[Hh]ello [Ww]orld", "Hello world", { 0, 0, 11 }, .OK },
	{ "[Hh]ello [Ww]orld", "hello world", { 0, 0, 11 }, .OK },
	{ "[Hh]ello [Ww]orld", "hello World", { 0, 0, 11 }, .OK },
	{ "[aabc", "a", {}, .Pattern_Ended_Unexpectedly }, // check early ending
	{ "[", "a", {}, .Pattern_Ended_Unexpectedly }, // check early ending
	{ "[\\\\]", "\\", { 0, 0, 1 }, .OK },

	// character class ranges
	{ "[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN]", "x", { 0, 0, 1 }, .OK },
	// { "[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO]", "x", {}, .Character_Class_Buffer_Too_Small },

	// escaped chars
	{ "\\", "\\", {}, .Pattern_Ended_Unexpectedly },
	{ "\\\\", "\\\\", { 0, 0, 1 }, .OK },
	
	// digit class
	{ "\\d", "1", { 0, 0, 1 }, .OK },
	{ "\\d", "a", {}, .No_Match },
	{ "\\d\\d", "12", { 0, 0, 2 }, .OK },

	// non-digit class
	{ "\\D", "a", { 0, 0, 1 }, .OK },
	{ "\\D", "1", {}, .No_Match },
	{ "\\D\\D\\D", "abc", { 0, 0, 3 }, .OK },

	// alpha class
	{ "\\w", "a", { 0, 0, 1 }, .OK },
	{ "\\w", "1", { 0, 0, 1 }, .OK },
	{ "\\w\\w\\w", "__A", { 0, 0, 3 }, .OK },

	// non-alpha class
	{ "\\W", "a", {}, .No_Match },
	{ "\\W", "@", { 0, 0, 1 }, .OK },
	{ "\\W", "-", { 0, 0, 1 }, .OK },

	// whitespace class
	{ "\\s", " ", { 0, 0, 1 }, .OK },
	{ "\\s", "a", {}, .No_Match },
	{ "\\s\\s\\s", "   ", { 0, 0, 3 }, .OK },

	// non-whitespace class
	{ "\\S", "a", { 0, 0, 1, }, .OK },
	{ "\\S", " ", {}, .No_Match },
	{ "\\S\\S\\S", "abc", { 0, 0, 3 }, .OK },

	// inverse class
	{ "[^a]", "0", { 0, 0, 1 }, .OK },
	{ "[^a]", "a", {}, .No_Match },
	{ "[^a]", "A", { 0, 0, 1 }, .OK },
	{ "[^", "", {}, .Pattern_Ended_Unexpectedly }, // check early ending
}

ASCII_Meta_Cases := [?]Test_Entry {
	// begin
	{ "^test", "test", { 0, 0, 4 }, .OK },
	{ "test", "xtest", { 1, 1, 4 }, .OK },
	{ "^test", "xtest", {}, .No_Match },
	{ "^", "test", {}, .OK }, // TODO expected result?

	// end
	{ "$", "", {}, .No_Match },
	{ "$", "test", {}, .No_Match },
	{ "test$", "test", { 0, 0, 4 }, .OK },
	{ "test$", "abctest", { 3, 3, 4 }, .OK },

	// dot
	{ ".", "a", { 0, 0, 1 }, .OK },
	{ ".", "\n", {}, .No_Match },
	{ ".", " ", { 0, 0, 1 }, .OK },
	{ "...", "abc", { 0, 0, 3 }, .OK },
	{ ".y.", "xyz", { 0, 0, 3 }, .OK },

	// star
	{ "s*", "expression", {}, .OK },
	{ "s*", "expresion", {}, .OK },
	{ "es*", "expreion", { 0, 0, 1 }, .OK }, // .Star error previously
	{ "es*", "xpreion", { 3, 3, 1 }, .OK },
	{ "tes*", "tetest", { 0, 0, 2 }, .OK },

	// plus 
	{ "es+", "expression", { 4, 4, 3 }, .OK },
	{ "es+", "expresion", { 4, 4, 2 }, .OK },
	{ "es+", "expresssssssion", { 4, 4, 8 }, .OK },
	{ "es+i", "expresssssssion", { 4, 4, 9 }, .OK },
	{ "es+i", "expression", { 4, 4, 4 }, .OK },
	{ "es+i", "expreion", {}, .No_Match },

	// question mark
	{ "te?st", "test", { 0, 0, 4 }, .OK },
	{ "te?st", "tst", { 0, 0, 3 }, .OK },
	{ "te?s?t", "tt", { 0, 0, 2 }, .OK },
	{ "t??t", "tt", {}, .No_Match },

	// branch
	{ "|", "test", {}, .Operation_Unsupported },
}

// NOTE(Skytrias): should be checked for all object.type variants
// utf8 specific cases with large rune sizes
UTF8_Specific_Cases := [?]Test_Entry {
	// simple unicode with proper length result
	{ "testö", "testö", { 0, 0, 5 }, .OK },
	{ "ö", "ö", { 0, 0, 1 }, .OK },
	{ "ö", "abcö", { 3, 3, 1 }, .OK },
	{ "ööö", "abcööö", { 3, 3, 3 }, .OK },
	
	// proper rune offsets
	{ "abc", "öabc", { 2, 1, 3 }, .OK },
	{ "abc", "öööabc", { 6, 3, 3 }, .OK },
	
	// size 3 big runes
	{ "恥ずべきフクロ", "恥ずべきフクロ", { 0, 0, 7 }, .OK },
	{ "ずべきフクロ", "恥ずべきフクロ", { 3, 1, 6 }, .OK },
	
	// different sizes
	{ "恥", "a", {}, .No_Match },
	{ "a", "恥", {}, .No_Match },

	// digit
	{ "\\d", "恥", {}, .No_Match },
	{ "\\D", "恥", { 0, 0, 1 }, .OK },
	{ "\\d", "恥123", { 3, 1, 1 }, .OK },
	{ "\\D", "123恥", { 3, 3, 1 }, .OK },
	
	// alpha
	{ "\\w", "恥", { 0, 0, 1 }, .OK },
	{ "\\w", " 恥", { 1, 1, 1 }, .OK },
	{ "\\W", "恥 ", { 3, 1, 1 }, .OK },
	
	// space
	{ "\\s", "恥", {}, .No_Match },
	{ "恥\\s", "恥恥恥 ", { 6, 2, 2 }, .OK },
	{ "恥\\s恥", "恥 恥", { 0, 0, 3 }, .OK },
	{ "\\S恥", "恥恥", { 0, 0, 2 }, .OK },
	{ "\\s\\S", "恥 a", { 3, 1, 2 }, .OK },

	// character class
	{ "[Öö]", "Whatö", { 4, 4, 1 }, .OK },
	{ "[Öö]", "What ", {}, .No_Match },
	{ "[Öö ]", "What ", { 4, 4, 1 }, .OK },
	{ "[", "", {}, .Pattern_Ended_Unexpectedly },

	// meta
	
	// begin with unicode
	{ "^te恥st", "te恥st", { 0, 0, 5 }, .OK },
	{ "^恥test", "恥test xyz", { 0, 0, 5 }, .OK },
	
	// end with unicode
	{ "te恥st$", "abcabc te恥st", { 7, 7, 5 }, .OK },
	{ "恥test$", "abcabc 恥test", { 7, 7, 5 }, .OK },
	
	// dot with unicode
	{ "te.st", "te恥st", { 0, 0, 5 }, .OK },
	{ ".st", "abc恥st", { 3, 3, 3 }, .OK },
	{ ".st", "ab恥恥st", { 5, 3, 3 }, .OK },
}

UTF8_Temp_Cases := [?]Test_Entry {
	{ ".st", "ab恥恥st", { 5, 3, 3 }, .OK }, // failed previously
}

test_check_match_entry :: proc(
	t: ^testing.T,
	entry: Test_Entry,
	match: regex.Match,
	err: regex.Error,
) {
	expect(
		t, 
		match == entry.match && err == entry.err, 
		fmt.tprintf(
			"\nRGX:%v\t\tSTR:%v\nExpected match result %v = %v, got %v = %v\n", 
			entry.pattern, 
			entry.haystack, 
			entry.match, 
			entry.err, 
			match, 
			err,
		),
	)
}

@test
test_ascii_simple_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Simple_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}
}

@test
test_ascii_meta_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Meta_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}
}

@test
test_utf8_simple_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Simple_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}
}

@test
test_utf8_meta_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Meta_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}
}

@test
test_utf8_specific_cases :: proc(t: ^testing.T) {
	for entry in UTF8_Specific_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}	
}

@test
test_utf8_temp_cases :: proc(t: ^testing.T) {
	for entry in UTF8_Temp_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}	
}

main :: proc() {
	using fmt

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	{
		regexp = regex.regexp_init()
		defer regex.regexp_destroy(regexp)

		t: testing.T
		test_ascii_simple_cases(&t)
		test_ascii_meta_cases(&t)
		test_utf8_simple_cases(&t)
		test_utf8_meta_cases(&t)
		test_utf8_specific_cases(&t)
		// test_utf8_temp_cases(&t)
	}

	fmt.printf("%v/%v tests successful.\n", TEST_count - TEST_fail, TEST_count)
	if TEST_fail > 0 {
		os.exit(1)
	}

	if len(track.allocation_map) > 0 {
		println()
		for _, v in track.allocation_map {
			printf("%v Leaked %v bytes.\n", v.location, v.size)
		}
	}
}
