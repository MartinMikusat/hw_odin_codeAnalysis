package analysis

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Capability_Audit_Builder :: struct {
	primitive:    Capability_Primitive,
	query_tokens: []string,
	matches:      [dynamic]Capability_Match,
	has_exact:    bool,
}

capability_scan_excluded :: proc(path: string) -> bool {
	excluded_paths := [7]string{
		".git",
		".cache",
		".svelte-kit",
		"build",
		"dist",
		"node_modules",
		"research/reference-projects",
	}
	for excluded in excluded_paths {
		needle := strings.join({"/", excluded, "/"}, "", context.temp_allocator)
		if strings.contains(path, needle) ||
		   strings.has_suffix(path, strings.join({"/", excluded}, "", context.temp_allocator)) {
			return true
		}
	}
	return false
}

capability_direct_collection :: proc(
	odin_root, path: string,
) -> (collection, collection_root: string, ok: bool) {
	collections := [3]string{"base", "core", "vendor"}
	for value in collections {
		root, _ := filepath.join({odin_root, value}, context.temp_allocator)
		if path_is_within(root, path) {
			return value, root, true
		}
	}
	return
}

capability_direct_source :: proc(
	odin_root, target_root, path: string,
) -> string {
	if strings.contains(path, "/tests/") ||
	   strings.contains(path, "/test/") ||
	   strings.contains(path, "/fixtures/") {
		return "test_or_fixture"
	}
	if collection, _, collection_ok := capability_direct_collection(odin_root, path); collection_ok {
		return strings.join({"odin.", collection}, "", context.temp_allocator)
	}
	if path_is_within(target_root, path) {
		return "target_project"
	}
	return "workspace_project"
}

capability_direct_file :: proc(
	workspace_root, odin_root, path: string,
	allocator := context.allocator,
) -> string {
	if path_is_within(odin_root, path) {
		return relative_path(odin_root, path, allocator)
	}
	return relative_path(workspace_root, path, allocator)
}

capability_direct_package :: proc(
	workspace_root, odin_root, path, declared_package: string,
	allocator := context.allocator,
) -> string {
	directory := filepath.dir(path)
	if collection, collection_root, collection_ok := capability_direct_collection(
		odin_root,
		path,
	); collection_ok {
		relative := relative_path(collection_root, directory, context.temp_allocator)
		if relative == "." {
			return strings.clone(collection, allocator)
		}
		return strings.join({collection, ":", relative}, "", allocator)
	}
	if declared_package != "" {
		return strings.clone(declared_package, allocator)
	}
	return relative_path(workspace_root, directory, allocator)
}

capability_direct_exact :: proc(
	primitive: Capability_Primitive,
	name, package_value: string,
) -> bool {
	qualified := strings.join({package_value, ".", name}, "", context.allocator)
	defer delete(qualified)
	short_qualified := strings.join(
		{filepath.base(package_value), ".", name},
		"",
		context.allocator,
	)
	defer delete(short_qualified)
	for term in primitive.search_terms {
		if capability_equal_fold(term, name) ||
		   capability_normalized_equal(term, qualified) ||
		   capability_normalized_equal(term, short_qualified) {
			return true
		}
	}
	return false
}

capability_direct_rank :: proc(
	builder: ^Capability_Audit_Builder,
	name, signature, docs, package_value, path: string,
) -> (rank: int, exact: bool, reasons: [5]string, reason_count: int) {
	exact = capability_direct_exact(builder.primitive, name, package_value)
	if exact {
		rank += 1000
		reasons[reason_count] = "exact normalized symbol or qualified-name match"
		reason_count += 1
	}
	if score := capability_token_score(builder.query_tokens, name, 70); score > 0 {
		rank += score
		reasons[reason_count] = "query token overlaps symbol name"
		reason_count += 1
	}
	if score := capability_token_score(builder.query_tokens, signature, 25); score > 0 {
		rank += score
		reasons[reason_count] = "query token overlaps signature"
		reason_count += 1
	}
	if score := capability_token_score(builder.query_tokens, docs, 15); score > 0 {
		rank += score
		reasons[reason_count] = "query token overlaps documentation"
		reason_count += 1
	}
	package_and_path := strings.join({package_value, " ", path}, "", context.allocator)
	defer delete(package_and_path)
	if score := capability_token_score(builder.query_tokens, package_and_path, 15); score > 0 {
		rank += score
		reasons[reason_count] = "query token overlaps package or file path"
		reason_count += 1
	}
	return
}

capability_direct_consider :: proc(
	builder: ^Capability_Audit_Builder,
	name, kind, signature, docs, package_value, file, source: string,
	line, rank: int,
	exact: bool,
	reasons: [5]string,
	reason_count: int,
	allocator := context.allocator,
) {
	if rank == 0 {
		return
	}
	builder.has_exact = builder.has_exact || exact
	if len(builder.matches) == CAPABILITY_MATCH_LIMIT {
		last := builder.matches[len(builder.matches) - 1]
		probe := Capability_Match{
			name = name,
			file = file,
			line = line,
			source = source,
			rank = rank,
		}
		if !capability_match_less(probe, last) {
			return
		}
	}
	match_reasons := make([]string, reason_count, allocator)
	for reason_index in 0 ..< reason_count {
		match_reasons[reason_index] = strings.clone(reasons[reason_index], allocator)
	}
	match := Capability_Match {
		name = strings.clone(name, allocator),
		kind = strings.clone(kind, allocator),
		signature = capability_clip(signature, allocator = allocator),
		docs = capability_clip(docs, allocator = allocator),
		package_name = strings.clone(package_value, allocator),
		file = strings.clone(file, allocator),
		line = line,
		source = strings.clone(source, allocator),
		rank = rank,
		reasons = match_reasons,
	}
	if len(builder.matches) < CAPABILITY_MATCH_LIMIT {
		append(&builder.matches, match)
	} else {
		builder.matches[len(builder.matches) - 1] = match
	}
	slice.sort_by(builder.matches[:], capability_match_less)
}

capability_declaration :: proc(line: string) -> (name, kind: string, ok: bool) {
	if line == "" || line[0] == ' ' || line[0] == '\t' {
		return
	}
	name_end := 0
	for name_end < len(line) {
		value := capability_ascii_lower(line[name_end])
		if !capability_is_word_byte(value) && line[name_end] != '_' {
			break
		}
		name_end += 1
	}
	if name_end == 0 || line[0] >= '0' && line[0] <= '9' {
		return
	}
	operator_start := name_end
	for operator_start < len(line) && line[operator_start] == ' ' {
		operator_start += 1
	}
	if operator_start >= len(line) || line[operator_start] != ':' {
		return
	}
	if operator_start + 1 >= len(line) ||
	   line[operator_start + 1] != ':' && line[operator_start + 1] != '=' {
		return
	}
	name = line[:name_end]
	right := strings.trim_space(line[operator_start + 2:])
	kind = "constant"
	if strings.has_prefix(right, "proc{") {
		kind = "procedure_group"
	} else if strings.has_prefix(right, "proc") {
		kind = "procedure"
	} else if strings.has_prefix(right, "struct") {
		kind = "struct"
	} else if strings.has_prefix(right, "union") {
		kind = "union"
	} else if strings.has_prefix(right, "enum") {
		kind = "enum"
	} else if line[operator_start + 1] == '=' {
		kind = "variable"
	}
	ok = true
	return
}

capability_scan_source :: proc(
	workspace_root, odin_root, target_root, path: string,
	builders: []Capability_Audit_Builder,
	allocator := context.allocator,
) -> bool {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return false
	}
	defer delete(data)
	text := string(data)
	declared_package := ""
	docs_start, docs_end := -1, -1
	in_block_comment := false
	line_number := 1
	line_start := 0
	for line_start <= len(text) {
		line_end := line_start
		for line_end < len(text) && text[line_end] != '\n' {
			line_end += 1
		}
		line := text[line_start:line_end]
		trimmed := strings.trim_space(line)
		if in_block_comment {
			docs_end = line_end
			if strings.contains(trimmed, "*/") {
				in_block_comment = false
			}
		} else if strings.has_prefix(trimmed, "/*") {
			docs_start = line_start
			docs_end = line_end
			in_block_comment = !strings.contains(trimmed, "*/")
		} else if strings.has_prefix(trimmed, "package ") {
			declared_package = strings.trim_space(trimmed[len("package "):])
			docs_start, docs_end = -1, -1
		} else if strings.has_prefix(trimmed, "//") {
			if docs_start < 0 {
				docs_start = line_start
			}
			docs_end = line_end
		} else if trimmed == "" {
			docs_start, docs_end = -1, -1
		} else if strings.has_prefix(trimmed, "@") || strings.has_prefix(trimmed, "#") {
			// Preserve the preceding documentation across top-level attributes.
		} else {
			if name, kind, declaration_ok := capability_declaration(line); declaration_ok {
				docs := ""
				if docs_start >= 0 && docs_end >= docs_start {
					docs = text[docs_start:docs_end]
				}
				package_value := capability_direct_package(
					workspace_root,
					odin_root,
					path,
					declared_package,
					context.allocator,
				)
				file := capability_direct_file(
					workspace_root,
					odin_root,
					path,
					context.allocator,
				)
				source := capability_direct_source(odin_root, target_root, path)
				for &builder in builders {
					rank, exact, reasons, reason_count := capability_direct_rank(
						&builder,
						name,
						trimmed,
						docs,
						package_value,
						file,
					)
					capability_direct_consider(
						&builder,
						name,
						kind,
						trimmed,
						docs,
						package_value,
						file,
						source,
						line_number,
						rank,
						exact,
						reasons,
						reason_count,
						allocator,
					)
				}
				delete(package_value)
				delete(file)
			}
			docs_start, docs_end = -1, -1
		}
		if line_end == len(text) {
			break
		}
		line_start = line_end + 1
		line_number += 1
	}
	return true
}

capability_scan_document :: proc(
	workspace_root, odin_root, target_root, path: string,
	builders: []Capability_Audit_Builder,
	allocator := context.allocator,
) -> bool {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return false
	}
	defer delete(data)
	text := string(data)
	for &builder in builders {
		match_offset := -1
		matched_term := ""
		for term in builder.primitive.search_terms {
			trimmed_term := strings.trim_space(term)
			if len(trimmed_term) >= 2 {
				match_offset = capability_index_fold(text, trimmed_term)
				if match_offset >= 0 {
					matched_term = trimmed_term
					break
				}
			}
		}
		if match_offset < 0 {
			continue
		}
		line, line_start := 1, 0
		for index in 0 ..< match_offset {
			if text[index] == '\n' {
				line += 1
				line_start = index + 1
			}
		}
		line_end := line_start
		for line_end < len(text) && text[line_end] != '\n' {
			line_end += 1
		}
		package_value := capability_direct_package(
			workspace_root,
			odin_root,
			path,
			"",
			context.allocator,
		)
		file := capability_direct_file(
			workspace_root,
			odin_root,
			path,
			context.allocator,
		)
		reasons := [5]string{}
		reasons[0] = strings.join(
			{"documentation contains search term: ", matched_term},
			"",
			context.temp_allocator,
		)
		capability_direct_consider(
			&builder,
			filepath.base(path),
			"documentation",
			"",
			text[line_start:line_end],
			package_value,
			file,
			capability_direct_source(odin_root, target_root, path),
			line,
			120,
			false,
			reasons,
			1,
			allocator,
		)
		delete(package_value)
		delete(file)
	}
	return true
}

capability_scan_root :: proc(
	workspace_root, odin_root, target_root, root: string,
	builders: []Capability_Audit_Builder,
	allocator := context.allocator,
) -> (string, bool) {
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type == .Directory {
			if capability_scan_excluded(info.fullpath) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if info.type != .Regular || capability_scan_excluded(info.fullpath) {
			continue
		}
		path := normalized_path(info.fullpath, context.temp_allocator)
		if strings.has_suffix(info.name, ".odin") {
			if !capability_scan_source(
				workspace_root,
				odin_root,
				target_root,
				path,
				builders,
				allocator,
			) {
				return strings.join({"failed to read source file: ", path}, "", allocator), false
			}
		} else if is_document_path(info.name) {
			if !capability_scan_document(
				workspace_root,
				odin_root,
				target_root,
				path,
				builders,
				allocator,
			) {
				return strings.join({"failed to read documentation file: ", path}, "", allocator), false
			}
		}
	}
	return "", true
}

capability_audit_workspace :: proc(
	workspace_root: string,
	input: Capability_Audit_Input,
	allocator := context.allocator,
) -> (result: Capability_Audit_Result, error_message: string, ok: bool) {
	if strings.trim_space(input.target_project) == "" {
		return {}, "target_project is required", false
	}
	if len(input.primitives) > 64 {
		return {}, "primitives accepts at most 64 entries", false
	}
	odin_root, odin_root_ok := resolve_odin_root(context.temp_allocator)
	if !odin_root_ok {
		return {}, "failed to resolve the active Odin compiler root", false
	}
	target_root := input.target_project
	if !filepath.is_abs(target_root) {
		target_root, _ = filepath.join(
			{workspace_root, input.target_project},
			context.temp_allocator,
		)
	}
	target_root = normalized_path(target_root, context.temp_allocator)
	if !path_is_within(workspace_root, target_root) || !os.exists(target_root) {
		return {}, "target_project must be an existing directory inside the workspace", false
	}

	result.target_project = strings.clone(input.target_project, allocator)
	result.compiler_root = strings.clone(odin_root, allocator)
	result.results = make([]Capability_Primitive_Result, len(input.primitives), allocator)
	if len(input.primitives) == 0 {
		return result, "", true
	}

	builders := make([]Capability_Audit_Builder, len(input.primitives), allocator)
	for primitive, index in input.primitives {
		if strings.trim_space(primitive.id) == "" || strings.trim_space(primitive.need) == "" {
			return {}, "each primitive requires id and need", false
		}
		query_text := strings.join(primitive.search_terms, " ", allocator)
		query_text = strings.join({primitive.need, " ", query_text}, "", allocator)
		builders[index] = Capability_Audit_Builder {
			primitive = primitive,
			query_tokens = capability_tokens(query_text, allocator),
			matches = make([dynamic]Capability_Match, 0, CAPABILITY_MATCH_LIMIT, allocator),
		}
	}

	if scan_error, scan_ok := capability_scan_root(
		workspace_root,
		odin_root,
		target_root,
		workspace_root,
		builders,
		allocator,
	); !scan_ok {
		return {}, scan_error, false
	}
	collections := [3]string{"base", "core", "vendor"}
	for collection in collections {
		collection_root, _ := filepath.join({odin_root, collection}, context.temp_allocator)
		if scan_error, scan_ok := capability_scan_root(
			workspace_root,
			odin_root,
			target_root,
			collection_root,
			builders,
			allocator,
		); !scan_ok {
			return {}, scan_error, false
		}
	}

	for &builder, index in builders {
		status := "not_found"
		if builder.has_exact {
			status = "available"
		} else if len(builder.matches) > 0 {
			status = "candidate"
		}
		result.results[index] = Capability_Primitive_Result {
			id = strings.clone(builder.primitive.id, allocator),
			need = strings.clone(builder.primitive.need, allocator),
			status = strings.clone(status, allocator),
			matches = builder.matches[:],
		}
	}
	return result, "", true
}
