package workflow

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "code_analysis:analysis"

HINTED_DIAGNOSTICS_MAX :: 12
SUGGESTIONS_MAX :: 4
SEARCH_TOKENS_MAX :: 4
CANDIDATES_MAX :: 4000
DECLARATION_LINES_MAX :: 30
SHOWN_SYMBOLS_MAX :: 4
SHOWN_LINES_MAX :: 160

Query :: proc(root, command: string, arguments: ..string) -> (payload: string, ok: bool)
USES_SHOWN_MAX :: 80

Scored_Symbol :: struct {
	symbol: analysis.Symbol,
	score:  int,
}

query_symbols :: proc(query: Query, root, command, argument: string) -> []analysis.Symbol {
	payload, ok := query(root, command, argument)
	if !ok {
		return nil
	}
	symbols: []analysis.Symbol
	if json.unmarshal_string(payload, &symbols, allocator = context.temp_allocator) != nil {
		return nil
	}
	return symbols
}

quoted_values :: proc(message: string) -> []string {
	values := make([dynamic]string, context.temp_allocator)
	remaining := message
	for {
		start := strings.index_byte(remaining, '\'')
		if start < 0 {
			break
		}
		end := strings.index_byte(remaining[start + 1:], '\'')
		if end < 0 {
			break
		}
		append(&values, remaining[start + 1:start + 1 + end])
		remaining = remaining[start + end + 2:]
	}
	return values[:]
}

last_segment :: proc(value: string) -> string {
	dot := strings.last_index_byte(value, '.')
	return dot < 0 ? value : value[dot + 1:]
}

similarity :: proc(wanted, candidate: string) -> (score: int, plausible: bool) {
	wanted_lower := strings.to_lower(wanted, context.temp_allocator)
	candidate_lower := strings.to_lower(candidate, context.temp_allocator)
	shared := 0
	remaining := wanted_lower
	for token in strings.split_iterator(&remaining, "_") {
		if len(token) >= 3 && strings.contains(candidate_lower, token) {
			shared += len(token)
		}
	}
	distance := strings.levenshtein_distance(wanted_lower, candidate_lower, context.temp_allocator)
	related := 3 * shared >= 2 * len(wanted) && len(candidate) <= 2 * len(wanted) + 4
	plausible = distance <= max(2, len(wanted) / 3) || related
	return 3 * shared - 2 * distance, plausible
}

closest :: proc(wanted: string, symbols: []analysis.Symbol) -> []Scored_Symbol {
	scored := make([dynamic]Scored_Symbol, context.temp_allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for symbol, index in symbols {
		if index >= CANDIDATES_MAX {
			break
		}
		key := fmt.tprintf("%s.%s", symbol.package_name, symbol.name)
		if key in seen || symbol.name == wanted && symbol.kind == .Import {
			continue
		}
		seen[key] = true
		score, plausible := similarity(wanted, symbol.name)
		if plausible {
			append(&scored, Scored_Symbol{symbol = symbol, score = score})
		}
	}
	slice.sort_by(scored[:], proc(a, b: Scored_Symbol) -> bool {
		return a.score > b.score || (a.score == b.score && a.symbol.name < b.symbol.name)
	})
	return scored[:min(len(scored), SUGGESTIONS_MAX)]
}

suggestion_text :: proc(root: string, matches: []Scored_Symbol) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for match, index in matches {
		if index > 0 {
			strings.write_string(&builder, ", ")
		}
		symbol := match.symbol
		fmt.sbprintf(
			&builder, "%s.%s (%s:%d)", symbol.package_name, symbol.name,
			display_path(root, symbol.path), symbol.range.start.line,
		)
	}
	return strings.to_string(builder)
}

similar_global :: proc(query: Query, root, name: string) -> string {
	candidates := make([dynamic]analysis.Symbol, context.temp_allocator)
	append(&candidates, ..query_symbols(query, root, "search", name))
	remaining := name
	tokens := 0
	for token in strings.split_iterator(&remaining, "_") {
		if len(token) < 4 || tokens >= SEARCH_TOKENS_MAX {
			continue
		}
		tokens += 1
		append(&candidates, ..query_symbols(query, root, "search", token))
	}
	matches := closest(name, candidates[:])
	if len(matches) == 0 {
		return ""
	}
	return fmt.tprintf("similar declarations: %s", suggestion_text(root, matches))
}

similar_member :: proc(query: Query, root, file, alias, name: string) -> string {
	payload, ok := query(root, "imports", file)
	if !ok {
		return ""
	}
	imports: []analysis.Import
	if json.unmarshal_string(payload, &imports, allocator = context.temp_allocator) != nil {
		return ""
	}
	for entry in imports {
		imported := entry.alias != "" ? entry.alias : entry.package_name
		if imported != alias && last_segment_path(entry.import_path) != alias {
			continue
		}
		matches := closest(name, query_symbols(query, root, "package-api", entry.resolved_path))
		if len(matches) > 0 {
			return fmt.tprintf("closest in %s: %s", alias, suggestion_text(root, matches))
		}
	}
	return ""
}

last_segment_path :: proc(import_path: string) -> string {
	start := max(strings.last_index_byte(import_path, '/'), strings.last_index_byte(import_path, ':'))
	return import_path[start + 1:]
}

declaration_text :: proc(root: string, symbol: analysis.Symbol, limit: int) -> string {
	text, found := read_text(absolute(root, symbol.path))
	if !found {
		return ""
	}
	lines := strings.split_lines(text, context.temp_allocator)
	first := symbol.extent.start.line
	if first <= 0 || first > len(lines) {
		first = symbol.range.start.line
	}
	last := max(symbol.extent.end.line, first)
	if first <= 0 || first > len(lines) {
		return ""
	}
	builder := strings.builder_make(context.temp_allocator)
	for number in first ..= min(last, len(lines)) {
		if number - first >= limit {
			fmt.sbprintf(&builder, "\n      ... %d more lines", last - number + 1)
			break
		}
		fmt.sbprintf(&builder, "\n      %d  %s", number, lines[number - 1])
	}
	return strings.to_string(builder)
}

named_declarations :: proc(query: Query, root, name: string) -> []analysis.Symbol {
	package_name := ""
	wanted := name
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		package_name = name[:dot]
		wanted = name[dot + 1:]
	}
	result := make([dynamic]analysis.Symbol, context.temp_allocator)
	for symbol in query_symbols(query, root, "search", wanted) {
		if symbol.name != wanted || symbol.kind == .Import || symbol.kind == .Package {
			continue
		}
		if package_name != "" && symbol.package_name != package_name &&
		   !strings.has_suffix(symbol.package_directory, package_name) {
			continue
		}
		append(&result, symbol)
	}
	return result[:]
}

callee_at :: proc(root: string, diagnostic: Compiler_Diagnostic) -> string {
	text, found := read_text(absolute(root, diagnostic.path))
	if !found || diagnostic.line <= 0 {
		return ""
	}
	lines := strings.split_lines(text, context.temp_allocator)
	if diagnostic.line > len(lines) {
		return ""
	}
	line := lines[diagnostic.line - 1]
	start := clamp(diagnostic.column - 1, 0, len(line))
	end := start
	for end < len(line) {
		switch line[end] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.':
			end += 1
			continue
		}
		break
	}
	if end >= len(line) || line[end] != '(' {
		return ""
	}
	return line[start:end]
}

diagnostic_hint :: proc(query: Query, root: string, diagnostic: Compiler_Diagnostic) -> string {
	message := diagnostic.message
	values := quoted_values(message)
	undeclared :: "Undeclared name: "
	if strings.has_prefix(message, undeclared) {
		name := strings.trim_space(message[len(undeclared):])
		return similar_global(query, root, last_segment(name))
	}
	if strings.contains(message, "is not declared by") && len(values) >= 2 {
		return similar_member(query, root, diagnostic.path, values[1], last_segment(values[0]))
	}
	if strings.contains(message, "has no field") && len(values) >= 3 {
		type_name := last_segment(strings.trim_left(values[1], "^"))
		declarations := named_declarations(query, root, type_name)
		if len(declarations) == 1 {
			return fmt.tprintf(
				"%s is declared at %s:%s", type_name, display_path(root, declarations[0].path),
				declaration_text(root, declarations[0], DECLARATION_LINES_MAX),
			)
		}
		return ""
	}
	argument_errors := [?]string{
		"is missing in procedure call", "Too many arguments", "Too few arguments",
		"in a procedure argument", "No parameter named",
	}
	for marker in argument_errors {
		if !strings.contains(message, marker) {
			continue
		}
		callee := callee_at(root, diagnostic)
		if callee == "" {
			return ""
		}
		declarations := named_declarations(query, root, last_segment(callee))
		if len(declarations) == 0 || len(declarations) > SHOWN_SYMBOLS_MAX {
			return ""
		}
		builder := strings.builder_make(context.temp_allocator)
		for symbol in declarations {
			detail, _ := strings.replace_all(symbol.detail, "\n", " ", context.temp_allocator)
			if brace := strings.index_byte(detail, '{'); brace > 0 {
				detail = detail[:brace]
			}
			fmt.sbprintf(
				&builder, "%s%s:%d  %s", strings.builder_len(builder) > 0 ? "; " : "signature: ",
				display_path(root, symbol.path), symbol.range.start.line,
				strings.trim_space(detail),
			)
		}
		return strings.to_string(builder)
	}
	return ""
}

add_hints :: proc(query: Query, report: ^Check_Report) {
	hinted := 0
	seen := make(map[string]string, allocator = context.temp_allocator)
	for &step in report.steps {
		for &diagnostic in step.output.diagnostics {
			if diagnostic.warning || hinted >= HINTED_DIAGNOSTICS_MAX {
				continue
			}
			if diagnostic.message in seen {
				continue
			}
			diagnostic.hint = diagnostic_hint(query, report.root, diagnostic)
			seen[diagnostic.message] = diagnostic.hint
			if diagnostic.hint != "" {
				hinted += 1
			}
		}
	}
}

uses :: proc(query: Query, root, name: string) -> (text: string, found: int, ok: bool) {
	declarations := named_declarations(query, root, name)
	if len(declarations) == 0 {
		suggestion := similar_global(query, root, last_segment(name))
		return fmt.tprintf("uses: %q is not declared in the indexed sources. %s", name, suggestion), 0, false
	}
	builder := strings.builder_make(context.temp_allocator)
	files := make(map[string][]string, allocator = context.temp_allocator)
	shown := 0
	for symbol, index in declarations {
		if index >= SHOWN_SYMBOLS_MAX {
			fmt.sbprintfln(
				&builder, "%d more declarations; qualify the name as PACKAGE.NAME",
				len(declarations) - index,
			)
			break
		}
		payload, answered := query(
			root, "references", symbol.path,
			fmt.tprint(symbol.range.start.line), fmt.tprint(symbol.range.start.column),
		)
		occurrences: []analysis.Occurrence
		if !answered || json.unmarshal_string(payload, &occurrences, allocator = context.temp_allocator) != nil {
			return fmt.tprintf("uses: the analyzer did not answer for %s", name), found, false
		}
		list := make([dynamic]analysis.Occurrence, context.temp_allocator)
		for occurrence in occurrences {
			if occurrence.path == symbol.path && occurrence.range.start.line == symbol.range.start.line {
				continue
			}
			append(&list, occurrence)
		}
		found += len(list)
		fmt.sbprintfln(
			&builder, "%s.%s %v %s:%d: %d uses", symbol.package_name, symbol.name, symbol.kind,
			display_path(root, symbol.path), symbol.range.start.line, len(list),
		)
		for occurrence in list {
			if shown >= USES_SHOWN_MAX {
				break
			}
			shown += 1
			lines, cached := files[occurrence.path]
			if !cached {
				source, _ := read_text(occurrence.path)
				lines = strings.split_lines(source, context.temp_allocator)
				files[occurrence.path] = lines
			}
			line := occurrence.range.start.line
			text := line >= 1 && line <= len(lines) ? strings.trim_space(lines[line - 1]) : ""
			fmt.sbprintfln(&builder, "  %s:%d  %s", display_path(root, occurrence.path), line, text)
		}
	}
	if found > shown {
		fmt.sbprintfln(&builder, "%d more uses are not listed", found - shown)
	}
	strings.write_string(
		&builder,
		"uses come from the analyzer's index; dynamic or ambiguous references can be missing\n",
	)
	return strings.to_string(builder), found, true
}

show :: proc(query: Query, root, name: string) -> (text: string, ok: bool) {
	declarations := named_declarations(query, root, name)
	builder := strings.builder_make(context.temp_allocator)
	if len(declarations) == 0 {
		suggestion := similar_global(query, root, last_segment(name))
		return fmt.tprintf("show: %q is not declared in the indexed sources. %s", name, suggestion), false
	}
	for symbol, index in declarations {
		if index >= SHOWN_SYMBOLS_MAX {
			fmt.sbprintfln(
				&builder, "%d more declarations; qualify the name as PACKAGE.NAME",
				len(declarations) - index,
			)
			break
		}
		fmt.sbprintfln(
			&builder, "%s.%s %v %s:%d%s", symbol.package_name, symbol.name, symbol.kind,
			display_path(root, symbol.path), symbol.range.start.line,
			declaration_text(root, symbol, SHOWN_LINES_MAX),
		)
	}
	return strings.to_string(builder), true
}
