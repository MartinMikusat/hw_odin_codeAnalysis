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
	for symbol in state.symbols {
		if symbol.path == path && symbol.is_global {
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
	for symbol in state.symbols {
		if !symbol.is_global {
			continue
		}
		name_lower := strings.to_lower(symbol.name, context.temp_allocator)
		if strings.contains(name_lower, query_lower) {
			append(&result, symbol)
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
	if symbol, ok := symbol_at(state, path, line, column); ok {
		values := make([]Symbol, 1, allocator)
		values[0] = symbol^
		return Location_Result{resolution = .Exact, locations = values}
	}

	if occurrence, ok := occurrence_at(state, path, line, column); ok {
		values := make([dynamic]Symbol, allocator)
		for symbol in state.symbols {
			if symbol.name == occurrence.name {
				append(&values, symbol)
			}
		}
		if len(values) > 0 {
			slice.sort_by(values[:], symbol_less)
			return Location_Result{resolution = .Ambiguous, locations = values[:]}
		}
	}
	return Location_Result{resolution = .Unresolved}
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
		   contains_identifier(symbol.detail, candidate.name) {
			append(&values, candidate)
		}
	}
	if len(values) == 0 {
		for candidate in state.symbols {
			if is_type_symbol(candidate) &&
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
		for occurrence in state.occurrences {
			if occurrence.symbol == id {
				reference_count += 1
			}
		}
	}
	return Inspect_Result {
		resolution = location.resolution,
		symbols = location.locations,
		type_definitions = type_location.locations,
		reference_count = reference_count,
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
	for occurrence in state.occurrences {
		if occurrence.symbol == symbol.id {
			append(&result, occurrence)
		}
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
	for occurrence in state.occurrences {
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
	for value in state.imports {
		if path == "" || value.path == path {
			append(&result, value)
		}
	}
	return result[:]
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
	for file in state.files {
		if file.relative_path != path || line <= 0 {
			continue
		}
		file_directory = file.package_directory
		offset := offset_for_position(file.source, line, column)
		start := offset
		for start > 0 {
			value := file.source[start - 1]
			if !(value == '_' || value >= 'a' && value <= 'z' ||
			     value >= 'A' && value <= 'Z' || value >= '0' && value <= '9') {
				break
			}
			start -= 1
		}
		prefix = file.source[start:offset]
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
		position_offset := max(int)
		for file in state.files {
			if file.relative_path == path {
				position_offset = offset_for_position(file.source, line, column)
				break
			}
		}
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

	for symbol in state.symbols {
		if seen[symbol.name] || prefix != "" && !strings.has_prefix(symbol.name, prefix) {
			continue
		}
		if symbol.is_global || symbol.path == path &&
		   symbol.range.start.line <= line {
			seen[symbol.name] = true
			append(&result, symbol)
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
