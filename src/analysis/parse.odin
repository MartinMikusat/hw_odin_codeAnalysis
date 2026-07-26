package analysis

import "base:runtime"
import "core:mem/virtual"
import "core:odin/ast"
import parser "core:odin/parser"
import "core:os"
import "core:path/filepath"
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

	for root in roots {
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
			if !parse_file_into_context(state, info.fullpath) {
				os.walker_destroy(&walker)
				return false
			}
		}
		os.walker_destroy(&walker)
	}
	return true
}

parse_file_into_context :: proc(state: ^Analysis_Context, path: string) -> bool {
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
		relative_path = relative_path(state.root, path, arena_allocator),
		package_name = strings.clone(package_path, arena_allocator),
		package_directory = relative_path(state.root, package_path, arena_allocator),
		source = string(source_bytes),
	}
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
	collect_file(state, file)
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
		return strings.clone(import_path, allocator)
	}
	if strings.has_prefix(import_path, "./") || strings.has_prefix(import_path, "../") {
		result, _ := filepath.join({filepath.dir(file.path), import_path}, allocator)
		return result
	}
	return strings.clone(import_path, allocator)
}

collect_file :: proc(state: ^Analysis_Context, file: ^File_Record) {
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
	}
	visitor := ast.Visitor{visit = collect_visit, data = &collector}
	for statement in file.ast_file.decls {
		ast.walk(&visitor, cast(^ast.Node)statement)
	}
	collect_imports(state, file)
}
