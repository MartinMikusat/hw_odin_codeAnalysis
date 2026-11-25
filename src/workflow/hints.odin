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

query_symbols :: proc(query: Query, root, command: string, arguments: ..string) -> []analysis.Symbol {
	payload, ok := query(root, command, ..arguments)
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
	return query_symbols(query, root, "declarations", name)
}

qualified_name :: proc(symbol: analysis.Symbol) -> string {
	if symbol.kind == .Field && symbol.owner_type != "" {
		return fmt.tprintf("%s.%s.%s", symbol.package_name, symbol.owner_type, symbol.name)
	}
	return fmt.tprintf("%s.%s", symbol.package_name, symbol.name)
}

diagnostic_type_at :: proc(query: Query, root: string, diagnostic: Compiler_Diagnostic) -> []analysis.Symbol {
	payload, ok := query(
		root, "type-definition", absolute(root, diagnostic.path),
		fmt.tprint(diagnostic.line), fmt.tprint(diagnostic.column),
	)
	if !ok { return nil }
	location: analysis.Location_Result
	if json.unmarshal_string(payload, &location, allocator = context.temp_allocator) != nil {
		return nil
	}
	return location.locations
}

field_hint :: proc(query: Query, root: string, owners: []analysis.Symbol, missing: string) -> string {
	if len(owners) != 1 || owners[0].kind != .Struct {
		return ""
	}
	owner := owners[0]
	name := fmt.tprintf("%s.%s.*", owner.package_directory, owner.name)
	fields := make([dynamic]analysis.Symbol, context.temp_allocator)
	for field in named_declarations(query, root, name) {
		if field.path == owner.path &&
		   field.range.start.offset >= owner.extent.start.offset &&
		   field.range.start.offset < owner.extent.end.offset {
			append(&fields, field)
		}
	}
	base := fmt.tprintf("%s at %s:%d", qualified_name(owner), display_path(root, owner.path), owner.range.start.line)
	matches := closest(missing, fields[:])
	if len(matches) == 0 {
		return base
	}
	match := matches[0].symbol
	return fmt.tprintf(
		"%s has field %s: %s (%s:%d)", base, match.name, match.detail,
		display_path(root, match.path), match.range.start.line,
	)
}

diagnostic_expression_declarations :: proc(
	query: Query, root: string, diagnostic: Compiler_Diagnostic, expression: string,
) -> []analysis.Symbol {
	return query_symbols(
		query, root, "diagnostic-declarations", absolute(root, diagnostic.path),
		fmt.tprint(diagnostic.line), fmt.tprint(diagnostic.column), expression,
	)
}

signature_hint :: proc(root: string, declarations: []analysis.Symbol) -> string {
	if len(declarations) == 0 { return "" }
	builder := strings.builder_make(context.temp_allocator)
	for symbol, index in declarations[:min(len(declarations), SHOWN_SYMBOLS_MAX)] {
		detail, _ := strings.replace_all(symbol.detail, "\n", " ", context.temp_allocator)
		fmt.sbprintf(
			&builder, "%s%s:%d  %s %s",
			index == 0 ? "declaration: " : "\n          ",
			display_path(root, symbol.path), symbol.range.start.line,
			qualified_name(symbol), strings.trim_space(detail),
		)
	}
	if len(declarations) > SHOWN_SYMBOLS_MAX {
		fmt.sbprintf(&builder, "\n          %d more declarations", len(declarations) - SHOWN_SYMBOLS_MAX)
	}
	return strings.to_string(builder)
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
		owners := diagnostic_type_at(query, root, diagnostic)
		if len(owners) != 1 {
			type_name := strings.trim_left(values[1], "^")
			owners = named_declarations(query, root, type_name)
		}
		return field_hint(query, root, owners, values[2])
	}
	if strings.has_prefix(message, "Unknown field ") && len(values) > 0 {
		owners := diagnostic_expression_declarations(query, root, diagnostic, "literal")
		return field_hint(query, root, owners, values[0])
	}
	argument_errors := [?]string{
		"is missing in procedure call", "Too many arguments", "Too few arguments",
		"in a procedure argument", "No parameter named", "Cannot convert",
		"procedure group", "procedure call",
	}
	for marker in argument_errors {
		if strings.contains(message, marker) {
			declarations := diagnostic_expression_declarations(query, root, diagnostic, "call")
			return signature_hint(root, declarations)
		}
	}
	return ""
}

add_hints :: proc(query: Query, report: ^Check_Report) {
	hinted := 0
	seen := make(map[Diagnostic_Key]bool, allocator = context.temp_allocator)
	for &step in report.steps {
		for &diagnostic in step.output.diagnostics {
			if diagnostic.warning || hinted >= HINTED_DIAGNOSTICS_MAX {
				continue
			}
			key := diagnostic_key(diagnostic, report.root)
			if seen[key] { continue }
			seen[key] = true
			diagnostic.hint = diagnostic_hint(query, report.root, diagnostic)
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
	if len(declarations) > 1 {
		fmt.sbprintfln(&builder, "%q matches %d declarations", name, len(declarations))
	}
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
			if occurrence.path == symbol.path && occurrence.range.start.offset == symbol.range.start.offset {
				continue
			}
			append(&list, occurrence)
		}
		found += len(list)
		fmt.sbprintfln(
			&builder, "%s %v %s:%d: %d uses", qualified_name(symbol), symbol.kind,
			display_path(root, symbol.path), symbol.range.start.line, len(list),
		)
		for occurrence in list {
			if shown >= USES_SHOWN_MAX {
				break
			}
			shown += 1
			lines, cached := files[occurrence.path]
			if !cached {
				source, _ := read_text(absolute(root, occurrence.path))
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
	if len(declarations) > 1 {
		fmt.sbprintfln(&builder, "%q matches %d declarations", name, len(declarations))
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
			&builder, "%s %v %s:%d%s", qualified_name(symbol), symbol.kind,
			display_path(root, symbol.path), symbol.range.start.line,
			declaration_text(root, symbol, SHOWN_LINES_MAX),
		)
	}
	return strings.to_string(builder), true
}
