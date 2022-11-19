package text_core_test_regex

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
			fmt.printf("[%v] %v\n", loc, message)
			return
		}
	}
	log     :: proc(t: ^testing.T, v: any, loc := #caller_location) {
		fmt.printf("[%v] ", loc)
		fmt.printf("log: %v\n", v)
	}
}

Test_Entry :: struct {
	pattern: string,
	haystack: string,
	pos, length: int,
	err: regex.Error,
}

ASCII_Cases := [?]Test_Entry {
	// empty patter/haystack
	{ "", "test", 0, 0, .No_Match },
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
	{ "[aabc", "a", 0, 0, .Pattern_Ended_Unexpectedly },
	// { "[aabc]", "H", 0, 1, .OK },

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
}

@test
test_ascii_cases :: proc(t: ^testing.T) {
	for entry in ASCII_Cases {
		pos, length, err := regex.match_string_ascii(entry.pattern, entry.haystack)
		// fmt.eprintln(entry, pos, length, err)
		expect(t, err == entry.err, "Regex: wrong error result")
		expect(t, pos == entry.pos, "Regex: wrong entry position found")
		expect(t, length == entry.length, "Regex: wrong entry length found")
	}
}

main :: proc() {
	using fmt

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	t: testing.T
	test_ascii_cases(&t)

	if len(track.allocation_map) > 0 {
		println()
		for _, v in track.allocation_map {
			printf("%v Leaked %v bytes.\n", v.location, v.size)
		}
	}
}