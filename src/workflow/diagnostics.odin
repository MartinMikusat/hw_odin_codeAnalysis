package workflow

import "core:fmt"
import "core:strconv"
import "core:strings"

DETAIL_LINES_MAX :: 6

Compiler_Diagnostic :: struct {
	path:     string,
	line:     int,
	column:   int,
	warning:  bool,
	message:  string,
	details:  []string,
	hint:     string,
	repeated: int,
}

Compiler_Output :: struct {
	diagnostics: []Compiler_Diagnostic,
	other:       []string,
}

parse_diagnostic_line :: proc(line: string) -> (diagnostic: Compiler_Diagnostic, ok: bool) {
	marker := strings.index(line, ".odin(")
	if marker < 0 {
		return
	}
	open := marker + len(".odin")
	close := strings.index_byte(line[open:], ')')
	if close < 0 {
		return
	}
	close += open
	position := line[open + 1:close]
	separator := strings.index_byte(position, ':')
	if separator < 0 {
		return
	}
	line_number := strconv.parse_int(position[:separator], 10) or_return
	column := strconv.parse_int(position[separator + 1:], 10) or_return
	rest := strings.trim_left_space(line[close + 1:])
	prefixes := [?]string{"Error:", "Syntax Error:", "Warning:", "Syntax Warning:"}
	for prefix, index in prefixes {
		if strings.has_prefix(rest, prefix) {
			diagnostic.path = strings.trim_left_space(line[:open])
			diagnostic.line = line_number
			diagnostic.column = column
			diagnostic.warning = index >= 2
			diagnostic.message = strings.trim_space(rest[len(prefix):])
			return diagnostic, true
		}
	}
	return
}

is_caret_line :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 {
		return true
	}
	for character in trimmed {
		if character != '^' && character != '~' {
			return false
		}
	}
	return true
}

is_toolchain_error :: proc(line: string) -> bool {
	if strings.has_prefix(line, "ld: ") {
		return !strings.has_prefix(line, "ld: warning")
	}
	markers := [?]string{
		"clang: error:", "Undefined symbols", ": error: ", ": fatal error: ",
		"Dependency check failed", "Unknown flag:", "Assertion Failure:", "LLVM ERROR",
	}
	for marker in markers {
		if strings.contains(line, marker) {
			return true
		}
	}
	return false
}

parse_compiler_output :: proc(output: string) -> Compiler_Output {
	diagnostics := make([dynamic]Compiler_Diagnostic, context.temp_allocator)
	other := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]int, allocator = context.temp_allocator)
	lines := strings.split_lines(output, context.temp_allocator)
	for index := 0; index < len(lines); index += 1 {
		diagnostic, parsed := parse_diagnostic_line(lines[index])
		if !parsed {
			if is_toolchain_error(lines[index]) {
				append(&other, lines[index])
			}
			continue
		}
		details := make([dynamic]string, context.temp_allocator)
		for index + 1 < len(lines) {
			next := lines[index + 1]
			if len(next) == 0 || (next[0] != '\t' && next[0] != ' ') {
				break
			}
			index += 1
			if !is_caret_line(next) && len(details) < DETAIL_LINES_MAX {
				append(&details, strings.trim_space(next))
			}
		}
		diagnostic.details = details[:]
		diagnostic.repeated = 1
		key := fmt.tprintf(
			"%s:%d:%d:%s", diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message,
		)
		if previous, found := seen[key]; found {
			diagnostics[previous].repeated += 1
			continue
		}
		seen[key] = len(diagnostics)
		append(&diagnostics, diagnostic)
	}
	return {diagnostics = diagnostics[:], other = other[:]}
}
