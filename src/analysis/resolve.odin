package analysis

import "core:path/filepath"
import "core:strings"

Symbol_Name_Index :: map[string][dynamic]Symbol_ID

same_position :: proc(a, b: Source_Position) -> bool {
	return a.offset == b.offset
}

range_contains :: proc(value: Source_Range, line, column: int) -> bool {
	if line < value.start.line || line > value.end.line {
		return false
	}
	if line == value.start.line && column < value.start.column {
		return false
	}
	if line == value.end.line && column >= value.end.column {
		return false
	}
	return true
}

find_declaration_occurrence :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> Symbol_ID {
	for symbol_id in candidates {
		symbol := state.symbols[int(symbol_id)]
		if symbol.path == occurrence.path && same_position(symbol.range.start, occurrence.range.start) {
			return symbol.id
		}
	}
	return Symbol_ID(-1)
}

symbol_is_builtin :: proc(state: ^Analysis_Context, symbol: Symbol) -> bool {
	return state.builtin_path != "" && symbol.path == state.builtin_path
}

symbol_occurrences_are_complete :: proc(
	state: ^Analysis_Context,
	symbol: Symbol,
) -> bool {
	for file in state.files {
		if file.relative_path == symbol.path {
			return file.occurrences_complete
		}
	}
	return false
}

import_exposes_symbol :: proc(
	state: ^Analysis_Context,
	import_value: Import,
	symbol: Symbol,
) -> bool {
	for file in state.files {
		if file.relative_path == symbol.path &&
		   filepath.dir(file.path) == import_value.resolved_path {
			return true
		}
	}
	return false
}

same_package_match :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> (match: Symbol_ID, count: int) {
	match = Symbol_ID(-1)
	for symbol_id in candidates {
		symbol := state.symbols[int(symbol_id)]
		if symbol.name == occurrence.name &&
		   symbol.package_directory == occurrence.package_directory &&
		   symbol.is_global &&
		   !symbol_is_builtin(state, symbol) {
			match = symbol.id
			count += 1
		}
	}
	return
}

using_import_match :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> (match: Symbol_ID, count: int) {
	match = Symbol_ID(-1)
	for symbol_id in candidates {
		symbol := state.symbols[int(symbol_id)]
		if symbol.name != occurrence.name ||
		   !symbol.is_global ||
		   symbol_is_builtin(state, symbol) {
			continue
		}
		for import_value in state.imports {
			if import_value.path == occurrence.path &&
			   import_value.is_using &&
			   import_exposes_symbol(state, import_value, symbol) {
				match = symbol.id
				count += 1
				break
			}
		}
	}
	return
}

builtin_match :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> (match: Symbol_ID, count: int) {
	match = Symbol_ID(-1)
	for symbol_id in candidates {
		symbol := state.symbols[int(symbol_id)]
		if symbol.name == occurrence.name && symbol_is_builtin(state, symbol) {
			match = symbol.id
			count += 1
		}
	}
	return
}

resolve_occurrence :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> Symbol_ID {
	if declaration := find_declaration_occurrence(
		state,
		occurrence,
		candidates,
	); int(declaration) >= 0 {
		return declaration
	}

	if occurrence.is_selector {
		if imported := resolve_import_selector(
			state,
			occurrence,
			candidates,
		); int(imported) >= 0 {
			return imported
		}
		if field := resolve_field_selector(
			state,
			occurrence,
			candidates,
		); int(field) >= 0 {
			return field
		}
		return Symbol_ID(-1)
	}

	best_local := Symbol_ID(-1)
	best_offset := -1
	occurrence_scope, has_occurrence_scope := enclosing_procedure(
		state,
		occurrence.path,
		occurrence.range.start.offset,
	)
	for symbol_id in candidates {
		symbol := state.symbols[int(symbol_id)]
		if symbol.name != occurrence.name || symbol.path != occurrence.path || symbol.is_global {
			continue
		}
		if has_occurrence_scope {
			if symbol.range.start.offset < occurrence_scope.extent.start.offset ||
			   symbol.range.start.offset >= occurrence_scope.extent.end.offset {
				continue
			}
		}
		if occurrence.range.start.offset < symbol.extent.start.offset ||
		   occurrence.range.start.offset >= symbol.extent.end.offset {
			continue
		}
		if symbol.range.start.offset <= occurrence.range.start.offset &&
		   symbol.range.start.offset > best_offset {
			best_local = symbol.id
			best_offset = symbol.range.start.offset
		}
	}
	if int(best_local) >= 0 {
		return best_local
	}

	package_match, package_count := same_package_match(
		state,
		occurrence,
		candidates,
	)
	if package_count > 0 {
		return package_match if package_count == 1 else Symbol_ID(-1)
	}

	using_match, using_count := using_import_match(
		state,
		occurrence,
		candidates,
	)
	if using_count > 0 {
		return using_match if using_count == 1 else Symbol_ID(-1)
	}

	builtin_value, builtin_count := builtin_match(
		state,
		occurrence,
		candidates,
	)
	if builtin_count == 1 {
		return builtin_value
	}
	return Symbol_ID(-1)
}

visible_candidates :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	allocator := context.allocator,
) -> []Symbol {
	result := make([dynamic]Symbol, allocator)
	if occurrence.is_selector {
		for symbol in state.symbols {
			if !symbol.is_global || symbol.name != occurrence.name {
				continue
			}
			for import_value in state.imports {
				if import_value.path == occurrence.path &&
				   import_value.alias == occurrence.selector_base &&
				   import_exposes_symbol(state, import_value, symbol) {
					append(&result, symbol)
					break
				}
			}
		}
		return result[:]
	}

	for symbol in state.symbols {
		if symbol.name == occurrence.name &&
		   symbol.package_directory == occurrence.package_directory &&
		   symbol.is_global &&
		   !symbol_is_builtin(state, symbol) {
			append(&result, symbol)
		}
	}
	if len(result) > 0 {
		return result[:]
	}

	for symbol in state.symbols {
		if symbol.name != occurrence.name ||
		   !symbol.is_global ||
		   symbol_is_builtin(state, symbol) {
			continue
		}
		for import_value in state.imports {
			if import_value.path == occurrence.path &&
			   import_value.is_using &&
			   import_exposes_symbol(state, import_value, symbol) {
				append(&result, symbol)
				break
			}
		}
	}
	if len(result) > 0 {
		return result[:]
	}

	for symbol in state.symbols {
		if symbol.name == occurrence.name && symbol_is_builtin(state, symbol) {
			append(&result, symbol)
		}
	}
	return result[:]
}

resolve_import_selector :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> Symbol_ID {
	if occurrence.selector_base == "" {
		return Symbol_ID(-1)
	}
	match := Symbol_ID(-1)
	count := 0
	for import_value in state.imports {
		if import_value.path != occurrence.path ||
		   import_value.alias != occurrence.selector_base {
			continue
		}
		for file in state.files {
			if filepath.dir(file.path) != import_value.resolved_path {
				continue
			}
			for symbol_id in candidates {
				symbol := state.symbols[int(symbol_id)]
				if symbol.path == file.relative_path &&
				   symbol.name == occurrence.name &&
				   symbol.is_global {
					match = symbol.id
					count += 1
				}
			}
		}
	}
	if count == 1 {
		return match
	}
	return Symbol_ID(-1)
}

contains_identifier :: proc(text, identifier: string) -> bool {
	if identifier == "" {
		return false
	}
	for start := 0; start + len(identifier) <= len(text); start += 1 {
		if text[start:start + len(identifier)] != identifier {
			continue
		}
		before_ok := start == 0 || !is_identifier_byte(text[start - 1])
		end := start + len(identifier)
		after_ok := end == len(text) || !is_identifier_byte(text[end])
		if before_ok && after_ok {
			return true
		}
	}
	return false
}

is_identifier_byte :: proc(value: byte) -> bool {
	return value == '_' ||
	       value >= 'a' && value <= 'z' ||
	       value >= 'A' && value <= 'Z' ||
	       value >= '0' && value <= '9'
}

resolve_base_symbol :: proc(state: ^Analysis_Context, occurrence: Occurrence) -> Symbol_ID {
	if occurrence.receiver_offset == 0 { return Symbol_ID(-1) }
	for index in state.occurrences_by_path[occurrence.path] {
		receiver := state.occurrences[index]
		if receiver.range.start.offset + 1 == occurrence.receiver_offset {
			return receiver.symbol
		}
	}
	return Symbol_ID(-1)
}

record_type :: proc(state: ^Analysis_Context, base: Symbol) -> Symbol_ID {
	if is_type_symbol(base) { return base.id }
	name := strings.trim_space(base.detail)
	for strings.has_prefix(name, "^") {
		name = strings.trim_space(name[1:])
	}
	directory := base.package_directory
	if dot := strings.index_byte(name, '.'); dot >= 0 {
		directory = ""
		for index in state.imports_by_path[base.path] {
			imported := state.imports[index]
			if imported.alias == name[:dot] {
				directory = imported.resolved_path
				break
			}
		}
		if directory == "" { return Symbol_ID(-1) }
		name = name[dot + 1:]
	}
	global := Symbol_ID(-1)
	local := Symbol_ID(-1)
	local_offset := -1
	global_count := 0
	for id in state.symbols_by_name[name] {
		candidate := state.symbols[int(id)]
		if candidate.package_directory != directory || !is_type_symbol(candidate) { continue }
		if candidate.is_global {
			global, global_count = id, global_count + 1
		} else if candidate.path == base.path &&
		          candidate.range.start.offset < base.range.start.offset &&
		          candidate.range.start.offset > local_offset &&
		          base.range.start.offset < candidate.extent.end.offset {
			local, local_offset = id, candidate.range.start.offset
		}
	}
	if int(local) >= 0 { return local }
	return global if global_count == 1 else Symbol_ID(-1)
}

resolve_field_selector :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
	candidates: []Symbol_ID,
) -> Symbol_ID {
	base_id := resolve_base_symbol(state, occurrence)
	if int(base_id) < 0 { return Symbol_ID(-1) }
	type_id := record_type(state, state.symbols[int(base_id)])
	if int(type_id) < 0 { return Symbol_ID(-1) }
	owner := state.symbols[int(type_id)]
	match := Symbol_ID(-1)
	for field_id in candidates {
		field := state.symbols[int(field_id)]
		if field.kind != .Field || field.path != owner.path || field.owner_type != owner.name ||
		   field.range.start.offset <= owner.range.start.offset ||
		   field.range.start.offset >= owner.extent.end.offset {
			continue
		}
		if int(match) >= 0 { return Symbol_ID(-1) }
		match = field.id
	}
	return match
}

resolve_occurrences :: proc(state: ^Analysis_Context, start := 0) -> bool {
	assert(state != nil)
	assert(start >= 0 && start <= len(state.occurrences))
	for index in start ..< len(state.occurrences) {
		occurrence := state.occurrences[index]
		state.occurrences[index].symbol = resolve_occurrence(
			state,
			occurrence,
			state.symbols_by_name[occurrence.name][:],
		)
	}
	return true
}

occurrence_at :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
) -> (^Occurrence, bool) {
	for &occurrence in state.occurrences {
		if occurrence.path == path && range_contains(occurrence.range, line, column) {
			return &occurrence, true
		}
	}
	return nil, false
}

symbol_at :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
) -> (^Symbol, bool) {
	if occurrence, ok := occurrence_at(state, path, line, column); ok && int(occurrence.symbol) >= 0 {
		return &state.symbols[int(occurrence.symbol)], true
	}
	for &symbol in state.symbols {
		if symbol.path == path && range_contains(symbol.range, line, column) {
			return &symbol, true
		}
	}
	return nil, false
}

enclosing_procedure :: proc(
	state: ^Analysis_Context,
	path: string,
	offset: int,
) -> (^Symbol, bool) {
	best: ^Symbol
	best_size := max(int)
	for symbol_id in state.symbols_by_path[path] {
		symbol := &state.symbols[int(symbol_id)]
		if symbol.kind != .Procedure {
			continue
		}
		if offset < symbol.extent.start.offset || offset >= symbol.extent.end.offset {
			continue
		}
		size := symbol.extent.end.offset - symbol.extent.start.offset
		if size < best_size {
			best = symbol
			best_size = size
		}
	}
	return best, best != nil
}
