package analysis

import "core:path/filepath"
import "core:slice"
import "core:strings"

CAPABILITY_MATCH_LIMIT :: 8

capability_ascii_lower :: proc(value: byte) -> byte {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

capability_is_word_byte :: proc(value: byte) -> bool {
	return value >= 'a' && value <= 'z' ||
	       value >= '0' && value <= '9'
}

capability_normalize :: proc(
	value: string,
	allocator := context.allocator,
) -> string {
	bytes := make([dynamic]byte, allocator)
	defer delete(bytes)
	separator_pending := false
	for raw in transmute([]byte)value {
		lower := capability_ascii_lower(raw)
		if capability_is_word_byte(lower) {
			if separator_pending && len(bytes) > 0 {
				append(&bytes, ' ')
			}
			append(&bytes, lower)
			separator_pending = false
		} else if len(bytes) > 0 {
			separator_pending = true
		}
	}
	return strings.clone(string(bytes[:]), allocator)
}

capability_tokens :: proc(
	value: string,
	allocator := context.allocator,
) -> []string {
	normalized := capability_normalize(value, allocator)
	return strings.fields(normalized, allocator)
}

capability_has_token :: proc(tokens: []string, wanted: string) -> bool {
	for token in tokens {
		if token == wanted {
			return true
		}
	}
	return false
}

capability_value_has_token :: proc(value, wanted: string) -> bool {
	if wanted == "" {
		return false
	}
	index := 0
	for index < len(value) {
		for index < len(value) && !capability_is_word_byte(capability_ascii_lower(value[index])) {
			index += 1
		}
		start := index
		for index < len(value) && capability_is_word_byte(capability_ascii_lower(value[index])) {
			index += 1
		}
		if index - start != len(wanted) {
			continue
		}
		matched := true
		for wanted_index in 0 ..< len(wanted) {
			if capability_ascii_lower(value[start + wanted_index]) != wanted[wanted_index] {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

capability_token_score :: proc(query_tokens: []string, value: string, weight: int) -> int {
	if value == "" || len(query_tokens) == 0 {
		return 0
	}
	score := 0
	for query_token in query_tokens {
		if len(query_token) < 2 {
			continue
		}
		if capability_value_has_token(value, query_token) {
			score += weight
		}
	}
	return score
}

capability_next_token :: proc(value: string, index: ^int) -> (start, end: int, ok: bool) {
	for index^ < len(value) && !capability_is_word_byte(capability_ascii_lower(value[index^])) {
		index^ += 1
	}
	if index^ >= len(value) {
		return
	}
	start = index^
	for index^ < len(value) && capability_is_word_byte(capability_ascii_lower(value[index^])) {
		index^ += 1
	}
	end = index^
	ok = true
	return
}

capability_normalized_equal :: proc(a, b: string) -> bool {
	a_index, b_index := 0, 0
	for {
		a_start, a_end, a_ok := capability_next_token(a, &a_index)
		b_start, b_end, b_ok := capability_next_token(b, &b_index)
		if a_ok != b_ok {
			return false
		}
		if !a_ok {
			return true
		}
		if a_end - a_start != b_end - b_start {
			return false
		}
		for offset in 0 ..< a_end - a_start {
			if capability_ascii_lower(a[a_start + offset]) != capability_ascii_lower(b[b_start + offset]) {
				return false
			}
		}
	}
}

capability_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, index in transmute([]byte)a {
		if capability_ascii_lower(value) != capability_ascii_lower(b[index]) {
			return false
		}
	}
	return true
}

capability_index_fold :: proc(value, query: string) -> int {
	if query == "" || len(query) > len(value) {
		return -1
	}
	for start in 0 ..= len(value) - len(query) {
		matched := true
		for offset in 0 ..< len(query) {
			if capability_ascii_lower(value[start + offset]) != capability_ascii_lower(query[offset]) {
				matched = false
				break
			}
		}
		if matched {
			return start
		}
	}
	return -1
}

capability_symbol_kind :: proc(kind: Symbol_Kind) -> string {
	switch kind {
	case .Package:         return "package"
	case .Import:          return "import"
	case .Constant:        return "constant"
	case .Variable:        return "variable"
	case .Procedure:       return "procedure"
	case .Procedure_Group: return "procedure_group"
	case .Struct:          return "struct"
	case .Union:           return "union"
	case .Enum:            return "enum"
	case .Field:           return "field"
	case .Parameter:       return "parameter"
	case .Unknown:         return "unknown"
	}
	return "unknown"
}

capability_collection_root :: proc(
	state: ^Analysis_Context,
	collection: string,
	allocator := context.allocator,
) -> string {
	root, _ := filepath.join({state.odin_root, collection}, allocator)
	return root
}

capability_source :: proc(
	state: ^Analysis_Context,
	path: string,
	target_root: string,
) -> string {
	absolute_path := path
	if !filepath.is_abs(path) {
		absolute_path, _ = filepath.join({state.root, path}, context.temp_allocator)
	}
	if strings.contains(absolute_path, "/tests/") ||
	   strings.contains(absolute_path, "/test/") ||
	   strings.contains(absolute_path, "/fixtures/") {
		return "test_or_fixture"
	}
	collections := [3]string{"base", "core", "vendor"}
	for collection in collections {
		root := capability_collection_root(state, collection, context.temp_allocator)
		if path_is_within(root, absolute_path) {
			return strings.join({"odin.", collection}, "", context.temp_allocator)
		}
	}
	if path_is_within(target_root, absolute_path) {
		return "target_project"
	}
	return "workspace_project"
}

capability_package :: proc(
	state: ^Analysis_Context,
	package_directory: string,
	package_name: string,
	allocator := context.allocator,
) -> string {
	collections := [3]string{"base", "core", "vendor"}
	for collection in collections {
		root := capability_collection_root(state, collection, context.temp_allocator)
		if path_is_within(root, package_directory) {
			relative := relative_path(root, package_directory, context.temp_allocator)
			if relative == "." {
				return strings.clone(collection, allocator)
			}
			return strings.join({collection, ":", relative}, "", allocator)
		}
	}
	if package_name != "" {
		return strings.clone(package_name, allocator)
	}
	return relative_path(state.root, package_directory, allocator)
}

capability_published_file :: proc(
	state: ^Analysis_Context,
	path: string,
	allocator := context.allocator,
) -> string {
	absolute_path := path
	if !filepath.is_abs(path) {
		absolute_path, _ = filepath.join({state.root, path}, context.temp_allocator)
	}
	if path_is_within(state.odin_root, absolute_path) {
		return relative_path(state.odin_root, absolute_path, allocator)
	}
	return relative_path(state.root, absolute_path, allocator)
}

capability_clip :: proc(
	value: string,
	limit := 1200,
	allocator := context.allocator,
) -> string {
	trimmed := strings.trim_space(value)
	if len(trimmed) > limit {
		trimmed = trimmed[:limit]
	}
	return strings.clone(trimmed, allocator)
}

capability_exact_symbol :: proc(
	primitive: Capability_Primitive,
	symbol: Symbol,
	package_value: string,
) -> bool {
	package_name := strings.join(
		{symbol.package_name, ".", symbol.name},
		"",
		context.temp_allocator,
	)
	qualified := strings.join(
		{package_value, ".", symbol.name},
		"",
		context.temp_allocator,
	)
	for term in primitive.search_terms {
		if capability_normalized_equal(term, symbol.name) ||
		   capability_normalized_equal(term, package_name) ||
		   capability_normalized_equal(term, qualified) {
			return true
		}
	}
	return false
}

capability_rank_symbol :: proc(
	primitive: Capability_Primitive,
	symbol: Symbol,
	package_value: string,
	query_tokens: []string,
) -> (rank: int, exact: bool, reasons: []string) {
	reason_values := make([dynamic]string, context.temp_allocator)
	exact = capability_exact_symbol(primitive, symbol, package_value)
	if exact {
		rank += 1000
		append(&reason_values, "exact normalized symbol or qualified-name match")
	}
	name_score := capability_token_score(query_tokens, symbol.name, 70)
	if name_score > 0 {
		rank += name_score
		append(&reason_values, "query token overlaps symbol name")
	}
	signature_score := capability_token_score(query_tokens, symbol.detail, 25)
	if signature_score > 0 {
		rank += signature_score
		append(&reason_values, "query token overlaps signature")
	}
	docs_score := capability_token_score(query_tokens, symbol.documentation, 15)
	if docs_score > 0 {
		rank += docs_score
		append(&reason_values, "query token overlaps documentation")
	}
	package_score := capability_token_score(query_tokens, package_value, 20)
	if package_score > 0 {
		rank += package_score
		append(&reason_values, "query token overlaps package")
	}
	path_score := capability_token_score(query_tokens, symbol.path, 10)
	if path_score > 0 {
		rank += path_score
		append(&reason_values, "query token overlaps file path")
	}
	return rank, exact, reason_values[:]
}

capability_match_less :: proc(a, b: Capability_Match) -> bool {
	if a.rank != b.rank {
		return a.rank > b.rank
	}
	if a.source != b.source {
		return strings.compare(a.source, b.source) < 0
	}
	if a.file != b.file {
		return strings.compare(a.file, b.file) < 0
	}
	if a.line != b.line {
		return a.line < b.line
	}
	return strings.compare(a.name, b.name) < 0
}

capability_document_match :: proc(
	state: ^Analysis_Context,
	document: Document_Record,
	primitive: Capability_Primitive,
	target_root: string,
	allocator := context.allocator,
) -> (Capability_Match, bool) {
	match_offset := -1
	matched_term := ""
	for term in primitive.search_terms {
		trimmed_term := strings.trim_space(term)
		if len(trimmed_term) < 2 {
			continue
		}
		if offset := capability_index_fold(document.text, trimmed_term); offset >= 0 {
			match_offset = offset
			matched_term = term
			break
		}
	}
	if match_offset < 0 {
		return {}, false
	}
	line := 1
	line_start := 0
	for index in 0 ..< match_offset {
		if document.text[index] == '\n' {
			line += 1
			line_start = index + 1
		}
	}
	line_end := line_start
	for line_end < len(document.text) && document.text[line_end] != '\n' {
		line_end += 1
	}
	package_value := capability_package(
		state,
		document.package_directory,
		"",
		allocator,
	)
	reasons := make([]string, 1, allocator)
	reasons[0] = strings.join(
		{"documentation contains search term: ", matched_term},
		"",
		allocator,
	)
	return Capability_Match {
		name = strings.clone(filepath.base(document.path), allocator),
		kind = strings.clone("documentation", allocator),
		docs = capability_clip(document.text[line_start:line_end], allocator = allocator),
		package_name = package_value,
		file = capability_published_file(state, document.path, allocator),
		line = line,
		source = strings.clone(
			capability_source(state, document.path, target_root),
			allocator,
		),
		rank = 120,
		reasons = reasons,
	}, true
}

capability_target_root :: proc(
	state: ^Analysis_Context,
	target_project: string,
	allocator := context.allocator,
) -> string {
	if filepath.is_abs(target_project) {
		return normalized_path(target_project, allocator)
	}
	path, _ := filepath.join({state.root, target_project}, context.temp_allocator)
	return normalized_path(path, allocator)
}

capability_audit :: proc(
	state: ^Analysis_Context,
	input: Capability_Audit_Input,
	allocator := context.allocator,
) -> (result: Capability_Audit_Result, error_message: string, ok: bool) {
	if state == nil || !state.initialized {
		return {}, "analysis index is unavailable", false
	}
	if strings.trim_space(input.target_project) == "" {
		return {}, "target_project is required", false
	}
	if len(input.primitives) > 64 {
		return {}, "primitives accepts at most 64 entries", false
	}
	target_root := capability_target_root(state, input.target_project, context.temp_allocator)
	if !path_is_within(state.root, target_root) {
		return {}, "target_project must be inside the analysis root", false
	}

	result.target_project = strings.clone(input.target_project, allocator)
	result.compiler_root = strings.clone(state.odin_root, allocator)
	result.results = make([]Capability_Primitive_Result, len(input.primitives), allocator)

	for primitive, primitive_index in input.primitives {
		if strings.trim_space(primitive.id) == "" || strings.trim_space(primitive.need) == "" {
			return {}, "each primitive requires id and need", false
		}
		matches := make([dynamic]Capability_Match, allocator)
		has_exact := false
		query_text := strings.join(primitive.search_terms, " ", context.temp_allocator)
		query_text = strings.join(
			{primitive.need, " ", query_text},
			"",
			context.temp_allocator,
		)
		query_tokens := capability_tokens(query_text, context.temp_allocator)
		for symbol in state.symbols {
			if !symbol.is_global {
				continue
			}
			package_value := capability_package(
				state,
				symbol.package_directory,
				symbol.package_name,
				context.temp_allocator,
			)
			rank, exact, reasons := capability_rank_symbol(
				primitive,
				symbol,
				package_value,
				query_tokens,
			)
			if rank == 0 {
				continue
			}
			has_exact = has_exact || exact
			match_reasons := make([]string, len(reasons), allocator)
			for reason, reason_index in reasons {
				match_reasons[reason_index] = strings.clone(reason, allocator)
			}
			append(
				&matches,
				Capability_Match {
					name = strings.clone(symbol.name, allocator),
					kind = strings.clone(capability_symbol_kind(symbol.kind), allocator),
					signature = capability_clip(symbol.detail, allocator = allocator),
					docs = capability_clip(symbol.documentation, allocator = allocator),
					package_name = strings.clone(package_value, allocator),
					file = capability_published_file(state, symbol.path, allocator),
					line = symbol.range.start.line,
					source = strings.clone(
						capability_source(state, symbol.path, target_root),
						allocator,
					),
					rank = rank,
					reasons = match_reasons,
				},
			)
		}
		for document in state.documents {
			if match, matched := capability_document_match(
				state,
				document,
				primitive,
				target_root,
				allocator,
			); matched {
				append(&matches, match)
			}
		}
		slice.sort_by(matches[:], capability_match_less)
		if len(matches) > CAPABILITY_MATCH_LIMIT {
			resize(&matches, CAPABILITY_MATCH_LIMIT)
		}
		status := "not_found"
		if has_exact {
			status = "available"
		} else if len(matches) > 0 {
			status = "candidate"
		}
		result.results[primitive_index] = Capability_Primitive_Result {
			id = strings.clone(primitive.id, allocator),
			need = strings.clone(primitive.need, allocator),
			status = strings.clone(status, allocator),
			matches = matches[:],
		}
	}
	return result, "", true
}
