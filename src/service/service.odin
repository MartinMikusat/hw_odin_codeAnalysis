package service

import "core:encoding/json"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

import "code_analysis:analysis"

VERSION :: "0.1.0"

Request :: struct {
	version:   int,
	command:   string,
	arguments: []string,
	compact:   bool,
}

Response :: struct {
	ok:      bool,
	payload: string,
	error:   string,
}

parse_position :: proc(arguments: []string, start: int) -> (line, column: int, ok: bool) {
	if start + 1 >= len(arguments) {
		return
	}
	line_ok, column_ok: bool
	line, line_ok = strconv.parse_int(arguments[start])
	column, column_ok = strconv.parse_int(arguments[start + 1])
	ok = line_ok && column_ok && line > 0 && column > 0
	return
}

encode :: proc(value: any, compact: bool, allocator := context.allocator) -> (string, bool) {
	options := json.Marshal_Options {
		pretty = !compact,
		use_spaces = true,
		spaces = 2,
		sort_maps_by_key = true,
		use_enum_names = true,
	}
	data, marshal_error := json.marshal(value, options, allocator)
	if marshal_error != nil {
		return "", false
	}
	return string(data), true
}

execute :: proc(
	state: ^analysis.Analysis_Context,
	request: Request,
	persistent := false,
	allocator := context.allocator,
) -> Response {
	if request.version != 1 {
		return Response{error = "unsupported protocol version"}
	}

	arguments := request.arguments
	command := request.command
	payload: string
	ok := false

	switch command {
	case "status":
		current_status := analysis.status(state, persistent)
		if persistent {
			current_status.pid = int(posix.getpid())
		}
		payload, ok = encode(current_status, request.compact, allocator)
	case "outline":
		if len(arguments) != 1 {
			return Response{error = "outline requires FILE"}
		}
		path, _, _ := analysis.query_path(state, arguments[0], context.temp_allocator)
		payload, ok = encode(
			analysis.outline(state, path, context.temp_allocator),
			request.compact,
			allocator,
		)
	case "search":
		if len(arguments) != 1 {
			return Response{error = "search requires QUERY"}
		}
		payload, ok = encode(
			analysis.search(state, arguments[0], context.temp_allocator),
			request.compact,
			allocator,
		)
	case "inspect", "definition", "type-definition", "references", "callers", "callees",
	     "completion", "signature":
		if len(arguments) != 3 {
			return Response{error = "the command requires FILE LINE COLUMN"}
		}
		line, column, position_ok := parse_position(arguments, 1)
		if !position_ok {
			return Response{error = "LINE and COLUMN must be positive integers"}
		}
		path, _, _ := analysis.query_path(state, arguments[0], context.temp_allocator)
		switch command {
		case "inspect", "signature":
			payload, ok = encode(
				analysis.inspect(state, path, line, column, context.temp_allocator),
				request.compact,
				allocator,
			)
		case "definition":
			payload, ok = encode(
				analysis.location_for_position(
					state,
					path,
					line,
					column,
					context.temp_allocator,
				),
				request.compact,
				allocator,
			)
		case "type-definition":
			payload, ok = encode(
				analysis.type_definition_for_position(
					state,
					path,
					line,
					column,
					context.temp_allocator,
				),
				request.compact,
				allocator,
			)
		case "references":
			payload, ok = encode(
				analysis.references(state, path, line, column, context.temp_allocator),
				request.compact,
				allocator,
			)
		case "callers":
			payload, ok = encode(
				analysis.callers(state, path, line, column, context.temp_allocator),
				request.compact,
				allocator,
			)
		case "callees":
			payload, ok = encode(
				analysis.callees(state, path, line, column, context.temp_allocator),
				request.compact,
				allocator,
			)
		case "completion":
			payload, ok = encode(
				analysis.completion(state, path, line, column, context.temp_allocator),
				request.compact,
				allocator,
			)
		}
	case "imports":
		if len(arguments) != 1 {
			return Response{error = "imports requires FILE or --workspace"}
		}
		path := ""
		if arguments[0] != "--workspace" {
			path, _, _ = analysis.query_path(state, arguments[0], context.temp_allocator)
		}
		payload, ok = encode(
			analysis.imports_for_file(state, path, context.temp_allocator),
			request.compact,
			allocator,
		)
	case "rename":
		if len(arguments) != 4 {
			return Response{error = "rename requires FILE LINE COLUMN NEW_NAME"}
		}
		line, column, position_ok := parse_position(arguments, 1)
		if !position_ok {
			return Response{error = "LINE and COLUMN must be positive integers"}
		}
		path, _, _ := analysis.query_path(state, arguments[0], context.temp_allocator)
		if !analysis.valid_identifier(arguments[3]) {
			return Response{error = "NEW_NAME must be a valid Odin identifier"}
		}
		target := analysis.location_for_position(
			state,
			path,
			line,
			column,
			context.temp_allocator,
		)
		if target.resolution == .Unresolved {
			return Response{error = "rename target is unresolved"}
		}
		if target.resolution == .Ambiguous || len(target.locations) != 1 {
			return Response{error = "rename target is ambiguous"}
		}
		if analysis.symbol_is_builtin(state, target.locations[0]) {
			return Response{error = "rename target is a read-only built-in"}
		}
		if !analysis.symbol_occurrences_are_complete(state, target.locations[0]) {
			return Response{error = "rename target is in a read-only dependency"}
		}
		if !analysis.rename_is_safe(
			state,
			path,
			line,
			column,
			arguments[3],
		) {
			return Response{error = "rename would collide with an existing declaration"}
		}
		payload, ok = encode(
			analysis.rename_plan(
				state,
				path,
				line,
				column,
				arguments[3],
				context.temp_allocator,
			),
			request.compact,
			allocator,
		)
	case "diagnostics":
		if len(arguments) != 1 {
			return Response{error = "diagnostics requires FILE or --workspace"}
		}
		target := state.root
		if arguments[0] != "--workspace" {
			_, absolute, _ := analysis.query_path(
				state,
				arguments[0],
				context.temp_allocator,
			)
			target = filepath.dir(absolute)
		}
		diagnostics, diagnostics_ok := analysis.run_diagnostics(
			state,
			target,
			context.temp_allocator,
		)
		if !diagnostics_ok {
			return Response{error = "failed to run Odin diagnostics"}
		}
		payload, ok = encode(diagnostics, request.compact, allocator)
	case:
		return Response{error = strings.join({"unknown command: ", command}, "", allocator)}
	}

	if !ok {
		return Response{error = "failed to encode the command result"}
	}
	return Response{ok = true, payload = payload}
}
