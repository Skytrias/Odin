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

	// inverted class
	{ "[^a]", "0", { 0, 0, 1 }, .OK },
	{ "[^a]", "a", {}, .No_Match },
	{ "[^a]", "A", { 0, 0, 1 }, .OK },
	{ "[^", "", {}, .Pattern_Ended_Unexpectedly }, // check early ending
	{ "[^abc]", "abctest", { 3, 3, 1 }, .OK },
	{ "[^abc]+", "abctest", { 3, 3, 4 }, .OK },
	{ "[^abc]+", "abctestabc", { 3, 3, 4 }, .OK },
	{ "[^0-9]+", "012abc0123", { 3, 3, 3 }, .OK },
	
	// meta inside classes
	{ "[\\w]+", "   1234   ", { 3, 3, 4 }, .OK },
	{ "[\\s]+", "123    123", { 3, 3, 4 }, .OK },

	// character ranges
	{ "[a-z]+", "abcdef", { 0, 0, 6 }, .OK },
	{ "[a-z]+", "abcdefABC", { 0, 0, 6 }, .OK },
	{ "[A-Z]+", "ABCDEFabc", { 0, 0, 6 }, .OK },
	{ "[A-Z]+", "abcDEFabc", { 3, 3, 3 }, .OK },
	{ "[0-9]+", "abc012abc", { 3, 3, 3 }, .OK },
	
	// multiple character ranges
	{ "[a-zA-Z]+", "abcDEFabc", { 0, 0, 9 }, .OK },
	{ "[a-cA-C]+", "abcDEFabc", { 0, 0, 3 }, .OK },
	{ "[a-cA-C]+", "___DEFabc", { 6, 6, 3 }, .OK },
	{ "[d-fD-F]+", "abcDEFabc", { 3, 3, 3 }, .OK },
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

	// begin + end
	{ "^testing$", "testing", { 0, 0, 7 }, .OK },
	{ "^testing this$", "testing", {}, .No_Match },
	{ "^testing$", "abc testing", {}, .No_Match },
	{ "^testing$", "testing abc", {}, .No_Match },

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

Case_Insensitive_Cases := [?]Test_Entry {
	{ "test", "teSt", { 0, 0, 4 }, .OK },
	{ "hello world", "Hello World", { 0, 0, 11 }, .OK },
}

TINY1_Cases := [?]Test_Entry {
  { "\\d", "5", { 0, 0, 1 }, .OK },
  { "\\w+", "hej", { 0, 0, 3 }, .OK },
  { "\\s", "\t \n",  { 0, 0, 1 }, .OK },
  { "\\S", "\t \n", { 0, 0, 0 }, .No_Match },
  { "[\\s]", "\t \n", { 0, 0, 1 }, .OK },
  { "[\\S]", "\t \n", { 0, 0, 0 }, .No_Match },
  { "\\D", "5", { 0, 0, 0 }, .No_Match },
  { "\\W+", "hej", { 0, 0, 0 }, .No_Match },
  { "[0-9]+", "12345", { 0, 0, 5 }, .OK },
  { "\\D", "hej", { 0, 0, 1 }, .OK },
  { "\\d", "hej", { 0, 0, 0 }, .No_Match },
  { "[^\\w]", "\\", { 0, 0, 1 }, .OK },
  { "[\\W]", "\\", { 0, 0, 1 }, .OK },
  { "[\\w]", "\\", { 0, 0, 0 }, .No_Match },
  { "[^\\d]", "d", { 0, 0, 1 }, .OK },
  { "[\\d]", "d", { 0, 0, 0 }, .No_Match },
  { "[^\\D]", "d", { 0, 0, 0 }, .No_Match },
  { "[\\D]", "d", { 0, 0, 1 }, .OK },
  { "^.*\\\\.*$", "c:\\Tools", { 0, 0, 8 }, .OK },
  { "^[\\+-]*[\\d]+$",  "+27", { 0, 0, 3 }, .OK },
  { "[abc]", "1c2", { 1, 1, 1 }, .OK },
  { "[abc]", "1C2", { 0, 0, 0 }, .No_Match },
  { "[1-5]+", "0123456789", { 1, 1, 5 }, .OK },
  { "[.2]", "1C2", { 2, 2, 1 }, .OK },
  { "a*$", "Xaa", { 1, 1, 2 }, .OK },
  { "[a-h]+", "abcdefghxxx",  { 0, 0, 8 }, .OK },
  { "[a-h]+", "ABCDEFGH", { 0, 0, 0 }, .No_Match },
  { "[A-H]+", "ABCDEFGH", { 0, 0, 8 }, .OK },
  { "[A-H]+", "abcdefgh", { 0, 0, 0 }, .No_Match },
  { "[^\\s]+", "abc def", { 0, 0, 3 }, .OK },
  { "[^fc]+", "abc def", { 0, 0, 2 }, .OK },
  { "[^d\\sf]+", "abc def", { 0, 0, 3 }, .OK },
  { "\n", "abc\ndef", { 3, 3, 1 }, .OK },
  { "b.\\s*\n", "aa\r\nbb\r\ncc\r\n\r\n",{ 4, 4, 4 }, .OK },
  { ".*c", "abcabc", { 0, 0, 6 }, .OK },
  { ".+c", "abcabc", { 0, 0, 6 }, .OK },
  { "[b-z].*", "ab", { 1, 1, 1 }, .OK },
  { "b[k-z]*", "ab", { 1, 1, 1 }, .OK },
  { "[0-9]", "  - ", { 0, 0, 0 }, .No_Match },
  { "[^0-9]", "  - ", { 0, 0, 1 }, .OK },
  // { "0|", "0|", { 0, 0, 2 }, .OK }, // unsupported
  { "0|", "0|", {}, .Operation_Unsupported },
  { "\\d\\d:\\d\\d:\\d\\d", "0s:00:00", { 0, 0, 0 }, .No_Match },
  { "\\d\\d:\\d\\d:\\d\\d", "000:00", { 0, 0, 0 }, .No_Match },
  { "\\d\\d:\\d\\d:\\d\\d", "00:0000", { 0, 0, 0 }, .No_Match },
  { "\\d\\d:\\d\\d:\\d\\d", "100:0:00", { 0, 0, 0 }, .No_Match },
  { "\\d\\d:\\d\\d:\\d\\d", "00:100:00", { 0, 0, 0 }, .No_Match },
  { "\\d\\d:\\d\\d:\\d\\d", "0:00:100", { 0, 0, 0 }, .No_Match },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "0:0:0",            { 0, 0, 5 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "0:00:0",           { 0, 0, 6 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "0:0:00",           { 0, 0, 5 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "00:0:0",           { 0, 0, 6 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "00:00:0",          { 0, 0, 7 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "00:0:00",          { 0, 0, 6 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "0:00:00",          { 0, 0, 6 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "00:00:00",         { 0, 0, 7 }, .OK },
  { "[Hh]ello [Ww]orld\\s*[!]?", "Hello world !",    { 0, 0, 12 }, .OK },
  { "[Hh]ello [Ww]orld\\s*[!]?", "hello world !",    { 0, 0, 12 }, .OK },
  { "[Hh]ello [Ww]orld\\s*[!]?", "Hello World !",    { 0, 0, 12 }, .OK },
  { "[Hh]ello [Ww]orld\\s*[!]?", "Hello world!   ",  { 0, 0, 11 }, .OK },
  { "[Hh]ello [Ww]orld\\s*[!]?", "Hello world  !",   { 0, 0, 13 }, .OK },
  { "[Hh]ello [Ww]orld\\s*[!]?", "hello World    !", { 0, 0, 15 }, .OK },
  { "\\d\\d?:\\d\\d?:\\d\\d?",   "a:0", { 0, 0, 0 }, .No_Match }, /* Failing test case reported in https://github.com/kokke/tiny-regex-c/issues/12 , .No_Match */
/*
  { "[^\\w][^-1-4]",     ")T",          { 0, 0, 2 }, .OK },
  { "[^\\w][^-1-4]",     ")^",          { 0, 0, 2 }, .OK },
  { "[^\\w][^-1-4]",     "*)",          { 0, 0, 2 }, .OK },
  { "[^\\w][^-1-4]",     "!.",          { 0, 0, 2 }, .OK },
  { "[^\\w][^-1-4]",     " x",          { 0, 0, 2 }, .OK },
  { "[^\\w][^-1-4]",     "$b",          { 0, 0, 2 }, .OK },
*/
  { ".?bar", "real_bar", { 4, 4, 4 }, .OK },
  { ".?bar", "real_foo", {}, .No_Match },
  { "X?Y", "Z", { 0, 0, 0 }, .No_Match },
  { "[a-z]+\nbreak", "blahblah\nbreak",  { 0, 0, 14 }, .OK },
  { "[a-z\\s]+\nbreak", "bla bla \nbreak",  { 0, 0, 14 }, .OK },
}

test_check_match_entry :: proc(
	t: ^testing.T,
	entry: Test_Entry,
	match: regex.Match,
	err: regex.Error,
	loc := #caller_location,
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
		loc,
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
test_utf8_specific_cases :: proc(t: ^testing.T) {
	for entry in UTF8_Specific_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack)
		test_check_match_entry(t, entry, match, err)
	}	
}

@test
test_case_insensitive_cases :: proc(t: ^testing.T) {
	for entry in Case_Insensitive_Cases {
		match, err := regex.match_string(&regexp, entry.pattern, entry.haystack, { .Case_Insensitive })
		test_check_match_entry(t, entry, match, err)
	}	
}

@test
test_larger_cases :: proc(t: ^testing.T) {
	pattern := "^[0-9]*$"
	haystack := `t1est
23
foo
bar
304958
bar`

	matches := make([dynamic]regex.Multiline_Match, 0, 32, context.temp_allocator)
	err := regex.match_multiline_string(&regexp, pattern, haystack, &matches)

	results := [?]regex.Multiline_Match {
		{ { 0, 0, 2 }, 1, },
		{ { 0, 0, 6 }, 4 },
	}

	for match, i in matches {
		expect(t, match == results[i], fmt.tprintf("Multi-line match failed %v != %v\n", match, results[i]))
	}
}

// from https://github.com/kokke/tiny-regex-c/blob/master/tests/test1.c
@test
test_tiny1_cases :: proc(t: ^testing.T) {
	for entry in TINY1_Cases {
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
		test_utf8_specific_cases(&t)
		test_case_insensitive_cases(&t)
		test_larger_cases(&t)
		test_tiny1_cases(&t)

		// {
		//   entry := Test_Entry { ".*c", "abcabc", { 0, 0, 6 }, .OK }
  // // { ".+c", "abcabc", { 0, 0, 6 }, .OK },

		// 	// entry := Test_Entry { "[a-z]+", "abcdef", { 0, 0, 6 }, .OK }
		// 	match, err := regex.match_string(&regexp, entry.pattern, entry.haystack, { .Case_Insensitive })
		// 	test_check_match_entry(&t, entry, match, err)
		// }
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
