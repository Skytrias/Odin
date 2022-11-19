/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

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

