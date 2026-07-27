package analysis

import "base:runtime"
import "core:mem/virtual"
import "core:odin/ast"
import parser "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Collect_State :: struct {
	analysis:       ^Analysis_Context,
	file:           ^File_Record,
	top_level:      map[^ast.Node]bool,
	selector_offsets: map[int]bool,
	selector_bases: map[int]string,
	call_offsets:   map[int]bool,
	field_kinds:    map[^ast.Field]Symbol_Kind,
	field_owners:   map[^ast.Field]string,
	collect_occurrences: bool,
}

position_from_ast :: proc(line, column, offset: int) -> Source_Position {
	return Source_Position{line = line, column = column, offset = offset}
}

range_from_node :: proc(node: ^ast.Node) -> Source_Range {
	if node == nil {
		return {}
	}
	end_offset := node.end.offset
	if end_offset < node.pos.offset {
		end_offset = node.pos.offset
	}
	return Source_Range {
		start = position_from_ast(node.pos.line, node.pos.column, node.pos.offset),
		end = position_from_ast(node.end.line, node.end.column, end_offset),
	}
}

range_from_ident :: proc(ident: ^ast.Ident) -> Source_Range {
	if ident == nil {
		return {}
	}
	return Source_Range {
		start = position_from_ast(ident.pos.line, ident.pos.column, ident.pos.offset),
		end = position_from_ast(
			ident.pos.line,
			ident.pos.column + len(ident.name),
			ident.pos.offset + len(ident.name),
		),
	}
}

relative_path :: proc(root, path: string, allocator := context.allocator) -> string {
	value, relative_error := filepath.rel(root, path, allocator)
	if relative_error != nil {
		return strings.clone(path, allocator)
	}
	return value
}

path_is_within :: proc(root, path: string) -> bool {
	if root == path {
		return true
	}
	if !strings.has_prefix(path, root) || len(path) <= len(root) {
		return false
	}
	return root[len(root) - 1] == '/' || path[len(root)] == '/'
}

normalized_path :: proc(path: string, allocator := context.allocator) -> string {
	result, path_error := os.get_absolute_path(path, allocator)
	if path_error == nil {
		return result
	}
	return strings.clone(path, allocator)
}

published_path :: proc(
	state: ^Analysis_Context,
	path: string,
	allocator := context.allocator,
) -> string {
	if path_is_within(state.root, path) {
		return relative_path(state.root, path, allocator)
	}
	return strings.clone(path, allocator)
}

add_watch_root :: proc(state: ^Analysis_Context, path: string) {
	normalized := normalized_path(path)
	for root in state.watch_roots {
		if path_is_within(root, normalized) {
			delete(normalized)
			return
		}
	}
	for index := len(state.watch_roots) - 1; index >= 0; index -= 1 {
		if path_is_within(normalized, state.watch_roots[index]) {
			delete(state.watch_roots[index])
			unordered_remove(&state.watch_roots, index)
		}
	}
	append(&state.watch_roots, normalized)
}

dependency_watch_root :: proc(directory: string) -> string {
	collection_names := [3]string{"base", "core", "vendor"}
	for collection_name in collection_names {
		root, _ := filepath.join(
			{ODIN_ROOT, collection_name},
			context.temp_allocator,
		)
		root = normalized_path(root, context.temp_allocator)
		if path_is_within(root, directory) {
			return root
		}
	}
	return directory
}

should_exclude :: proc(state: ^Analysis_Context, path: string) -> bool {
	for excluded in state.config.exclude_paths {
		if excluded == "" {
			continue
		}
		needle := strings.join({"/", excluded, "/"}, "", context.temp_allocator)
		if strings.contains(path, needle) ||
		   strings.has_suffix(path, strings.join({"/", excluded}, "", context.temp_allocator)) {
			return true
		}
	}
	return false
}

scan_recursive_root :: proc(
	state: ^Analysis_Context,
	root: string,
	visited_files: ^map[string]bool,
) -> bool {
	add_watch_root(state, root)
	walker := os.walker_create(root)
	for info in os.walker_walk(&walker) {
		if info.type == .Directory {
			if should_exclude(state, info.fullpath) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if info.type != .Regular || !strings.has_suffix(info.name, ".odin") {
			continue
		}
		if should_exclude(state, info.fullpath) {
			continue
		}
		path := normalized_path(info.fullpath, context.temp_allocator)
		if visited_files^[path] {
			continue
		}
		visited_files^[path] = true
		if !parse_file_into_context(state, path) {
			os.walker_destroy(&walker)
			return false
		}
	}
	os.walker_destroy(&walker)
	return true
}

scan_package_directory :: proc(
	state: ^Analysis_Context,
	directory: string,
	visited_files: ^map[string]bool,
) -> bool {
	entries, read_error := os.read_all_directory_by_path(
		directory,
		context.temp_allocator,
	)
	if read_error != nil {
		return false
	}
	slice.sort_by(
		entries,
		proc(a, b: os.File_Info) -> bool {
			return strings.compare(a.fullpath, b.fullpath) < 0
		},
	)
	for info in entries {
		if info.type != .Regular ||
		   !strings.has_suffix(info.name, ".odin") ||
		   should_exclude(state, info.fullpath) {
			continue
		}
		path := normalized_path(info.fullpath, context.temp_allocator)
		if visited_files^[path] {
			continue
		}
		visited_files^[path] = true
		if !parse_file_into_context(state, path, false, true, false) {
			return false
		}
	}
	return true
}

scan_and_parse :: proc(state: ^Analysis_Context) -> bool {
	roots := make([dynamic]string, context.temp_allocator)
	append(&roots, state.root)
	for collection in state.config.collections {
		path := collection.path
		if !filepath.is_abs(path) {
			path, _ = filepath.join({state.root, path}, context.temp_allocator)
		}
		append(&roots, path)
	}

	visited_files := make(map[string]bool, context.temp_allocator)
	builtin_path, _ := filepath.join(
		{ODIN_ROOT, "base", "builtin", "builtin.odin"},
		context.temp_allocator,
	)
	builtin_path = normalized_path(builtin_path, context.temp_allocator)
	if !parse_builtin_file_into_context(state, builtin_path) {
		return false
	}
	visited_files[builtin_path] = true
	add_watch_root(state, filepath.dir(builtin_path))

	for root in roots {
		if !scan_recursive_root(state, root, &visited_files) {
			return false
		}
	}

	visited_packages := make(map[string]bool, context.temp_allocator)
	for import_index := 0; import_index < len(state.imports); import_index += 1 {
		import_value := state.imports[import_index]
		if !filepath.is_abs(import_value.resolved_path) {
			continue
		}
		directory := normalized_path(
			import_value.resolved_path,
			context.temp_allocator,
		)
		if visited_packages[directory] {
			continue
		}
		visited_packages[directory] = true
		add_watch_root(state, dependency_watch_root(directory))
		if !scan_package_directory(state, directory, &visited_files) {
			return false
		}
	}

	slice.sort_by(
		state.watch_roots[:],
		proc(a, b: string) -> bool {
			return strings.compare(a, b) < 0
		},
	)
	return true
}

parse_builtin_file_into_context :: proc(
	state: ^Analysis_Context,
	path: string,
) -> bool {
	arena_allocator := virtual_arena_allocator(state)
	source_bytes, read_error := os.read_entire_file(path, arena_allocator)
	if read_error != nil {
		return false
	}

	record := File_Record {
		id = File_ID(len(state.files)),
		path = strings.clone(path, arena_allocator),
		relative_path = strings.clone(path, arena_allocator),
		package_name = strings.clone("builtin", arena_allocator),
		package_directory = strings.clone(filepath.dir(path), arena_allocator),
		source = string(source_bytes),
		is_builtin = true,
		occurrences_complete = false,
	}
	append(&state.files, record)
	file := &state.files[len(state.files) - 1]
	state.builtin_path = file.relative_path

	symbol_count_before := len(state.symbols)
	line_number := 1
	line_start := 0
	for line_start < len(file.source) {
		line_end := line_start
		for line_end < len(file.source) && file.source[line_end] != '\n' {
			line_end += 1
		}
		line := file.source[line_start:line_end]

		name_end := 0
		if len(line) > 0 &&
		   (line[0] == '_' ||
		    line[0] >= 'a' && line[0] <= 'z' ||
		    line[0] >= 'A' && line[0] <= 'Z') {
			for name_end < len(line) && is_identifier_byte(line[name_end]) {
				name_end += 1
			}
		}
		operator_start := name_end
		for operator_start < len(line) && line[operator_start] == ' ' {
			operator_start += 1
		}
		if name_end > 0 &&
		   operator_start + 1 < len(line) &&
		   line[operator_start:operator_start + 2] == "::" {
			detail := strings.trim_space(line[operator_start + 2:])
			kind := Symbol_Kind.Constant
			if strings.has_prefix(detail, "proc{") {
				kind = .Procedure_Group
			} else if strings.has_prefix(detail, "proc") {
				kind = .Procedure
			} else if strings.has_prefix(detail, "struct") {
				kind = .Struct
			} else if strings.has_prefix(detail, "union") {
				kind = .Union
			} else if strings.has_prefix(detail, "enum") {
				kind = .Enum
			}

			symbol_id := Symbol_ID(len(state.symbols))
			name_range := Source_Range {
				start = position_from_ast(line_number, 1, line_start),
				end = position_from_ast(
					line_number,
					name_end + 1,
					line_start + name_end,
				),
			}
			append(
				&state.symbols,
				Symbol {
					id = symbol_id,
					name = strings.clone(line[:name_end], arena_allocator),
					kind = kind,
					path = file.relative_path,
					package_name = file.package_name,
					package_directory = file.package_directory,
					range = name_range,
					extent = Source_Range {
						start = name_range.start,
						end = position_from_ast(
							line_number,
							len(line) + 1,
							line_end,
						),
					},
					detail = strings.clone(detail, arena_allocator),
					is_global = true,
				},
			)
			append(
				&state.occurrences,
				Occurrence {
					name = state.symbols[int(symbol_id)].name,
					path = file.relative_path,
					package_name = file.package_name,
					package_directory = file.package_directory,
					range = name_range,
					symbol = symbol_id,
				},
			)
		}

		line_start = line_end + 1
		line_number += 1
	}
	return len(state.symbols) > symbol_count_before
}

parse_file_into_context :: proc(
	state: ^Analysis_Context,
	path: string,
	is_builtin := false,
	collect_import_declarations := true,
	collect_occurrences := true,
) -> bool {
	arena_allocator := virtual_arena_allocator(state)
	source_bytes, read_error := os.read_entire_file(path, arena_allocator)
	if read_error != nil {
		return false
	}

	package_path := filepath.dir(path)
	ast_package := new(ast.Package, arena_allocator)
	ast_package.kind = .Normal
	ast_package.fullpath = strings.clone(package_path, arena_allocator)
	ast_package.name = strings.clone(filepath.base(package_path), arena_allocator)
	ast_package.files = make(map[string]^ast.File, allocator = arena_allocator)

	record := File_Record {
		id = File_ID(len(state.files)),
		path = strings.clone(path, arena_allocator),
		relative_path = published_path(state, path, arena_allocator),
		package_name = strings.clone(package_path, arena_allocator),
		source = string(source_bytes),
		is_builtin = is_builtin,
		occurrences_complete = collect_occurrences,
	}
	record.package_directory = strings.clone(
		filepath.dir(record.relative_path),
		arena_allocator,
	)
	record.ast_file = ast.File {
		pkg = ast_package,
		fullpath = record.path,
		src = record.source,
	}

	old_allocator := context.allocator
	context.allocator = arena_allocator
	file_parser := parser.default_parser()
	file_parser.err = nil
	file_parser.warn = nil
	_ = parser.parse_file(&file_parser, &record.ast_file)
	context.allocator = old_allocator

	if record.ast_file.pkg_name != "" {
		record.package_name = strings.clone(record.ast_file.pkg_name, arena_allocator)
	}

	append(&state.files, record)
	file := &state.files[len(state.files) - 1]
	collect_file(
		state,
		file,
		collect_import_declarations,
		collect_occurrences,
	)
	return true
}

virtual_arena_allocator :: proc(state: ^Analysis_Context) -> runtime.Allocator {
	return virtual.arena_allocator(&state.arena)
}

symbol_kind_from_value :: proc(decl: ^ast.Value_Decl, index: int) -> Symbol_Kind {
	value: ^ast.Expr
	if index < len(decl.values) {
		value = decl.values[index]
	} else if len(decl.values) > 0 {
		value = decl.values[0]
	}
	if value != nil {
		#partial switch value_node in value.derived {
		case ^ast.Proc_Lit:
			return .Procedure
		case ^ast.Proc_Group:
			return .Procedure_Group
		case ^ast.Struct_Type:
			return .Struct
		case ^ast.Union_Type:
			return .Union
		case ^ast.Enum_Type:
			return .Enum
		}
	}
	if decl.is_mutable {
		return .Variable
	}
	return .Constant
}

node_source_text :: proc(file: ^File_Record, node: ^ast.Node, allocator := context.allocator) -> string {
	if node == nil {
		return ""
	}
	start := clamp(node.pos.offset, 0, len(file.source))
	end := clamp(node.end.offset, start, len(file.source))
	if end == start {
		return ""
	}
	return strings.clone(file.source[start:end], allocator)
}

add_value_symbols :: proc(collector: ^Collect_State, decl: ^ast.Value_Decl) {
	is_global := collector.top_level[cast(^ast.Node)decl]
	for name_expression, index in decl.names {
		ident, ok := name_expression.derived.(^ast.Ident)
		if !ok || ident.name == "_" {
			continue
		}
		detail_node: ^ast.Node
		if decl.type != nil {
			detail_node = cast(^ast.Node)decl.type
		} else if index < len(decl.values) {
			detail_node = cast(^ast.Node)decl.values[index]
		} else if len(decl.values) > 0 {
			detail_node = cast(^ast.Node)decl.values[0]
		}
		if detail_node != nil {
			#partial switch value in detail_node.derived {
			case ^ast.Proc_Lit:
				detail_node = cast(^ast.Node)value.type
				if value.type.params != nil {
					for field in value.type.params.list {
						collector.field_kinds[field] = .Parameter
					}
				}
				if value.type.results != nil {
					for field in value.type.results.list {
						collector.field_kinds[field] = .Parameter
					}
				}
			case ^ast.Struct_Type:
				if value.fields != nil {
					for field in value.fields.list {
						collector.field_owners[field] = ident.name
					}
				}
			}
		}
		symbol := Symbol {
			id = Symbol_ID(len(collector.analysis.symbols)),
			name = strings.clone(ident.name, virtual_arena_allocator(collector.analysis)),
			kind = symbol_kind_from_value(decl, index),
			path = collector.file.relative_path,
			package_name = collector.file.package_name,
			package_directory = collector.file.package_directory,
			range = range_from_ident(ident),
			extent = range_from_node(cast(^ast.Node)decl),
			detail = node_source_text(
				collector.file,
				detail_node,
				virtual_arena_allocator(collector.analysis),
			),
			is_global = is_global,
		}
		append(&collector.analysis.symbols, symbol)
	}
}

add_field_symbols :: proc(collector: ^Collect_State, field: ^ast.Field) {
	kind := Symbol_Kind.Field
	if classified_kind, found := collector.field_kinds[field]; found {
		kind = classified_kind
	}
	owner := collector.field_owners[field]
	for name_expression in field.names {
		ident, ok := name_expression.derived.(^ast.Ident)
		if !ok || ident.name == "_" {
			continue
		}
		append(
			&collector.analysis.symbols,
			Symbol {
				id = Symbol_ID(len(collector.analysis.symbols)),
				name = strings.clone(ident.name, virtual_arena_allocator(collector.analysis)),
				kind = kind,
				path = collector.file.relative_path,
				package_name = collector.file.package_name,
				package_directory = collector.file.package_directory,
				owner_type = owner,
				range = range_from_ident(ident),
				extent = range_from_node(cast(^ast.Node)field),
				detail = node_source_text(
					collector.file,
					cast(^ast.Node)field.type,
					virtual_arena_allocator(collector.analysis),
				),
			},
		)
	}
}

collect_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return visitor
	}
	collector := cast(^Collect_State)visitor.data
	#partial switch value in node.derived {
	case ^ast.Value_Decl:
		add_value_symbols(collector, value)
	case ^ast.Field:
		add_field_symbols(collector, value)
	case ^ast.Selector_Expr:
		collector.selector_offsets[value.field.pos.offset] = true
		if base, ok := value.expr.derived.(^ast.Ident); ok {
			collector.selector_bases[value.field.pos.offset] = base.name
		}
	case ^ast.Implicit_Selector_Expr:
		collector.selector_offsets[value.field.pos.offset] = true
	case ^ast.Call_Expr:
		#partial switch expression in value.expr.derived {
		case ^ast.Ident:
			collector.call_offsets[expression.pos.offset] = true
		case ^ast.Selector_Expr:
			collector.call_offsets[expression.field.pos.offset] = true
		}
	case ^ast.Ident:
		if !collector.collect_occurrences {
			return visitor
		}
		append(
			&collector.analysis.occurrences,
			Occurrence {
				name = strings.clone(value.name, virtual_arena_allocator(collector.analysis)),
				path = collector.file.relative_path,
				package_name = collector.file.package_name,
				package_directory = collector.file.package_directory,
				range = range_from_ident(value),
				symbol = Symbol_ID(-1),
				is_call = collector.call_offsets[value.pos.offset],
				is_selector = collector.selector_offsets[value.pos.offset],
				selector_base = collector.selector_bases[value.pos.offset],
			},
		)
	}
	return visitor
}

trim_import_path :: proc(value: string) -> string {
	if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
		return value[1:len(value) - 1]
	}
	return value
}

collect_imports :: proc(state: ^Analysis_Context, file: ^File_Record) {
	allocator := virtual_arena_allocator(state)
	for declaration in file.ast_file.imports {
		import_path := trim_import_path(declaration.relpath.text)
		alias := declaration.name.text
		if alias == "" {
			separator := strings.last_index_byte(import_path, '/')
			if separator >= 0 {
				alias = import_path[separator + 1:]
			} else if colon := strings.last_index_byte(import_path, ':'); colon >= 0 {
				alias = import_path[colon + 1:]
			} else {
				alias = import_path
			}
		}
		resolved := resolve_import_path(state, file, import_path, allocator)
		append(
			&state.imports,
			Import {
				path = file.relative_path,
				package_name = file.package_name,
				alias = strings.clone(alias, allocator),
				import_path = strings.clone(import_path, allocator),
				resolved_path = resolved,
				is_using = declaration.is_using,
				range = range_from_node(cast(^ast.Node)declaration),
			},
		)
	}
}

resolve_import_path :: proc(
	state: ^Analysis_Context,
	file: ^File_Record,
	import_path: string,
	allocator := context.allocator,
) -> string {
	if colon := strings.index_byte(import_path, ':'); colon > 0 {
		collection_name := import_path[:colon]
		suffix := import_path[colon + 1:]
		for collection in state.config.collections {
			if collection.name == collection_name {
				root := collection.path
				if !filepath.is_abs(root) {
					root, _ = filepath.join({state.root, root}, context.temp_allocator)
				}
				result, _ := filepath.join({root, suffix}, allocator)
				return result
			}
		}
		if collection_name == "base" ||
		   collection_name == "core" ||
		   collection_name == "vendor" {
			result, _ := filepath.join(
				{ODIN_ROOT, collection_name, suffix},
				allocator,
			)
			return result
		}
		return strings.clone(import_path, allocator)
	}
	if strings.has_prefix(import_path, "./") || strings.has_prefix(import_path, "../") {
		result, _ := filepath.join({filepath.dir(file.path), import_path}, allocator)
		return result
	}
	return strings.clone(import_path, allocator)
}

collect_file :: proc(
	state: ^Analysis_Context,
	file: ^File_Record,
	collect_import_declarations := true,
	collect_occurrences := true,
) {
	top_level := make(map[^ast.Node]bool, context.temp_allocator)
	for statement in file.ast_file.decls {
		top_level[cast(^ast.Node)statement] = true
	}
	collector := Collect_State {
		analysis = state,
		file = file,
		top_level = top_level,
		selector_offsets = make(map[int]bool, context.temp_allocator),
		selector_bases = make(map[int]string, context.temp_allocator),
		call_offsets = make(map[int]bool, context.temp_allocator),
		field_kinds = make(map[^ast.Field]Symbol_Kind, context.temp_allocator),
		field_owners = make(map[^ast.Field]string, context.temp_allocator),
		collect_occurrences = collect_occurrences,
	}
	visitor := ast.Visitor{visit = collect_visit, data = &collector}
	for statement in file.ast_file.decls {
		ast.walk(&visitor, cast(^ast.Node)statement)
	}
	if collect_import_declarations {
		collect_imports(state, file)
	}
}
