package analysis

import "core:path/filepath"
import "core:slice"
import "core:strings"

symbol_less :: proc(a, b: Symbol) -> bool {
	if a.path != b.path {
		return strings.compare(a.path, b.path) < 0
	}
	if a.range.start.line != b.range.start.line {
		return a.range.start.line < b.range.start.line
	}
	if a.range.start.column != b.range.start.column {
		return a.range.start.column < b.range.start.column
	}
	return a.name < b.name
}

copy_symbols :: proc(values: []Symbol, allocator := context.allocator) -> []Symbol {
	result := make([]Symbol, len(values), allocator)
	copy(result, values)
	slice.sort_by(result, symbol_less)
	return result
}

outline :: proc(
	state: ^Analysis_Context,
	path: string,
	allocator := context.allocator,
) -> []Symbol {
	result := make([dynamic]Symbol, allocator)
	for symbol_id in state.symbols_by_path[path] {
		symbol := state.symbols[int(symbol_id)]
		if symbol.is_global {
			append(&result, symbol)
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

search :: proc(
	state: ^Analysis_Context,
	query: string,
	allocator := context.allocator,
) -> []Symbol {
	result := make([dynamic]Symbol, allocator)
	query_lower := strings.to_lower(query, context.temp_allocator)
	for _, symbol_ids in state.symbols_by_name {
		if len(symbol_ids) == 0 {
			continue
		}
		symbol := state.symbols[int(symbol_ids[0])]
		name_lower := strings.to_lower(symbol.name, context.temp_allocator)
		if !strings.contains(name_lower, query_lower) {
			continue
		}
		for symbol_id in symbol_ids {
			symbol = state.symbols[int(symbol_id)]
			if !symbol.is_global {
				continue
			}
			append(&result, symbol)
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

package_api :: proc(
	state: ^Analysis_Context,
	package_query: string,
	allocator := context.allocator,
) -> []Symbol {
	result := make([dynamic]Symbol, allocator)
	seen := make(map[Symbol_ID]bool, context.temp_allocator)
	for package_directory, symbol_ids in state.symbols_by_package {
		matches := package_directory == package_query
		if !matches {
			for file_id in state.files_by_package[package_directory] {
				if state.files[int(file_id)].package_name == package_query {
					matches = true
					break
				}
			}
		}
		if !matches { continue }
		for symbol_id in symbol_ids {
			symbol := state.symbols[int(symbol_id)]
			if symbol.is_global && !seen[symbol.id] {
				seen[symbol.id] = true
				append(&result, symbol)
			}
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

location_for_position :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> Location_Result {
	active_package := ""
	if file_id, found := state.files_by_path[path]; found {
		active_package = state.files[int(file_id)].package_name
	}
	visible_imports := imports_for_file(state, path, allocator)
	scope_chain := make([]string, 5, allocator)
	copy(scope_chain, []string{"lexical", "file", "package", "imports", "builtins"})
	if symbol, ok := symbol_at(state, path, line, column); ok {
		values := make([]Symbol, 1, allocator)
		values[0] = symbol^
		return Location_Result{resolution = .Exact, locations = values, active_package = active_package, visible_imports = visible_imports, scope_chain = scope_chain}
	}

	if occurrence, ok := occurrence_at(state, path, line, column); ok {
		values := visible_candidates(state, occurrence^, allocator)
		if len(values) == 1 {
			return Location_Result{resolution = .Exact, locations = values, active_package = active_package, visible_imports = visible_imports, scope_chain = scope_chain}
		}
		if len(values) > 1 {
			slice.sort_by(values[:], symbol_less)
			return Location_Result{
				resolution = .Ambiguous,
				locations = values,
				reason = "multiple visible declarations satisfy lexical and import resolution",
				next_action = "qualify the symbol with its package alias or inspect the competing declarations",
				active_package = active_package,
				visible_imports = visible_imports,
				scope_chain = scope_chain,
				analyzer_boundary = "overload and polymorphic specialization are not evaluated",
			}
		}
	}
	return Location_Result{
		resolution = .Unresolved,
		reason = "no declaration is visible through the indexed lexical, package, import, or builtin scopes",
		next_action = "inspect imports and run hw-odin check when conditional files or type inference may supply the declaration",
		active_package = active_package,
		visible_imports = visible_imports,
		scope_chain = scope_chain,
		analyzer_boundary = "conditional-file evaluation, overload resolution, polymorphic specialization, implicit selectors, and general using behavior are bounded",
	}
}

is_type_symbol :: proc(symbol: Symbol) -> bool {
	return symbol.kind == .Struct ||
	       symbol.kind == .Union ||
	       symbol.kind == .Enum
}

type_definition_for_position :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> Location_Result {
	symbol, ok := symbol_at(state, path, line, column)
	if !ok {
		return Location_Result{resolution = .Unresolved}
	}
	if is_type_symbol(symbol^) {
		values := make([]Symbol, 1, allocator)
		values[0] = symbol^
		return Location_Result{resolution = .Exact, locations = values}
	}

	values := make([dynamic]Symbol, allocator)
	for candidate in state.symbols {
		if is_type_symbol(candidate) &&
		   candidate.package_directory == symbol.package_directory &&
		   !symbol_is_builtin(state, candidate) &&
		   contains_identifier(symbol.detail, candidate.name) {
			append(&values, candidate)
		}
	}
	if len(values) == 0 {
		for candidate in state.symbols {
			if !is_type_symbol(candidate) ||
			   symbol_is_builtin(state, candidate) {
				continue
			}
			for import_value in state.imports {
				qualified_name := strings.join(
					{import_value.alias, ".", candidate.name},
					"",
					context.temp_allocator,
				)
				if import_value.path == symbol.path &&
				   !import_value.is_using &&
				   import_exposes_symbol(state, import_value, candidate) &&
				   strings.contains(symbol.detail, qualified_name) {
					append(&values, candidate)
					break
				}
			}
		}
	}
	if len(values) == 0 {
		for candidate in state.symbols {
			if !is_type_symbol(candidate) ||
			   symbol_is_builtin(state, candidate) ||
			   !contains_identifier(symbol.detail, candidate.name) {
				continue
			}
			for import_value in state.imports {
				if import_value.path == symbol.path &&
				   import_value.is_using &&
				   import_exposes_symbol(state, import_value, candidate) {
					append(&values, candidate)
					break
				}
			}
		}
	}
	if len(values) == 0 {
		for candidate in state.symbols {
			if symbol_is_builtin(state, candidate) &&
			   contains_identifier(symbol.detail, candidate.name) {
				append(&values, candidate)
			}
		}
	}
	if len(values) == 1 {
		return Location_Result{resolution = .Exact, locations = values[:]}
	}
	if len(values) > 1 {
		slice.sort_by(values[:], symbol_less)
		return Location_Result{resolution = .Ambiguous, locations = values[:]}
	}
	return Location_Result{resolution = .Unresolved}
}

inspect :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> Inspect_Result {
	location := location_for_position(state, path, line, column, allocator)
	type_location := type_definition_for_position(
		state,
		path,
		line,
		column,
		allocator,
	)
	reference_count := 0
	if location.resolution == .Exact && len(location.locations) == 1 {
		id := location.locations[0].id
		reference_count = len(state.occurrences_by_symbol[id])
	}
	return Inspect_Result {
		resolution = location.resolution,
		symbols = location.locations,
		type_definitions = type_location.locations,
		reference_count = reference_count,
		explanation = location,
	}
}

references :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> []Occurrence {
	symbol, ok := symbol_at(state, path, line, column)
	if !ok {
		return nil
	}
	result := make([dynamic]Occurrence, allocator)
	for occurrence_index in state.occurrences_by_symbol[symbol.id] {
		append(&result, state.occurrences[occurrence_index])
	}
	slice.sort_by(
		result[:],
		proc(a, b: Occurrence) -> bool {
			if a.path != b.path {
				return strings.compare(a.path, b.path) < 0
			}
			return a.range.start.offset < b.range.start.offset
		},
	)
	return result[:]
}

rename_plan :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	new_name: string,
	allocator := context.allocator,
) -> []Text_Edit {
	found := references(state, path, line, column, context.temp_allocator)
	result := make([]Text_Edit, len(found), allocator)
	for occurrence, index in found {
		result[index] = Text_Edit {
			path = occurrence.path,
			range = occurrence.range,
			new_text = strings.clone(new_name, allocator),
		}
	}
	return result
}

valid_identifier :: proc(value: string) -> bool {
	if len(value) == 0 {
		return false
	}
	first := value[0]
	if !(first == '_' ||
	     first >= 'a' && first <= 'z' ||
	     first >= 'A' && first <= 'Z') {
		return false
	}
	for byte in transmute([]byte)value[1:] {
		if !is_identifier_byte(byte) {
			return false
		}
	}
	return true
}

rename_is_safe :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	new_name: string,
) -> bool {
	if !valid_identifier(new_name) {
		return false
	}
	target, ok := symbol_at(state, path, line, column)
	if !ok || target.name == new_name {
		return ok
	}
	for symbol in state.symbols {
		if symbol.id == target.id || symbol.name != new_name {
			continue
		}
		if target.is_global &&
		   symbol.is_global &&
		   symbol.package_directory == target.package_directory {
			return false
		}
		if !target.is_global &&
		   !symbol.is_global &&
		   symbol.path == target.path {
			return false
		}
	}
	return true
}

callers :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> []Symbol {
	target, ok := symbol_at(state, path, line, column)
	if !ok {
		return nil
	}
	seen := make(map[Symbol_ID]bool, context.temp_allocator)
	result := make([dynamic]Symbol, allocator)
	for occurrence_index in state.occurrences_by_symbol[target.id] {
		occurrence := state.occurrences[occurrence_index]
		if occurrence.symbol != target.id || !occurrence.is_call {
			continue
		}
		caller, found := enclosing_procedure(state, occurrence.path, occurrence.range.start.offset)
		if found && !seen[caller.id] {
			seen[caller.id] = true
			append(&result, caller^)
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

callees :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> []Symbol {
	procedure, ok := symbol_at(state, path, line, column)
	if !ok || procedure.kind != .Procedure {
		return nil
	}
	seen := make(map[Symbol_ID]bool, context.temp_allocator)
	result := make([dynamic]Symbol, allocator)
	for occurrence in state.occurrences {
		if occurrence.path != procedure.path ||
		   !occurrence.is_call ||
		   occurrence.range.start.offset < procedure.extent.start.offset ||
		   occurrence.range.start.offset >= procedure.extent.end.offset ||
		   int(occurrence.symbol) < 0 {
			continue
		}
		if !seen[occurrence.symbol] {
			seen[occurrence.symbol] = true
			append(&result, state.symbols[int(occurrence.symbol)])
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

imports_for_file :: proc(
	state: ^Analysis_Context,
	path: string,
	allocator := context.allocator,
) -> []Import {
	result := make([dynamic]Import, allocator)
	if path == "" {
		append(&result, ..state.imports[:])
		return result[:]
	}
	if import_indices, found := state.imports_by_path[path]; found {
		for import_index in import_indices {
			append(&result, state.imports[import_index])
		}
	}
	return result[:]
}

append_completion_candidate :: proc(
	result: ^[dynamic]Symbol,
	seen: ^map[string]bool,
	symbol: Symbol,
	prefix: string,
) {
	if seen^[symbol.name] ||
	   prefix != "" && !strings.has_prefix(symbol.name, prefix) {
		return
	}
	seen^[symbol.name] = true
	append(result, symbol)
}

completion :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	allocator := context.allocator,
) -> []Symbol {
	prefix := ""
	selector_base := ""
	file_directory := ""
	position_offset := max(int)
	file_found := false
	for file in state.files {
		if file.relative_path != path || line <= 0 {
			continue
		}
		file_found = true
		file_directory = file.package_directory
		position_offset = offset_for_position(file.source, line, column)
		start := position_offset
		for start > 0 {
			value := file.source[start - 1]
			if !(value == '_' || value >= 'a' && value <= 'z' ||
			     value >= 'A' && value <= 'Z' || value >= '0' && value <= '9') {
				break
			}
			start -= 1
		}
		prefix = file.source[start:position_offset]
		if start > 0 && file.source[start - 1] == '.' {
			base_end := start - 1
			base_start := base_end
			for base_start > 0 && is_identifier_byte(file.source[base_start - 1]) {
				base_start -= 1
			}
			selector_base = file.source[base_start:base_end]
		}
		break
	}
	if !file_found {
		return nil
	}
	result := make([dynamic]Symbol, allocator)
	seen := make(map[string]bool, context.temp_allocator)
	if selector_base != "" {
		for import_value in state.imports {
			if import_value.path != path || import_value.alias != selector_base {
				continue
			}
			for file in state.files {
				if filepath.dir(file.path) != import_value.resolved_path {
					continue
				}
				for symbol in state.symbols {
					if symbol.path == file.relative_path &&
					   symbol.is_global &&
					   strings.has_prefix(symbol.name, prefix) &&
					   !seen[symbol.name] {
						seen[symbol.name] = true
						append(&result, symbol)
					}
				}
			}
		}

		base_symbol := Symbol_ID(-1)
		best_offset := -1
		for occurrence in state.occurrences {
			if occurrence.path == path &&
			   occurrence.name == selector_base &&
			   occurrence.range.start.offset < position_offset &&
			   occurrence.range.start.offset > best_offset &&
			   int(occurrence.symbol) >= 0 {
				base_symbol = occurrence.symbol
				best_offset = occurrence.range.start.offset
			}
		}
		if int(base_symbol) >= 0 {
			base := state.symbols[int(base_symbol)]
			for type_symbol in state.symbols {
				if !is_type_symbol(type_symbol) ||
				   type_symbol.package_directory != file_directory ||
				   !contains_identifier(base.detail, type_symbol.name) {
					continue
				}
				for field in state.symbols {
					if field.kind == .Field &&
					   field.owner_type == type_symbol.name &&
					   field.package_directory == type_symbol.package_directory &&
					   strings.has_prefix(field.name, prefix) &&
					   !seen[field.name] {
						seen[field.name] = true
						append(&result, field)
					}
				}
			}
		}
		slice.sort_by(result[:], symbol_less)
		return result[:]
	}

	if procedure, found := enclosing_procedure(
		state,
		path,
		position_offset,
	); found {
		for index := len(state.symbols) - 1; index >= 0; index -= 1 {
			symbol := state.symbols[index]
			if symbol.is_global ||
			   symbol.kind == .Field ||
			   symbol.path != path ||
			   symbol.range.start.offset < procedure.extent.start.offset ||
			   symbol.range.start.offset > position_offset {
				continue
			}
			append_completion_candidate(&result, &seen, symbol, prefix)
		}
	}

	for symbol in state.symbols {
		if !symbol.is_global ||
		   symbol_is_builtin(state, symbol) ||
		   symbol.package_directory != file_directory {
			continue
		}
		append_completion_candidate(&result, &seen, symbol, prefix)
	}

	for import_value in state.imports {
		if import_value.path != path || !import_value.is_using {
			continue
		}
		for file in state.files {
			if filepath.dir(file.path) != import_value.resolved_path {
				continue
			}
			for symbol in state.symbols {
				if symbol.path == file.relative_path &&
				   symbol.is_global &&
				   !symbol_is_builtin(state, symbol) {
					append_completion_candidate(&result, &seen, symbol, prefix)
				}
			}
		}
	}

	for symbol in state.symbols {
		if symbol.is_global && symbol_is_builtin(state, symbol) {
			append_completion_candidate(&result, &seen, symbol, prefix)
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

offset_for_position :: proc(source: string, line, column: int) -> int {
	current_line := 1
	offset := 0
	for offset < len(source) && current_line < line {
		if source[offset] == '\n' {
			current_line += 1
		}
		offset += 1
	}
	return clamp(offset + max(column - 1, 0), 0, len(source))
}
