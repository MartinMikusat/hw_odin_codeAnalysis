package analysis

import "base:runtime"
import "core:odin/ast"
import "core:slice"
import "core:strings"

qualified_declarations :: proc(
	state: ^Analysis_Context,
	query: string,
	allocator := context.allocator,
) -> []Symbol {
	name, prefix := query, ""
	if dot := strings.last_index_byte(query, '.'); dot >= 0 {
		prefix, name = query[:dot], query[dot + 1:]
	}
	owner, package_name := prefix, ""
	if dot := strings.last_index_byte(prefix, '.'); dot >= 0 {
		package_name, owner = prefix[:dot], prefix[dot + 1:]
	}
	candidates := state.symbols_by_name[name][:]
	if name == "*" && owner != "" {
		candidates = state.symbols_by_owner_type[owner][:]
	}
	result := make([dynamic]Symbol, allocator)
	for id in candidates {
		symbol := state.symbols[int(id)]
		if symbol.kind == .Field {
			if owner != "" && symbol.owner_type == owner && matches_package(symbol, package_name) {
				append(&result, symbol)
			}
		} else if name != "*" && symbol.is_global && symbol.kind != .Import &&
		          symbol.kind != .Package && matches_package(symbol, prefix) {
			append(&result, symbol)
		}
	}
	slice.sort_by(result[:], symbol_less)
	return result[:]
}

matches_package :: proc(symbol: Symbol, package_name: string) -> bool {
	if package_name == "" || symbol.package_name == package_name ||
	   symbol.package_directory == package_name {
		return true
	}
	directory := symbol.package_directory
	start := len(directory) - len(package_name)
	return start > 0 && directory[start - 1] == '/' && directory[start:] == package_name
}

Diagnostic_Expression :: enum {Call, Literal}

expression_symbol_position :: proc(expr: ^ast.Expr) -> (Source_Position, bool) {
	if expr == nil { return {}, false }
	#partial switch value in expr.derived {
	case ^ast.Ident:
		return range_from_ident(value).start, true
	case ^ast.Selector_Expr:
		return range_from_ident(value.field).start, true
	}
	return {}, false
}

procedure_group_members :: proc(state: ^Analysis_Context, symbol: Symbol, allocator: runtime.Allocator) -> []Symbol {
	file_id, found := state.files_by_path[symbol.path]
	if !found { return nil }
	Search :: struct {
		position: Source_Position,
		group:    ^ast.Proc_Group,
	}
	search := Search{position = symbol.range.start}
	visitor := ast.Visitor{data = &search, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil { return v }
		search := cast(^Search)v.data
		if !range_contains(range_from_node(node), search.position.line, search.position.column) {
			return nil
		}
		if declaration, ok := node.derived.(^ast.Value_Decl); ok {
			for name, index in declaration.names {
				if name.pos.offset == search.position.offset && index < len(declaration.values) {
					search.group, _ = declaration.values[index].derived.(^ast.Proc_Group)
					return nil
				}
			}
		}
		return v
	}}
	for statement in state.files[int(file_id)].ast_file.decls {
		ast.walk(&visitor, cast(^ast.Node)statement)
		if search.group != nil { break }
	}
	if search.group == nil { return nil }
	result := make([dynamic]Symbol, allocator)
	for member in search.group.args {
		position, ok := expression_symbol_position(member)
		if !ok { continue }
		location := location_for_position(state, symbol.path, position.line, position.column, context.temp_allocator)
		for candidate in location.locations {
			if candidate.kind == .Procedure { append(&result, candidate) }
		}
	}
	return result[:]
}

diagnostic_declarations :: proc(
	state: ^Analysis_Context,
	path: string,
	line, column: int,
	expression: Diagnostic_Expression,
	allocator := context.allocator,
) -> []Symbol {
	file_id, found := state.files_by_path[path]
	if !found { return nil }
	file := &state.files[int(file_id)]
	Search :: struct {
		line, column: int,
		expression:   Diagnostic_Expression,
		position:     Source_Position,
		start:        int,
	}
	search := Search{line = line, column = column, expression = expression, start = -1}
	visitor := ast.Visitor{data = &search, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil { return v }
		search := cast(^Search)v.data
		area := range_from_node(node)
		if !range_contains(area, search.line, search.column) { return nil }
		target: ^ast.Expr
		#partial switch value in node.derived {
		case ^ast.Call_Expr:
			if search.expression == .Call { target = value.expr }
		case ^ast.Comp_Lit:
			if search.expression == .Literal { target = value.type }
		}
		if position, ok := expression_symbol_position(target); ok && area.start.offset >= search.start {
			search.position, search.start = position, area.start.offset
		}
		return v
	}}
	for statement in file.ast_file.decls {
		ast.walk(&visitor, cast(^ast.Node)statement)
	}
	if search.start < 0 { return nil }
	location := location_for_position(state, path, search.position.line, search.position.column, allocator)
	if expression == .Literal { return location.locations }
	result := make([dynamic]Symbol, allocator)
	for symbol in location.locations {
		#partial switch symbol.kind {
		case .Procedure_Group:
			append(&result, symbol)
			append(&result, ..procedure_group_members(state, symbol, allocator))
		case .Procedure:
			append(&result, symbol)
		case .Variable, .Parameter, .Field:
			if strings.has_prefix(strings.trim_space(symbol.detail), "proc") {
				append(&result, symbol)
			}
		case:
		}
	}
	return result[:]
}
