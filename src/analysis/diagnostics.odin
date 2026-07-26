package analysis

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

Checker_Position :: struct {
	file:       string,
	offset:     int,
	line:       int,
	column:     int,
	end_column: int,
}

Checker_Error :: struct {
	type: string,
	pos:  Checker_Position,
	msgs: []string,
}

Checker_Output :: struct {
	error_count: int,
	errors:      []Checker_Error,
}

run_diagnostics :: proc(
	state: ^Analysis_Context,
	target: string,
	allocator := context.allocator,
) -> ([]Diagnostic, bool) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, state.config.odin_command)
	append(&command, "check")
	append(&command, target)
	append(&command, "-json-errors")
	for collection in state.config.collections {
		collection_path := collection.path
		if !filepath.is_abs(collection_path) {
			collection_path, _ = filepath.join(
				{state.root, collection_path},
				context.temp_allocator,
			)
		}
		append(
			&command,
			strings.join(
				{"-collection:", collection.name, "=", collection_path},
				"",
				context.temp_allocator,
			),
		)
	}
	for argument in state.config.checker_args {
		append(&command, argument)
	}

	process_state, stdout, stderr, process_error := os.process_exec(
		os.Process_Desc{command = command[:], working_dir = state.root},
		context.temp_allocator,
	)
	if process_error != nil {
		return nil, false
	}

	payload := stdout
	if len(payload) == 0 {
		payload = stderr
	}
	if len(payload) == 0 {
		return []Diagnostic{}, process_state.exit_code == 0
	}

	checker_output: Checker_Output
	if parse_error := json.unmarshal(payload, &checker_output, allocator = context.temp_allocator); parse_error != nil {
		return nil, false
	}

	result := make([]Diagnostic, len(checker_output.errors), allocator)
	for value, index in checker_output.errors {
		path := value.pos.file
		if filepath.is_abs(path) {
			path = relative_path(state.root, path, allocator)
		} else {
			path = strings.clone(path, allocator)
		}
		message := strings.join(value.msgs, "\n", allocator)
		severity := Diagnostic_Severity.Error
		if value.type == "warning" {
			severity = .Warning
		}
		result[index] = Diagnostic {
			path = path,
			range = {
				start = {
					line = max(value.pos.line, 1),
					column = max(value.pos.column, 1),
					offset = max(value.pos.offset, 0),
				},
				end = {
					line = max(value.pos.line, 1),
					column = max(value.pos.end_column, value.pos.column + 1),
					offset = max(value.pos.offset, 0),
				},
			},
			severity = severity,
			message = message,
			source = "odin check",
		}
	}
	return result, true
}
