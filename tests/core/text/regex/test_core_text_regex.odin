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
	offset, length: int,
	err: regex.Error,
}

ASCII_Simple_Cases := [?]Test_Entry {
	// empty patter/haystack
	{ "", "test", 0, 0, .Pattern_Empty },
	{ "test", "", 0, 0, .No_Match },

	// simple
	{ "foobar", "foobar", 0, 6, .OK },
	{ "foobar", "fooba", 0, 0, .No_Match },
	
	// short
	{ "2", "2", 0, 1, .OK },
	{ "ö", "ö", 0, 2, .OK }, // Hmm?
	{ "1", "1", 0, 1, .OK },
	
	// character classes
	{ "[Hh]ello [Ww]orld", "Hello World", 0, 11, .OK },
	{ "[Hh]ello [Ww]orld", "Hello world", 0, 11, .OK },
	{ "[Hh]ello [Ww]orld", "hello world", 0, 11, .OK },
	{ "[Hh]ello [Ww]orld", "hello World", 0, 11, .OK },
	{ "[aabc", "a", 0, 0, .Pattern_Ended_Unexpectedly }, // check early ending
	{ "[", "a", 0, 0, .Pattern_Ended_Unexpectedly }, // check early ending
	{ "[\\\\]", "\\", 0, 1, .OK }, // check early ending

	// escaped chars
	{ "\\", "\\", 0, 0, .Pattern_Ended_Unexpectedly },
	{ "\\\\", "\\\\", 0, 1, .OK },
	
	// digit class
	{ "\\d", "1", 0, 1, .OK },
	{ "\\d", "a", 0, 0, .No_Match },
	{ "\\d\\d", "12", 0, 2, .OK },

	// non-digit class
	{ "\\D", "a", 0, 1, .OK },
	{ "\\D", "1", 0, 0, .No_Match },
	{ "\\D\\D\\D", "abc", 0, 3, .OK },

	// alpha class
	{ "\\w", "a", 0, 1, .OK },
	{ "\\w", "1", 0, 1, .OK },
	{ "\\w\\w\\w", "__A", 0, 3, .OK },

	// non-alpha class
	{ "\\W", "a", 0, 0, .No_Match },
	{ "\\W", "@", 0, 1, .OK },
	{ "\\W", "-", 0, 1, .OK },

	// whitespace class
	{ "\\s", " ", 0, 1, .OK },
	{ "\\s", "a", 0, 0, .No_Match },
	{ "\\s\\s\\s", "   ", 0, 3, .OK },

	// non-whitespace class
	{ "\\S", "a", 0, 1, .OK },
	{ "\\S", " ", 0, 0, .No_Match },
	{ "\\S\\S\\S", "abc", 0, 3, .OK },

	// inverse class
	{ "[^a]", "0", 0, 1, .OK },
	{ "[^a]", "a", 0, 0, .No_Match },
	{ "[^a]", "A", 0, 1, .OK },
	{ "[^", "", 0, 0, .Pattern_Ended_Unexpectedly }, // check early ending
}

ASCII_Meta_Cases := [?]Test_Entry {
	// begin
	{ "^test", "test", 0, 4, .OK },
	{ "test", "xtest", 1, 4, .OK },
	{ "^test", "xtest", 0, 0, .No_Match },
	{ "^", "test", 0, 0, .OK }, // TODO expected result?

	// end
	{ "$", "", 0, 0, .No_Match },
	{ "$", "test", 0, 0, .No_Match },
	{ "test$", "test", 0, 4, .OK },
	{ "test$", "abctest", 3, 4, .OK },

	// dot
	{ ".", "a", 0, 1, .OK },
	{ ".", "\n", 0, 0, .No_Match },
	{ ".", " ", 0, 1, .OK },
	{ "...", "abc", 0, 3, .OK },
	{ ".y.", "xyz", 0, 3, .OK },

	// star
	{ "s*", "expression", 0, 0, .OK },
	{ "s*", "expresion", 0, 0, .OK },
	{ "es*", "expreion", 0, 1, .OK }, // .Star error previously
	{ "es*", "xpreion", 3, 1, .OK },
	{ "tes*", "tetest", 0, 2, .OK },

	// plus 
	{ "es+", "expression", 4, 3, .OK },
	{ "es+", "expresion", 4, 2, .OK },
	{ "es+", "expresssssssion", 4, 8, .OK },
	{ "es+i", "expresssssssion", 4, 9, .OK },
	{ "es+i", "expression", 4, 4, .OK },
	{ "es+i", "expreion", 0, 0, .No_Match },

	// question mark
	{ "te?st", "test", 0, 4, .OK },
	{ "te?st", "tst", 0, 3, .OK },
	{ "te?s?t", "tt", 0, 2, .OK },
	{ "t??t", "tt", 0, 0, .No_Match },

	// branch
	{ "|", "test", 0, 0, .Operation_Unsupported }
}

@test
test_ascii_simple_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Simple_Cases {
		offset, length, err := regex.match_string_ascii(entry.pattern, entry.haystack)
		expect(t, offset == entry.offset && length == entry.length && err == entry.err, fmt.tprintf("Expected match result {{offset=%v, len=%v, res=%v}}, got {{offset=%v, len=%v, res=%v}}", entry.offset, entry.length, entry.err, offset, length, err))
	}
}

@test
test_ascii_meta_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Meta_Cases {
		offset, length, err := regex.match_string_ascii(entry.pattern, entry.haystack)
		expect(t, offset == entry.offset && length == entry.length && err == entry.err, fmt.tprintf("Expected match result {{offset=%v, len=%v, res=%v}}, got {{offset=%v, len=%v, res=%v}}", entry.offset, entry.length, entry.err, offset, length, err))
	}
}

main :: proc() {
	using fmt

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	t: testing.T
	test_ascii_simple_cases(&t)
	test_ascii_meta_cases(&t)

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
