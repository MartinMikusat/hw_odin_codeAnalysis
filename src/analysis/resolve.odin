package analysis

import "core:path/filepath"

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

find_declaration_occurrence :: proc(state: ^Analysis_Context, occurrence: Occurrence) -> Symbol_ID {
	for symbol in state.symbols {
		if symbol.path == occurrence.path && same_position(symbol.range.start, occurrence.range.start) {
			return symbol.id
		}
	}
	return Symbol_ID(-1)
}

resolve_occurrence :: proc(state: ^Analysis_Context, occurrence: Occurrence) -> Symbol_ID {
	if declaration := find_declaration_occurrence(state, occurrence); int(declaration) >= 0 {
		return declaration
	}

	best_local := Symbol_ID(-1)
	best_offset := -1
	occurrence_scope, has_occurrence_scope := enclosing_procedure(
		state,
		occurrence.path,
		occurrence.range.start.offset,
	)
	for symbol in state.symbols {
		if symbol.name != occurrence.name || symbol.path != occurrence.path || symbol.is_global {
			continue
		}
		if has_occurrence_scope {
			if symbol.range.start.offset < occurrence_scope.extent.start.offset ||
			   symbol.range.start.offset >= occurrence_scope.extent.end.offset {
				continue
			}
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

	if occurrence.is_selector {
		if imported := resolve_import_selector(state, occurrence); int(imported) >= 0 {
			return imported
		}
		if field := resolve_field_selector(state, occurrence); int(field) >= 0 {
			return field
		}
	}

	package_match := Symbol_ID(-1)
	package_count := 0
	for symbol in state.symbols {
		if symbol.name == occurrence.name &&
		   symbol.package_directory == occurrence.package_directory &&
		   symbol.is_global {
			package_match = symbol.id
			package_count += 1
		}
	}
	if package_count == 1 {
		return package_match
	}

	global_match := Symbol_ID(-1)
	global_count := 0
	for symbol in state.symbols {
		if symbol.name == occurrence.name && symbol.is_global {
			global_match = symbol.id
			global_count += 1
		}
	}
	if global_count == 1 {
		return global_match
	}
	return Symbol_ID(-1)
}

resolve_import_selector :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
) -> Symbol_ID {
	if occurrence.selector_base == "" {
		return Symbol_ID(-1)
	}
	for import_value in state.imports {
		if import_value.path != occurrence.path ||
		   import_value.alias != occurrence.selector_base {
			continue
		}
		for file in state.files {
			if filepath.dir(file.path) != import_value.resolved_path {
				continue
			}
			for symbol in state.symbols {
				if symbol.path == file.relative_path &&
				   symbol.name == occurrence.name &&
				   symbol.is_global {
					return symbol.id
				}
			}
		}
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

resolve_base_symbol :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
) -> Symbol_ID {
	best := Symbol_ID(-1)
	best_offset := -1
	for candidate in state.occurrences {
		if candidate.path != occurrence.path ||
		   candidate.name != occurrence.selector_base ||
		   candidate.range.start.offset >= occurrence.range.start.offset ||
		   int(candidate.symbol) < 0 {
			continue
		}
		if candidate.range.start.offset > best_offset {
			best = candidate.symbol
			best_offset = candidate.range.start.offset
		}
	}
	return best
}

resolve_field_selector :: proc(
	state: ^Analysis_Context,
	occurrence: Occurrence,
) -> Symbol_ID {
	base_id := resolve_base_symbol(state, occurrence)
	if int(base_id) < 0 {
		return Symbol_ID(-1)
	}
	base := state.symbols[int(base_id)]
	type_symbol := Symbol_ID(-1)
	for candidate in state.symbols {
		if candidate.kind != .Struct &&
		   candidate.kind != .Union &&
		   candidate.kind != .Enum {
			continue
		}
		if candidate.package_directory == base.package_directory &&
		   contains_identifier(base.detail, candidate.name) {
			type_symbol = candidate.id
			break
		}
	}
	if int(type_symbol) < 0 {
		return Symbol_ID(-1)
	}
	type_value := state.symbols[int(type_symbol)]
	match := Symbol_ID(-1)
	count := 0
	for field in state.symbols {
		if field.kind == .Field &&
		   field.name == occurrence.name &&
		   field.owner_type == type_value.name &&
		   field.package_directory == type_value.package_directory {
			match = field.id
			count += 1
		}
	}
	if count == 1 {
		return match
	}
	return Symbol_ID(-1)
}

resolve_occurrences :: proc(state: ^Analysis_Context) {
	for &occurrence in state.occurrences {
		occurrence.symbol = resolve_occurrence(state, occurrence)
	}
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
	for &symbol in state.symbols {
		if symbol.path != path || symbol.kind != .Procedure {
			continue
		}
		if offset < symbol.extent.start.offset || offset >= symbol.extent.end.offset {
			continue
		}
		size := symbol.extent.end.offset - symbol.extent.start.offset
		if size < best_size {
			best = &symbol
			best_size = size
		}
	}
	return best, best != nil
}
