package analysis

import "base:runtime"
import "core:mem/virtual"
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

Capability_Catalog_Entry :: struct {
	name:          string,
	kind:          string,
	signature:     string,
	docs:          string,
	package_value: string,
	file:          string,
	absolute_path: string,
	line:          int,
	platform:      string,
}

capability_platform :: proc(path: string) -> string {
	name := filepath.base(path)
	platforms := [7]string{"darwin", "linux", "windows", "freebsd", "openbsd", "wasm", "js"}
	for platform in platforms {
		needle := strings.join({"_", platform, ".odin"}, "", context.temp_allocator)
		if strings.has_suffix(name, needle) {
			return platform
		}
	}
	return "all"
}

capability_import_path :: proc(package_value, source: string, allocator := context.allocator) -> string {
	if strings.has_prefix(source, "odin.") {
		return strings.clone(package_value, allocator)
	}
	return ""
}

capability_package_alias :: proc(package_value: string) -> string {
	colon := strings.last_index_byte(package_value, ':')
	value := package_value
	if colon >= 0 {
		value = package_value[colon + 1:]
	}
	return filepath.base(value)
}

capability_source_allowed :: proc(primitive: Capability_Primitive, source: string) -> bool {
	if len(primitive.allowed_sources) == 0 {
		return true
	}
	for allowed in primitive.allowed_sources {
		if allowed == source {
			return true
		}
	}
	return false
}

capability_proc_parts :: proc(signature: string) -> (parameters, results: string, ok: bool) {
	proc_offset := strings.index(signature, "proc")
	if proc_offset < 0 {
		return
	}
	open_offset := strings.index(signature[proc_offset:], "(")
	if open_offset < 0 {
		return
	}
	open_offset += proc_offset
	depth := 1
	close_offset := open_offset + 1
	for close_offset < len(signature) && depth > 0 {
		if signature[close_offset] == '(' {
			depth += 1
		} else if signature[close_offset] == ')' {
			depth -= 1
		}
		close_offset += 1
	}
	if depth != 0 {
		return
	}
	parameters = signature[open_offset + 1:close_offset - 1]
	results = strings.trim_space(signature[close_offset:])
	if strings.has_prefix(results, "->") {
		results = strings.trim_space(results[2:])
	} else {
		results = ""
	}
	ok = true
	return
}

capability_entry_compatible :: proc(
	primitive: Capability_Primitive,
	kind, signature, platform, source: string,
) -> bool {
	if primitive.kind != "" && primitive.kind != kind {
		return false
	}
	if !capability_source_allowed(primitive, source) {
		return false
	}
	if primitive.target_platform != "" && platform != "all" && platform != primitive.target_platform {
		return false
	}
	parameters, results, proc_ok := capability_proc_parts(signature)
	if (len(primitive.parameter_types) > 0 || len(primitive.result_types) > 0) && !proc_ok {
		return false
	}
	for parameter_type in primitive.parameter_types {
		if !strings.contains(parameters, parameter_type) {
			return false
		}
	}
	for result_type in primitive.result_types {
		if !strings.contains(results, result_type) {
			return false
		}
	}
	is_generic := strings.contains(signature, "$")
	if primitive.generic_requirement == "required" && !is_generic ||
	   primitive.generic_requirement == "forbidden" && is_generic {
		return false
	}
	// The lexical catalog cannot prove allocation or ownership semantics.
	if primitive.allocation_behavior != "" || primitive.ownership_requirement != "" {
		return false
	}
	return true
}

Capability_Catalog_Document :: struct {
	file:          string,
	absolute_path: string,
	package_value: string,
	text:          string,
}

Capability_Catalog :: struct {
	workspace_root: string,
	odin_root:      string,
	arena:          virtual.Arena,
	entries:        [dynamic]Capability_Catalog_Entry,
	documents:      [dynamic]Capability_Catalog_Document,
	entries_by_name: map[string][dynamic]int,
	entries_by_token: map[string][dynamic]int,
	generation:      u64,
	initialized:    bool,
}

capability_catalog_destroy :: proc(catalog: ^Capability_Catalog) {
	if catalog == nil || !catalog.initialized {
		return
	}
	virtual.arena_destroy(&catalog.arena)
	catalog^ = {}
}

capability_catalog_append_index :: proc(
	index: ^map[string][dynamic]int,
	key: string,
	value: int,
	allocator: runtime.Allocator,
) {
	values, found := index^[key]
	if !found {
		values = make([dynamic]int, allocator)
	}
	append(&values, value)
	index^[key] = values
}

capability_catalog_index_entry :: proc(
	catalog: ^Capability_Catalog,
	entry_index: int,
) {
	allocator := virtual.arena_allocator(&catalog.arena)
	entry := catalog.entries[entry_index]
	normalized_name := capability_normalize(entry.name, allocator)
	capability_catalog_append_index(
		&catalog.entries_by_name,
		normalized_name,
		entry_index,
		allocator,
	)
	seen := make(map[string]bool, context.temp_allocator)
	index_values := [5]string{
		entry.name,
		entry.signature,
		entry.docs,
		entry.package_value,
		entry.file,
	}
	for value in index_values {
		for token in capability_tokens(value, context.temp_allocator) {
			if len(token) < 2 || seen[token] {
				continue
			}
			seen[token] = true
			capability_catalog_append_index(
				&catalog.entries_by_token,
				strings.clone(token, allocator),
				entry_index,
				allocator,
			)
		}
	}
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
	platform := capability_platform(file)
	if !capability_entry_compatible(builder.primitive, kind, signature, platform, source) {
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
		import_path = capability_import_path(package_value, source, allocator),
		qualified_symbol = strings.join(
			{capability_package_alias(package_value), ".", name},
			"",
			allocator,
		),
		file = strings.clone(file, allocator),
		line = line,
		source = strings.clone(source, allocator),
		excerpt = capability_clip(signature, allocator = allocator),
		platform = strings.clone(platform, allocator),
		allocation_behavior = "unknown",
		ownership = "unknown",
		unknown_properties = []string{"allocation_behavior", "ownership"},
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

capability_declaration_signature :: proc(
	text: string,
	start: int,
	kind: string,
) -> string {
	line_end := start
	for line_end < len(text) && text[line_end] != '\n' {
		line_end += 1
	}
	if kind != "procedure" && kind != "procedure_group" {
		return strings.trim_space(text[start:line_end])
	}
	paren_depth := 0
	index := start
	limit := min(len(text), start + 4096)
	for index < limit {
		value := text[index]
		if value == '(' {
			paren_depth += 1
		} else if value == ')' && paren_depth > 0 {
			paren_depth -= 1
		} else if value == '{' && paren_depth == 0 {
			return strings.trim_space(text[start:index])
		}
		index += 1
	}
	return strings.trim_space(text[start:line_end])
}

capability_scan_source :: proc(
	workspace_root, odin_root, target_root, path: string,
	builders: []Capability_Audit_Builder,
	catalog: ^Capability_Catalog = nil,
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
				signature := capability_declaration_signature(text, line_start, kind)
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
				if catalog != nil {
					catalog_allocator := virtual.arena_allocator(&catalog.arena)
					append(
						&catalog.entries,
						Capability_Catalog_Entry {
							name = strings.clone(name, catalog_allocator),
							kind = strings.clone(kind, catalog_allocator),
							signature = strings.clone(signature, catalog_allocator),
							docs = strings.clone(docs, catalog_allocator),
							package_value = strings.clone(package_value, catalog_allocator),
							file = strings.clone(file, catalog_allocator),
							absolute_path = strings.clone(path, catalog_allocator),
							line = line_number,
							platform = strings.clone(capability_platform(path), catalog_allocator),
						},
					)
					capability_catalog_index_entry(catalog, len(catalog.entries) - 1)
				}
				source := capability_direct_source(odin_root, target_root, path)
				for &builder in builders {
					rank, exact, reasons, reason_count := capability_direct_rank(
						&builder,
						name,
						signature,
						docs,
						package_value,
						file,
					)
					capability_direct_consider(
						&builder,
						name,
						kind,
						signature,
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
	catalog: ^Capability_Catalog = nil,
	allocator := context.allocator,
) -> bool {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return false
	}
	defer delete(data)
	text := string(data)
	if catalog != nil {
		catalog_allocator := virtual.arena_allocator(&catalog.arena)
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
		append(
			&catalog.documents,
			Capability_Catalog_Document {
				file = strings.clone(file, catalog_allocator),
				absolute_path = strings.clone(path, catalog_allocator),
				package_value = strings.clone(package_value, catalog_allocator),
				text = strings.clone(text, catalog_allocator),
			},
		)
		delete(package_value)
		delete(file)
	}
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
	catalog: ^Capability_Catalog = nil,
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
					catalog,
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
					catalog,
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
		nil,
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
			nil,
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

capability_catalog_init :: proc(
	catalog: ^Capability_Catalog,
	workspace_root: string,
) -> (error_message: string, ok: bool) {
	if catalog == nil {
		return "capability catalog is required", false
	}
	if virtual.arena_init_growing(&catalog.arena) != nil {
		return "failed to allocate the capability catalog", false
	}
	catalog.initialized = true
	allocator := virtual.arena_allocator(&catalog.arena)
	catalog.workspace_root = strings.clone(workspace_root, allocator)
	odin_root, odin_root_ok := resolve_odin_root(context.temp_allocator)
	if !odin_root_ok {
		capability_catalog_destroy(catalog)
		return "failed to resolve the active Odin compiler root", false
	}
	catalog.odin_root = strings.clone(odin_root, allocator)
	catalog.entries = make([dynamic]Capability_Catalog_Entry, allocator)
	catalog.documents = make([dynamic]Capability_Catalog_Document, allocator)
	catalog.entries_by_name = make(map[string][dynamic]int, allocator = allocator)
	catalog.entries_by_token = make(map[string][dynamic]int, allocator = allocator)
	catalog.generation = 1
	if scan_error, scan_ok := capability_scan_root(
		workspace_root,
		odin_root,
		workspace_root,
		workspace_root,
		nil,
		catalog,
		context.temp_allocator,
	); !scan_ok {
		capability_catalog_destroy(catalog)
		return scan_error, false
	}
	collections := [3]string{"base", "core", "vendor"}
	for collection in collections {
		collection_root, _ := filepath.join({odin_root, collection}, context.temp_allocator)
		if scan_error, scan_ok := capability_scan_root(
			workspace_root,
			odin_root,
			workspace_root,
			collection_root,
			nil,
			catalog,
			context.temp_allocator,
		); !scan_ok {
			capability_catalog_destroy(catalog)
			return scan_error, false
		}
	}
	return "", true
}

capability_catalog_consider_document :: proc(
	builder: ^Capability_Audit_Builder,
	document: Capability_Catalog_Document,
	target_root: string,
	odin_root: string,
	allocator := context.allocator,
) {
	match_offset := -1
	matched_term := ""
	for term in builder.primitive.search_terms {
		trimmed_term := strings.trim_space(term)
		if len(trimmed_term) >= 2 {
			match_offset = capability_index_fold(document.text, trimmed_term)
			if match_offset >= 0 {
				matched_term = trimmed_term
				break
			}
		}
	}
	if match_offset < 0 {
		return
	}
	line, line_start := 1, 0
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
	reasons := [5]string{}
	reasons[0] = strings.join(
		{"documentation contains search term: ", matched_term},
		"",
		context.temp_allocator,
	)
	capability_direct_consider(
		builder,
		filepath.base(document.absolute_path),
		"documentation",
		"",
		document.text[line_start:line_end],
		document.package_value,
		document.file,
		capability_direct_source(odin_root, target_root, document.absolute_path),
		line,
		120,
		false,
		reasons,
		1,
		allocator,
	)
}

capability_audit_catalog :: proc(
	catalog: ^Capability_Catalog,
	input: Capability_Audit_Input,
	allocator := context.allocator,
) -> (result: Capability_Audit_Result, error_message: string, ok: bool) {
	if catalog == nil || !catalog.initialized {
		return {}, "capability catalog is unavailable", false
	}
	if strings.trim_space(input.target_project) == "" {
		return {}, "target_project is required", false
	}
	if len(input.primitives) > 64 {
		return {}, "primitives accepts at most 64 entries", false
	}
	target_root := input.target_project
	if !filepath.is_abs(target_root) {
		target_root, _ = filepath.join(
			{catalog.workspace_root, input.target_project},
			context.temp_allocator,
		)
	}
	target_root = normalized_path(target_root, context.temp_allocator)
	if !path_is_within(catalog.workspace_root, target_root) || !os.exists(target_root) {
		return {}, "target_project must be an existing directory inside the workspace", false
	}
	result.target_project = strings.clone(input.target_project, allocator)
	result.compiler_root = strings.clone(catalog.odin_root, allocator)
	result.generation = catalog.generation
	result.results = make([]Capability_Primitive_Result, len(input.primitives), allocator)
	for primitive, primitive_index in input.primitives {
		if strings.trim_space(primitive.id) == "" || strings.trim_space(primitive.need) == "" {
			return {}, "each primitive requires id and need", false
		}
		query_text := strings.join(primitive.search_terms, " ", context.temp_allocator)
		query_text = strings.join({primitive.need, " ", query_text}, "", context.temp_allocator)
		builder := Capability_Audit_Builder {
			primitive = primitive,
			query_tokens = capability_tokens(query_text, context.temp_allocator),
			matches = make([dynamic]Capability_Match, 0, CAPABILITY_MATCH_LIMIT, allocator),
		}
		candidate_entries := make(map[int]bool, context.temp_allocator)
		for term in primitive.search_terms {
			normalized_term := capability_normalize(term, context.temp_allocator)
			if entry_indices, found := catalog.entries_by_name[normalized_term]; found {
				for entry_index in entry_indices {
					candidate_entries[entry_index] = true
				}
			}
		}
		for token in builder.query_tokens {
			if entry_indices, found := catalog.entries_by_token[token]; found {
				for entry_index in entry_indices {
					candidate_entries[entry_index] = true
				}
			}
		}
		for entry_index in candidate_entries {
			entry := catalog.entries[entry_index]
			rank, exact, reasons, reason_count := capability_direct_rank(
				&builder,
				entry.name,
				entry.signature,
				entry.docs,
				entry.package_value,
				entry.file,
			)
			capability_direct_consider(
				&builder,
				entry.name,
				entry.kind,
				entry.signature,
				entry.docs,
				entry.package_value,
				entry.file,
				capability_direct_source(catalog.odin_root, target_root, entry.absolute_path),
				entry.line,
				rank,
				exact,
				reasons,
				reason_count,
				allocator,
			)
		}
		for document in catalog.documents {
			capability_catalog_consider_document(
				&builder,
				document,
				target_root,
				catalog.odin_root,
				allocator,
			)
		}
		status := "not_found"
		if builder.has_exact {
			status = "available"
		} else if len(builder.matches) > 0 {
			status = "candidate"
		}
		result.results[primitive_index] = Capability_Primitive_Result {
			id = strings.clone(primitive.id, allocator),
			need = strings.clone(primitive.need, allocator),
			status = strings.clone(status, allocator),
			matches = builder.matches[:],
		}
	}
	return result, "", true
}
