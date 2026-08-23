package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "code_analysis:analysis"
import "code_analysis:service"
import "code_analysis:transport"
import "code_analysis:usage"
import "code_analysis:watcher"

IDLE_TIMEOUT_SECONDS :: 15 * 60
REQUEST_READ_TIMEOUT :: 1 * time.Second

print_usage :: proc() {
	fmt.println(`hw-odin-analyze [--root PATH] [--compact] [--tsv] COMMAND

Commands:
  capability-audit < INPUT.json
  mcp
  usage status
  usage summary [--days N]
  usage recent [--days N] [--tool NAME] [--limit N] [--include-payloads]
  outline FILE
  search QUERY
  inspect FILE LINE COLUMN
  definition FILE LINE COLUMN
  type-definition FILE LINE COLUMN
  references FILE LINE COLUMN
  callers FILE LINE COLUMN
  callees FILE LINE COLUMN
  completion FILE LINE COLUMN
  signature FILE LINE COLUMN
  diagnostics FILE
  diagnostics --workspace
  imports FILE
  imports --workspace
  rename FILE LINE COLUMN NEW_NAME
  status
  restart
  stop
  version
  help

--tsv writes outline, search, and package-api results as tab-separated
rows (line, kind, name, detail) instead of JSON. Kind names are short
(proc, struct, enum, ...) and details are flattened to one line.`)
}

fail :: proc(message: string) -> ! {
	fmt.eprintln("hw-odin-analyze:", message)
	os.exit(1)
}

parse_arguments :: proc() -> (
	root: string,
	root_explicit: bool,
	compact: bool,
	tsv: bool,
	arguments: [dynamic]string,
) {
	root_error: os.Error
	root, root_error = os.get_working_directory(context.allocator)
	if root_error != nil {
		fail("failed to read the working directory")
	}
	arguments = make([dynamic]string, context.temp_allocator)
	for index := 1; index < len(os.args); index += 1 {
		argument := os.args[index]
		if argument == "--compact" {
			compact = true
		} else if argument == "--tsv" {
			tsv = true
		} else if argument == "--root" {
			if index + 1 >= len(os.args) {
				fail("--root requires a path")
			}
			index += 1
			delete(root)
			root, root_error = os.get_absolute_path(os.args[index], context.allocator)
			if root_error != nil {
				fail("failed to resolve the analysis root")
			}
			root_explicit = true
		} else {
			append(&arguments, argument)
		}
	}
	return
}

write_json :: proc(value: any, compact: bool) {
	options := json.Marshal_Options {
		pretty = !compact,
		use_spaces = true,
		spaces = 2,
		sort_maps_by_key = true,
		use_enum_names = true,
	}
	data, marshal_error := json.marshal(
		value,
		options,
		context.temp_allocator,
	)
	if marshal_error != nil {
		fail("failed to encode JSON output")
	}
	fmt.println(string(data))
}

tsv_kind :: proc(kind: analysis.Symbol_Kind) -> string {
	#partial switch kind {
	case .Package:         return "pkg"
	case .Import:          return "imp"
	case .Constant:        return "const"
	case .Variable:        return "var"
	case .Procedure:       return "proc"
	case .Procedure_Group: return "procs"
	case .Struct:          return "struct"
	case .Union:           return "union"
	case .Enum:            return "enum"
	case .Field:           return "field"
	case .Parameter:       return "param"
	}
	return "?"
}

// Collapse tabs and whitespace runs so every row stays a single line with
// exactly four tab-separated fields.
tsv_flatten_detail :: proc(detail: string, allocator := context.allocator) -> string {
	flattened := make([dynamic]u8, 0, len(detail), allocator)
	prior_space := false
	for byte_value in detail {
		is_space := byte_value == ' ' || byte_value == '	' || byte_value == '\n' || byte_value == '\r'
		if is_space {
			if prior_space { continue }
			prior_space = true
			append(&flattened, u8(' '))
		} else {
			prior_space = false
			append(&flattened, u8(byte_value))
		}
	}
	return transmute(string)flattened[:]
}

// Write []Symbol rows in the compact agent-facing form:
// line, short kind, name, one-line detail.
write_symbols_tsv :: proc(symbols: []analysis.Symbol) {
	builder := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(
		&builder,
		"line	kind	name	detail\n",
	)
	for symbol in symbols {
		name, _ := strings.replace_all(symbol.name, "	", " ", context.temp_allocator)
		detail := tsv_flatten_detail(symbol.detail, context.temp_allocator)
		detail, _ = strings.replace_all(detail, "	", " ", context.temp_allocator)
		fmt.sbprintf(
			&builder,
			"%d	%s	%s	%s\n",
			symbol.range.start.line,
			tsv_kind(symbol.kind),
			name,
			detail,
		)
	}
	fmt.println(strings.to_string(builder))
}

parse_positive_option :: proc(name, source: string, maximum: int) -> int {
	value, parsed := strconv.parse_int(source)
	if !parsed || value <= 0 || value > maximum {
		fail(fmt.aprintf(
			"%s must be between 1 and %d",
			name,
			maximum,
			allocator = context.temp_allocator,
		))
	}
	return value
}

run_usage_report :: proc(
	root: string,
	root_explicit, compact: bool,
	arguments: []string,
) {
	if len(arguments) < 2 {
		fail("usage requires status, summary, or recent")
	}
	command := arguments[1]
	if command == "status" {
		if len(arguments) != 2 {
			fail("usage status accepts no report options")
		}
		report, ok := usage.status(context.temp_allocator)
		if !ok {
			fail("usage database does not exist or has an unsupported schema")
		}
		write_json(report, compact)
		return
	}
	if command != "summary" && command != "recent" {
		fail("usage requires status, summary, or recent")
	}
	days := 30
	limit := 50
	tool_filter := ""
	include_payloads := false
	for index := 2; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--days":
			if index + 1 >= len(arguments) {
				fail("--days requires a value")
			}
			index += 1
			days = parse_positive_option("--days", arguments[index], 36500)
		case "--tool":
			if command != "recent" || index + 1 >= len(arguments) {
				fail("--tool is valid only for usage recent and requires a value")
			}
			index += 1
			tool_filter = arguments[index]
		case "--limit":
			if command != "recent" || index + 1 >= len(arguments) {
				fail("--limit is valid only for usage recent and requires a value")
			}
			index += 1
			limit = parse_positive_option("--limit", arguments[index], 1000)
		case "--include-payloads":
			if command != "recent" {
				fail("--include-payloads is valid only for usage recent")
			}
			include_payloads = true
		case:
			fail(fmt.aprintf("unknown usage option: %s", arguments[index], allocator = context.temp_allocator))
		}
	}
	root_filter := root if root_explicit else ""
	if command == "summary" {
		report, ok := usage.summary(days, root_filter, context.temp_allocator)
		if !ok {
			fail("failed to read the usage summary")
		}
		write_json(report, compact)
		return
	}
	report, ok := usage.recent(
		days,
		root_filter,
		tool_filter,
		limit,
		include_payloads,
		context.temp_allocator,
	)
	if !ok {
		fail("failed to read recent usage")
	}
	write_json(report, compact)
}

marshal_request :: proc(
	command: string,
	arguments: []string,
	compact: bool,
	allocator := context.allocator,
) -> ([]byte, bool) {
	request := service.Request {
		version = 1,
		command = command,
		arguments = arguments,
		compact = compact,
	}
	data, marshal_error := json.marshal(request, allocator = allocator)
	return data, marshal_error == nil
}

send_request :: proc(
	socket_path: string,
	command: string,
	arguments: []string,
	compact: bool,
	allocator := context.allocator,
) -> (response: service.Response, ok: bool) {
	socket, connected := transport.connect(socket_path)
	if !connected {
		return
	}
	defer posix.close(socket)

	request_data, encoded := marshal_request(
		command,
		arguments,
		compact,
		context.temp_allocator,
	)
	if !encoded || !transport.send_message(socket, request_data) {
		return
	}
	response_data, received := transport.receive_message(socket, context.temp_allocator)
	if !received {
		return
	}
	if decode_error := json.unmarshal(response_data, &response, allocator = allocator);
	   decode_error != nil {
		return
	}
	ok = true
	return
}

start_daemon :: proc(root: string, paths: transport.Runtime_Paths) -> bool {
	executable, executable_error := os.get_executable_path(context.temp_allocator)
	if executable_error != nil {
		return false
	}
	command := []string{executable, "--root", root, "__daemon"}
	_, process_error := os.process_start(
		os.Process_Desc {
			working_dir = root,
			command = command,
		},
	)
	if process_error != nil {
		return false
	}

	for attempt := 0; attempt < 2000; attempt += 1 {
		socket, connected := transport.connect(paths.socket_path)
		if connected {
			posix.close(socket)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

run_capability_client :: proc(root: string, compact: bool) {
	input := make([dynamic]byte, context.temp_allocator)
	buffer: [4096]byte
	for {
		count, read_error := os.read(os.stdin, buffer[:])
		if count > 0 {
			append(&input, ..buffer[:count])
		}
		if read_error != nil || count == 0 {
			break
		}
	}
	if len(input) > 1024 * 1024 {
		fail("capability-audit input exceeds 1 MiB")
	}
	audit_input: analysis.Capability_Audit_Input
	if decode_error := json.unmarshal(
		input[:],
		&audit_input,
		allocator = context.temp_allocator,
	); decode_error != nil {
		fail("capability-audit input is invalid JSON")
	}
	result, audit_error, audit_ok := analysis.capability_audit_workspace(
		root,
		audit_input,
		context.temp_allocator,
	)
	if !audit_ok {
		fail(audit_error)
	}
	options := json.Marshal_Options {
		pretty = !compact,
		use_spaces = true,
		spaces = 2,
		sort_maps_by_key = true,
		use_enum_names = true,
	}
	payload, marshal_error := json.marshal(
		result,
		options,
		context.temp_allocator,
	)
	if marshal_error != nil {
		fail("failed to encode capability-audit result")
	}
	fmt.println(string(payload))
}

MCP_PROTOCOL_VERSION :: "2025-11-25"

MCP_Client_Info :: struct {
	name: string,
	version: string,
}

MCP_Request_Params :: struct {
	name:             string,
	arguments:        json.Value,
	protocol_version: string          `json:"protocolVersion"`,
	client_info:      MCP_Client_Info `json:"clientInfo"`,
}

MCP_Query :: struct {
	query: string,
	symbol_id: Maybe(int),
	generation: u64,
	file: string,
	line: int,
	column: int,
	new_name: string,
	scope: string,
}

MCP_Query_Input :: struct {
	queries: []MCP_Query,
}

MCP_Roots :: struct {
	workspace: string,
	compiler:  string,
}

MCP_Batch_Result :: struct {
	generation:    u64,
	config_digest: string,
	roots:         MCP_Roots,
	truncated:     bool,
	results:       []json.Value,
}

MCP_Capability_Match :: struct {
	name:             string,
	kind:             string,
	qualified_symbol: string,
	import_path:      string `json:"import_path,omitempty"`,
	source:           string,
	file:             string,
	line:             int,
	rank:             int,
}

MCP_Capability_Primitive_Result :: struct {
	id:      string,
	status:  string,
	matches: []MCP_Capability_Match,
}

MCP_Capability_Result :: struct {
	generation:    u64,
	config_digest: string,
	roots:         MCP_Roots,
	match_limit:   int,
	truncated:     bool,
	results:       []MCP_Capability_Primitive_Result,
}

MCP_Definition_References :: struct {
	definition: json.Value,
	references: json.Value,
}

MCP_Call_Graph :: struct {
	callers: json.Value,
	callees: json.Value,
}

MCP_Impact :: struct {
	definition: json.Value,
	references: json.Value,
	callers: json.Value,
	callees: json.Value,
	imports: json.Value,
	affected_packages: []string,
	relevant_tests: []string,
	configuration_files: []string,
}

MCP_Request :: struct {
	jsonrpc: string,
	id:      json.Value,
	method:  string,
	params:  MCP_Request_Params,
}

MCP_Response :: struct {
	jsonrpc: string,
	id:      json.Value,
	result:  json.Value,
}

MCP_Initialize_Tool_Capabilities :: struct {
	list_changed: bool `json:"listChanged"`,
}

MCP_Initialize_Capabilities :: struct {
	tools: MCP_Initialize_Tool_Capabilities,
}

MCP_Server_Info :: struct {
	name: string,
	version: string,
}

MCP_Initialize_Result :: struct {
	protocol_version: string `json:"protocolVersion"`,
	capabilities: MCP_Initialize_Capabilities,
	server_info: MCP_Server_Info `json:"serverInfo"`,
}

MCP_Initialize_Response :: struct {
	jsonrpc: string,
	id: json.Value,
	result: MCP_Initialize_Result,
}

MCP_Error_Value :: struct {
	code:    int,
	message: string,
}

MCP_Error_Response :: struct {
	jsonrpc: string,
	id:      json.Value,
	error:   MCP_Error_Value,
}

MCP_Content :: struct {
	type: string,
	text: string,
}

MCP_Call_Result :: struct {
	content:            []MCP_Content,
	structured_content: json.Value `json:"structuredContent,omitempty"`,
	is_error:           bool       `json:"isError,omitempty"`,
}

MCP_Call_Response :: struct {
	jsonrpc: string,
	id:      json.Value,
	result:  MCP_Call_Result,
}

MCP_Tool :: struct {
	name: string,
	description: string,
	input_schema: json.Value `json:"inputSchema"`,
}

MCP_Tool_List :: struct {
	tools: []MCP_Tool,
}

MCP_Usage_Context :: struct {
	store: ^usage.Store,
	event: ^usage.Event,
	started: time.Tick,
	recorded: bool,
}

MCP_Query_Metrics :: struct {
	empty_result_count: int,
	ambiguous_count: int,
	unresolved_count: int,
	truncated: bool,
}

mcp_usage_context: ^MCP_Usage_Context

mcp_metrics_add_resolution :: proc(
	metrics: ^MCP_Query_Metrics,
	value: json.Value,
) {
	#partial switch resolution in value {
	case json.String:
		if resolution == "Ambiguous" {
			metrics.ambiguous_count += 1
		} else if resolution == "Unresolved" {
			metrics.unresolved_count += 1
		}
	}
}

mcp_query_metrics :: proc(command: string, value: json.Value) -> MCP_Query_Metrics {
	metrics: MCP_Query_Metrics
	#partial switch concrete in value {
	case json.Null:
		metrics.empty_result_count = 1
	case json.Array:
		if len(concrete) == 0 {
			metrics.empty_result_count = 1
		}
	case json.Object:
		if len(concrete) == 0 {
			metrics.empty_result_count = 1
		}
		if truncated, found := concrete["truncated"]; found {
			#partial switch is_truncated in truncated {
			case json.Boolean:
				metrics.truncated = is_truncated
			}
		}
		resolution_target := value
		if command == "definition_and_references" || command == "impact_analysis" {
			if definition, found := concrete["definition"]; found {
				resolution_target = definition
			}
		}
		#partial switch result in resolution_target {
		case json.Object:
			if resolution, found := result["resolution"]; found {
				mcp_metrics_add_resolution(&metrics, resolution)
			}
		}
	}
	return metrics
}

mcp_metrics_add :: proc(target: ^MCP_Query_Metrics, source: MCP_Query_Metrics) {
	target.empty_result_count += source.empty_result_count
	target.ambiguous_count += source.ambiguous_count
	target.unresolved_count += source.unresolved_count
	target.truncated = target.truncated || source.truncated
}

mcp_usage_finish :: proc() {
	if mcp_usage_context == nil || mcp_usage_context.recorded {
		return
	}
	mcp_usage_context.event.duration_ns = i64(time.tick_since(mcp_usage_context.started))
	_ = usage.store_record(mcp_usage_context.store, mcp_usage_context.event^)
	mcp_usage_context.recorded = true
}

mcp_write :: proc(value: any) {
	data, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	if marshal_error != nil {
		return
	}
	fmt.println(string(data))
	if mcp_usage_context != nil && !mcp_usage_context.recorded {
		mcp_usage_context.event.response_line = data
		mcp_usage_finish()
	}
}

mcp_parse_value :: proc(source: string) -> (json.Value, bool) {
	value: json.Value
	if parse_error := json.unmarshal(
		transmute([]byte)source,
		&value,
		allocator = context.temp_allocator,
	); parse_error != nil {
		return {}, false
	}
	return value, true
}

mcp_decode_arguments :: proc(value: json.Value, destination: ^$T) -> bool {
	data, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	if marshal_error != nil {
		return false
	}
	return json.unmarshal(data, destination, allocator = context.temp_allocator) == nil
}

mcp_json_copy :: proc(
	target: ^json.Object,
	source: json.Object,
	source_name, target_name: string,
) {
	if value, found := source[source_name]; found {
		target^[target_name] = value
	}
}

mcp_json_copy_nonempty :: proc(
	target: ^json.Object,
	source: json.Object,
	source_name, target_name: string,
) {
	value, found := source[source_name]
	if !found {
		return
	}
	#partial switch concrete in value {
	case json.String:
		if concrete != "" {
			target^[target_name] = value
		}
	case json.Boolean:
		if concrete {
			target^[target_name] = value
		}
	case:
		target^[target_name] = value
	}
}

mcp_json_copy_start :: proc(
	target: ^json.Object,
	source: json.Object,
	range_name: string,
) {
	range_value, range_found := source[range_name]
	if !range_found {
		return
	}
	#partial switch range in range_value {
	case json.Object:
		start_value, start_found := range["start"]
		if !start_found {
			return
		}
		#partial switch start in start_value {
		case json.Object:
			mcp_json_copy(target, start, "line", "line")
			mcp_json_copy(target, start, "column", "column")
		}
	}
}

mcp_json_copy_end :: proc(
	target: ^json.Object,
	source: json.Object,
	range_name: string,
) {
	range_value, range_found := source[range_name]
	if !range_found {
		return
	}
	#partial switch range in range_value {
	case json.Object:
		end_value, end_found := range["end"]
		if !end_found {
			return
		}
		#partial switch end in end_value {
		case json.Object:
			mcp_json_copy(target, end, "line", "end_line")
			mcp_json_copy(target, end, "column", "end_column")
		}
	}
}

mcp_compact_symbol :: proc(value: json.Value, detail := false) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "id", "symbol_id")
		mcp_json_copy(&result, source, "name", "name")
		mcp_json_copy(&result, source, "kind", "kind")
		mcp_json_copy(&result, source, "path", "file")
		mcp_json_copy_nonempty(&result, source, "package_name", "package")
		mcp_json_copy_nonempty(&result, source, "owner_type", "owner_type")
		mcp_json_copy_start(&result, source, "range")
		if detail {
			mcp_json_copy_nonempty(
				&result,
				source,
				"package_directory",
				"package_directory",
			)
			mcp_json_copy_nonempty(&result, source, "detail", "signature")
			mcp_json_copy_nonempty(
				&result,
				source,
				"documentation",
				"documentation",
			)
			mcp_json_copy_end(&result, source, "extent")
		}
		return result
	}
	return value
}

mcp_compact_symbol_array :: proc(value: json.Value, detail := false) -> json.Value {
	#partial switch source in value {
	case json.Array:
		result := make(json.Array, len(source), context.temp_allocator)
		for item, index in source {
			result[index] = mcp_compact_symbol(item, detail)
		}
		return result
	}
	return value
}

mcp_compact_location :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "resolution", "resolution")
		mcp_json_copy_nonempty(&result, source, "reason", "reason")
		mcp_json_copy_nonempty(&result, source, "next_action", "next_action")
		mcp_json_copy_nonempty(
			&result,
			source,
			"analyzer_boundary",
			"analyzer_boundary",
		)
		if locations, found := source["locations"]; found {
			result["symbols"] = mcp_compact_symbol_array(locations)
		}
		return result
	}
	return value
}

mcp_compact_inspect :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "resolution", "resolution")
		mcp_json_copy(&result, source, "reference_count", "reference_count")
		if symbols, found := source["symbols"]; found {
			result["symbols"] = mcp_compact_symbol_array(symbols, true)
		}
		if definitions, found := source["type_definitions"]; found {
			result["type_definitions"] = mcp_compact_symbol_array(definitions)
		}
		if explanation_value, found := source["explanation"]; found {
			#partial switch explanation in explanation_value {
			case json.Object:
				mcp_json_copy_nonempty(&result, explanation, "reason", "reason")
				mcp_json_copy_nonempty(
					&result,
					explanation,
					"next_action",
					"next_action",
				)
				mcp_json_copy_nonempty(
					&result,
					explanation,
					"analyzer_boundary",
					"analyzer_boundary",
				)
			}
		}
		return result
	}
	return value
}

mcp_compact_occurrence :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "name", "name")
		mcp_json_copy(&result, source, "path", "file")
		mcp_json_copy(&result, source, "symbol", "symbol_id")
		mcp_json_copy_nonempty(&result, source, "is_call", "is_call")
		mcp_json_copy_start(&result, source, "range")
		mcp_json_copy_end(&result, source, "range")
		return result
	}
	return value
}

mcp_compact_occurrence_array :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Array:
		result := make(json.Array, len(source), context.temp_allocator)
		for item, index in source {
			result[index] = mcp_compact_occurrence(item)
		}
		return result
	}
	return value
}

mcp_compact_import :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "path", "file")
		mcp_json_copy_nonempty(&result, source, "alias", "alias")
		mcp_json_copy(&result, source, "import_path", "import_path")
		mcp_json_copy(&result, source, "resolved_path", "resolved_path")
		mcp_json_copy_nonempty(&result, source, "is_using", "is_using")
		mcp_json_copy_start(&result, source, "range")
		return result
	}
	return value
}

mcp_compact_import_array :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Array:
		result := make(json.Array, len(source), context.temp_allocator)
		for item, index in source {
			result[index] = mcp_compact_import(item)
		}
		return result
	}
	return value
}

mcp_compact_diagnostic :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "path", "file")
		mcp_json_copy(&result, source, "severity", "severity")
		mcp_json_copy(&result, source, "message", "message")
		mcp_json_copy(&result, source, "source", "source")
		mcp_json_copy_start(&result, source, "range")
		mcp_json_copy_end(&result, source, "range")
		return result
	}
	return value
}

mcp_compact_diagnostic_array :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Array:
		result := make(json.Array, len(source), context.temp_allocator)
		for item, index in source {
			result[index] = mcp_compact_diagnostic(item)
		}
		return result
	}
	return value
}

mcp_compact_text_edit :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Object:
		result := make(json.Object, context.temp_allocator)
		mcp_json_copy(&result, source, "path", "file")
		mcp_json_copy(&result, source, "new_text", "new_text")
		mcp_json_copy_start(&result, source, "range")
		mcp_json_copy_end(&result, source, "range")
		return result
	}
	return value
}

mcp_compact_text_edit_array :: proc(value: json.Value) -> json.Value {
	#partial switch source in value {
	case json.Array:
		result := make(json.Array, len(source), context.temp_allocator)
		for item, index in source {
			result[index] = mcp_compact_text_edit(item)
		}
		return result
	}
	return value
}

mcp_compact_query_value :: proc(command: string, value: json.Value) -> json.Value {
	switch command {
	case "search", "outline", "package-api", "callers", "callees":
		return mcp_compact_symbol_array(value)
	case "inspect":
		return mcp_compact_inspect(value)
	case "definition":
		return mcp_compact_location(value)
	case "references":
		return mcp_compact_occurrence_array(value)
	case "imports":
		return mcp_compact_import_array(value)
	case "diagnostics":
		return mcp_compact_diagnostic_array(value)
	case "rename":
		return mcp_compact_text_edit_array(value)
	}
	return value
}

mcp_resolve_query_identity :: proc(
	state: ^analysis.Analysis_Context,
	input_query: MCP_Query,
) -> (MCP_Query, string, bool) {
	query := input_query
	if query.generation != 0 && query.generation != state.generation {
		return {}, "query generation does not match the published index", false
	}
	if symbol_id, supplied := query.symbol_id.?; supplied {
		if symbol_id < 0 || symbol_id >= len(state.symbols) {
			return {}, "symbol_id is outside the published generation", false
		}
		symbol := state.symbols[symbol_id]
		query.file = symbol.path
		query.line = symbol.range.start.line
		query.column = symbol.range.start.column
		query.symbol_id = nil
	}
	return query, "", true
}

mcp_execute_query :: proc(
	state: ^analysis.Analysis_Context,
	command: string,
	input_query: MCP_Query,
) -> (json.Value, string, bool) {
	query, resolve_error, resolved := mcp_resolve_query_identity(state, input_query)
	if !resolved {
		return {}, resolve_error, false
	}
	arguments := make([dynamic]string, context.temp_allocator)
	switch command {
	case "search", "package-api":
		if strings.trim_space(query.query) == "" { return {}, "query is required", false }
		append(&arguments, query.query)
	case "outline", "imports", "diagnostics":
		target := query.file
		if query.scope == "workspace" { target = "--workspace" }
		if target == "" { return {}, "file or workspace scope is required", false }
		append(&arguments, target)
	case "rename":
		if query.file == "" || query.line <= 0 || query.column <= 0 || query.new_name == "" {
			return {}, "file, positive line and column, and new_name are required", false
		}
		append(&arguments, query.file, fmt.aprintf("%d", query.line), fmt.aprintf("%d", query.column), query.new_name)
	case:
		if query.file == "" || query.line <= 0 || query.column <= 0 {
			return {}, "file and positive line and column are required", false
		}
		append(&arguments, query.file, fmt.aprintf("%d", query.line), fmt.aprintf("%d", query.column))
	}
	response := service.execute(
		state,
		service.Request{version = 1, command = command, arguments = arguments[:], compact = true},
		persistent = true,
		allocator = context.temp_allocator,
	)
	if !response.ok { return {}, response.error, false }
	value, parsed := mcp_parse_value(response.payload)
	if !parsed { return {}, "failed to decode analysis result", false }
	return mcp_compact_query_value(command, value), "", true
}

mcp_composite_value :: proc(value: any) -> (json.Value, bool) {
	data, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	if marshal_error != nil { return {}, false }
	return mcp_parse_value(string(data))
}

mcp_execute_composite :: proc(
	state: ^analysis.Analysis_Context,
	mode: string,
	input_query: MCP_Query,
) -> (json.Value, string, bool) {
	query, resolve_error, resolved := mcp_resolve_query_identity(state, input_query)
	if !resolved {
		return {}, resolve_error, false
	}
	if mode == "definition_and_references" {
		definition, error, ok := mcp_execute_query(state, "definition", query); if !ok { return {}, error, false }
		references, error_2, ok_2 := mcp_execute_query(state, "references", query); if !ok_2 { return {}, error_2, false }
		value, encoded := mcp_composite_value(MCP_Definition_References{definition = definition, references = references})
		return value, "failed to encode definition and references", encoded
	}
	if mode == "call_graph" {
		callers, error, ok := mcp_execute_query(state, "callers", query); if !ok { return {}, error, false }
		callees, error_2, ok_2 := mcp_execute_query(state, "callees", query); if !ok_2 { return {}, error_2, false }
		value, encoded := mcp_composite_value(MCP_Call_Graph{callers = callers, callees = callees})
		return value, "failed to encode call graph", encoded
	}
	definition, error, ok := mcp_execute_query(state, "definition", query); if !ok { return {}, error, false }
	references, error_2, ok_2 := mcp_execute_query(state, "references", query); if !ok_2 { return {}, error_2, false }
	callers, error_3, ok_3 := mcp_execute_query(state, "callers", query); if !ok_3 { return {}, error_3, false }
	callees, error_4, ok_4 := mcp_execute_query(state, "callees", query); if !ok_4 { return {}, error_4, false }
	imports, error_5, ok_5 := mcp_execute_query(state, "imports", query); if !ok_5 { return {}, error_5, false }
	affected_packages := make([dynamic]string, context.temp_allocator)
	relevant_tests := make([dynamic]string, context.temp_allocator)
	seen_packages := make(map[string]bool, context.temp_allocator)
	seen_tests := make(map[string]bool, context.temp_allocator)
	target, target_ok := analysis.symbol_at(state, query.file, query.line, query.column)
	if target_ok {
		for occurrence_index in state.occurrences_by_symbol[target.id] {
			occurrence := state.occurrences[occurrence_index]
			if !seen_packages[occurrence.package_name] {
				seen_packages[occurrence.package_name] = true
				append(&affected_packages, occurrence.package_name)
			}
			if (strings.contains(occurrence.path, "/test/") || strings.contains(occurrence.path, "/tests/") || strings.has_suffix(occurrence.path, "_test.odin")) && !seen_tests[occurrence.path] {
				seen_tests[occurrence.path] = true
				append(&relevant_tests, occurrence.path)
			}
		}
	}
	configuration_files := make([dynamic]string, context.temp_allocator)
	config_path, _ := filepath.join({state.root, "code-analysis.json"}, context.temp_allocator)
	if os.exists(config_path) { append(&configuration_files, config_path) }
	value, encoded := mcp_composite_value(MCP_Impact{
		definition = definition,
		references = references,
		callers = callers,
		callees = callees,
		imports = imports,
		affected_packages = affected_packages[:],
		relevant_tests = relevant_tests[:],
		configuration_files = configuration_files[:],
	})
	return value, "failed to encode impact analysis", encoded
}

mcp_run_batch :: proc(
	id: json.Value,
	state: ^analysis.Analysis_Context,
	arguments: json.Value,
	tool_name: string,
	command: string,
) {
	input: MCP_Query_Input
	if !mcp_decode_arguments(arguments, &input) {
		mcp_write_call_result(id, "invalid query batch", true)
		return
	}
	if len(input.queries) == 0 || len(input.queries) > 64 {
		mcp_write_call_result(id, "queries must contain between 1 and 64 entries", true)
		return
	}
	if mcp_usage_context != nil {
		mcp_usage_context.event.generation = state.generation
		mcp_usage_context.event.batch_size = len(input.queries)
	}
	batch_metrics: MCP_Query_Metrics
	results := make([]json.Value, len(input.queries), context.temp_allocator)
	for query, index in input.queries {
		value: json.Value
		query_error: string
		query_ok: bool
		if command == "definition_and_references" || command == "call_graph" || command == "impact_analysis" {
			value, query_error, query_ok = mcp_execute_composite(state, command, query)
		} else {
			value, query_error, query_ok = mcp_execute_query(state, command, query)
		}
		if !query_ok {
			mcp_write_call_result(id, query_error, true)
			return
		}
		results[index] = value
		mcp_metrics_add(&batch_metrics, mcp_query_metrics(command, value))
	}
	payload, marshal_error := json.marshal(
		MCP_Batch_Result{
			generation = state.generation,
			config_digest = state.config_digest,
			roots = {
				workspace = state.root,
				compiler = state.odin_root,
			},
			truncated = batch_metrics.truncated,
			results = results,
		},
		allocator = context.temp_allocator,
	)
	if marshal_error != nil { mcp_write_error(id, -32603, "failed to encode batch result"); return }
	if mcp_usage_context != nil {
		mcp_usage_context.event.result_count = len(results)
		mcp_usage_context.event.empty_result_count = batch_metrics.empty_result_count
		mcp_usage_context.event.ambiguous_count = batch_metrics.ambiguous_count
		mcp_usage_context.event.unresolved_count = batch_metrics.unresolved_count
		mcp_usage_context.event.truncated = batch_metrics.truncated
	}
	summary := fmt.aprintf(
		"ok: %s; queries=%d; generation=%d; truncated=%t",
		tool_name,
		len(input.queries),
		state.generation,
		batch_metrics.truncated,
		allocator = context.temp_allocator,
	)
	mcp_write_call_result(id, string(payload), summary = summary)
}

mcp_write_result :: proc(id: json.Value, source: string) {
	result, parsed := mcp_parse_value(source)
	if !parsed {
		mcp_write_error(id, -32603, "failed to encode MCP result")
		return
	}
	mcp_write(MCP_Response{jsonrpc = "2.0", id = id, result = result})
}

mcp_write_error :: proc(id: json.Value, code: int, message: string) {
	if mcp_usage_context != nil {
		mcp_usage_context.event.outcome = "protocol_error"
		mcp_usage_context.event.error_code = code
		mcp_usage_context.event.error_message = message
	}
	mcp_write(
		MCP_Error_Response {
			jsonrpc = "2.0",
			id = id,
			error = {code = code, message = message},
		},
	)
}

mcp_write_call_result :: proc(
	id: json.Value,
	payload: string,
	is_error := false,
	summary := "",
) {
	if is_error && mcp_usage_context != nil {
		mcp_usage_context.event.outcome = "tool_error"
		mcp_usage_context.event.error_message = payload
	}
	content_text := summary
	if is_error || content_text == "" {
		content_text = payload
	}
	content := [1]MCP_Content{{type = "text", text = content_text}}
	result := MCP_Call_Result {
		content = content[:],
		is_error = is_error,
	}
	if !is_error {
		structured, parsed := mcp_parse_value(payload)
		if !parsed {
			mcp_write_error(id, -32603, "failed to decode capability result")
			return
		}
		result.structured_content = structured
	}
	mcp_write(MCP_Call_Response{jsonrpc = "2.0", id = id, result = result})
}

mcp_compact_capability_result :: proc(
	result: analysis.Capability_Audit_Result,
) -> (MCP_Capability_Result, int) {
	compact_results := make(
		[]MCP_Capability_Primitive_Result,
		len(result.results),
		context.temp_allocator,
	)
	match_count := 0
	for primitive, primitive_index in result.results {
		matches := make(
			[]MCP_Capability_Match,
			len(primitive.matches),
			context.temp_allocator,
		)
		for match, match_index in primitive.matches {
			matches[match_index] = {
				name = match.name,
				kind = match.kind,
				qualified_symbol = match.qualified_symbol,
				import_path = match.import_path,
				source = match.source,
				file = match.file,
				line = match.line,
				rank = match.rank,
			}
		}
		match_count += len(matches)
		compact_results[primitive_index] = {
			id = primitive.id,
			status = primitive.status,
			matches = matches,
		}
	}
	return MCP_Capability_Result{
		generation = result.generation,
		config_digest = result.config_digest,
		roots = {
			workspace = result.query_scope,
			compiler = result.compiler_root,
		},
		match_limit = result.result_limit,
		truncated = result.truncated,
		results = compact_results,
	}, match_count
}

run_mcp :: proc(root: string) {
	state: analysis.Analysis_Context
	if !analysis.context_prepare(&state, root) {
		fail("failed to prepare the initial analysis context")
	}
	defer analysis.context_destroy(&state)
	catalog: analysis.Capability_Catalog
	defer analysis.capability_catalog_destroy(&catalog)
	usage_store: usage.Store
	_ = usage.store_init(
		&usage_store,
		root,
		service.VERSION,
		filepath.base(state.odin_root),
		state.odin_root,
		state.config_digest,
	)
	defer usage.store_destroy(&usage_store)
	_ = usage.store_prune_payloads(&usage_store)
	catalog_watcher: watcher.Watcher
	catalog_watcher_started := false
	workspace_ready := false
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_stream(os.stdin))
	defer bufio.scanner_destroy(&scanner)
	for bufio.scanner_scan(&scanner) {
		free_all(context.temp_allocator)
		raw_line := bufio.scanner_text(&scanner)
		event := usage.Event {
			event_kind = "request",
			outcome = "ok",
			received_at_ns = usage.now_unix_ns(),
			request_line = transmute([]byte)raw_line,
		}
		usage_context := MCP_Usage_Context {
			store = &usage_store,
			event = &event,
			started = time.tick_now(),
		}
		mcp_usage_context = &usage_context
		if workspace_ready {
			watcher.flush(&catalog_watcher)
		}
		if workspace_ready && watcher.consume_dirty(&catalog_watcher) {
			candidate: analysis.Capability_Catalog
			analysis_candidate: analysis.Analysis_Context
			catalog_ok := false
			_, catalog_ok = analysis.capability_catalog_init(&candidate, root)
			analysis_ok := analysis.context_build_candidate(&state, &analysis_candidate)
			if catalog_ok && analysis_ok {
				candidate.generation = catalog.generation + 1
				previous := catalog
				catalog = candidate
				analysis.capability_catalog_destroy(&previous)
				analysis.context_publish_candidate(&state, &analysis_candidate)
				_ = usage.store_update_context(
					&usage_store,
					filepath.base(state.odin_root),
					state.odin_root,
					state.config_digest,
				)
			} else {
				if catalog_ok { analysis.capability_catalog_destroy(&candidate) }
				if analysis_ok { analysis.context_destroy(&analysis_candidate) }
				watcher.mark_dirty(&catalog_watcher)
			}
		}
		line := strings.trim_space(raw_line)
		if line == "" {
			event.event_kind = "ignored_blank"
			event.outcome = "ignored"
			mcp_usage_finish()
			continue
		}
		request: MCP_Request
		if decode_error := json.unmarshal(
			transmute([]byte)line,
			&request,
			allocator = context.temp_allocator,
		); decode_error != nil {
			event.event_kind = "parse_error"
			mcp_write_error({}, -32700, "invalid JSON-RPC request")
			continue
		}
		event.method = request.method
		if request.method == "tools/call" {
			event.tool_name = request.params.name
		}
		if request.jsonrpc != "2.0" {
			mcp_write_error(request.id, -32600, "jsonrpc must be 2.0")
			continue
		}
		if request.method == "tools/call" && !workspace_ready {
			analysis_candidate: analysis.Analysis_Context
			if !analysis.context_build_candidate(&state, &analysis_candidate) {
				fail("failed to build the initial analysis index")
			}
			analysis.context_publish_candidate(&state, &analysis_candidate)
			if catalog_error, catalog_ok := analysis.capability_catalog_init(&catalog, root); !catalog_ok {
				fail(catalog_error)
			}
			base_root, _ := filepath.join({catalog.odin_root, "base"}, context.temp_allocator)
			core_root, _ := filepath.join({catalog.odin_root, "core"}, context.temp_allocator)
			vendor_root, _ := filepath.join({catalog.odin_root, "vendor"}, context.temp_allocator)
			catalog_watch_roots := [4]string{
				catalog.workspace_root,
				base_root,
				core_root,
				vendor_root,
			}
			if !watcher.start(&catalog_watcher, catalog_watch_roots[:]) {
				fail("failed to start the capability catalog watcher")
			}
			catalog_watcher_started = true
			watcher.flush(&catalog_watcher)
			_ = watcher.consume_dirty(&catalog_watcher)
			_ = usage.store_update_context(
				&usage_store,
				filepath.base(state.odin_root),
				state.odin_root,
				state.config_digest,
			)
			workspace_ready = true
		}
		switch request.method {
		case "initialize":
			_ = usage.store_update_client(
				&usage_store,
				request.params.protocol_version,
				request.params.client_info.name,
				request.params.client_info.version,
			)
			mcp_write(MCP_Initialize_Response {
				jsonrpc = "2.0",
				id = request.id,
				result = {
					protocol_version = MCP_PROTOCOL_VERSION,
					capabilities = {tools = {}},
					server_info = {
						name = "hw-odin-analyze",
						version = service.VERSION,
					},
				},
			})
		case "notifications/initialized":
			event.outcome = "notification"
			mcp_usage_finish()
			continue
		case "ping":
			mcp_write_result(request.id, `{}`)
		case "tools/list":
			audit_schema, _ := mcp_parse_value(`{"type":"object","required":["target_project","primitives"],"properties":{"target_project":{"type":"string"},"primitives":{"type":"array","items":{"type":"object","required":["id","need","search_terms"]}}}}`)
			lookup_schema, _ := mcp_parse_value(`{"type":"object","required":["queries"],"properties":{"queries":{"type":"array","items":{"type":"object","required":["query"],"properties":{"query":{"type":"string"}}}}}}`)
			symbol_schema, _ := mcp_parse_value(`{"type":"object","required":["queries"],"properties":{"queries":{"type":"array","items":{"type":"object","properties":{"symbol_id":{"type":"integer","minimum":0},"generation":{"type":"integer"},"file":{"type":"string"},"line":{"type":"integer"},"column":{"type":"integer"}}}}}}`)
			file_schema, _ := mcp_parse_value(`{"type":"object","required":["queries"],"properties":{"queries":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"scope":{"enum":["workspace"]}}}}}}`)
			rename_schema, _ := mcp_parse_value(`{"type":"object","required":["queries"],"properties":{"queries":{"type":"array","items":{"type":"object","required":["new_name"],"properties":{"symbol_id":{"type":"integer","minimum":0},"generation":{"type":"integer"},"file":{"type":"string"},"line":{"type":"integer"},"column":{"type":"integer"},"new_name":{"type":"string"}}}}}}`)
			tools := [11]MCP_Tool{
				{name = "audit_primitives", description = "Return ranked capability source locators; read cited declarations for detail.", input_schema = audit_schema},
				{name = "lookup_symbols", description = "Return compact symbol IDs and source locations for batched searches.", input_schema = lookup_schema},
				{name = "inspect_symbol", description = "Expand selected symbol IDs or positions with signature and documentation.", input_schema = symbol_schema},
				{name = "definition_and_references", description = "Return compact definitions and indexed reference locations.", input_schema = symbol_schema},
				{name = "call_graph", description = "Return compact direct caller and callee symbol locations.", input_schema = symbol_schema},
				{name = "file_outline", description = "Return compact ordered declaration locations for files.", input_schema = file_schema},
				{name = "package_api", description = "Return compact public symbol locations for packages.", input_schema = lookup_schema},
				{name = "imports", description = "Return compact resolved import locations.", input_schema = file_schema},
				{name = "diagnostics", description = "Return compiler-authoritative diagnostic locations and messages.", input_schema = file_schema},
				{name = "impact_analysis", description = "Return compact read-only symbol impact records.", input_schema = symbol_schema},
				{name = "rename", description = "Return checked generation-bound rename edits without modifying source.", input_schema = rename_schema},
			}
			tool_value, encoded := mcp_composite_value(MCP_Tool_List{tools = tools[:]})
			if !encoded { mcp_write_error(request.id, -32603, "failed to encode tool list"); continue }
			mcp_write(MCP_Response{jsonrpc = "2.0", id = request.id, result = tool_value})
		case "tools/call":
			switch request.params.name {
			case "audit_primitives":
				input: analysis.Capability_Audit_Input
				if !mcp_decode_arguments(request.params.arguments, &input) {
					mcp_write_call_result(request.id, "invalid capability audit input", true); continue
				}
				result, audit_error, audit_ok := analysis.capability_audit_catalog(&catalog, input, allocator = context.temp_allocator)
				if !audit_ok { mcp_write_call_result(request.id, audit_error, true); continue }
				event.generation = result.generation
				event.batch_size = len(input.primitives)
				event.result_count = len(result.results)
				event.truncated = result.truncated
				for primitive_result in result.results {
					if primitive_result.status == "not_found" {
						event.not_found_count += 1
					}
				}
				compact_result, match_count := mcp_compact_capability_result(result)
				payload, marshal_error := json.marshal(compact_result, allocator = context.temp_allocator)
				if marshal_error != nil { mcp_write_error(request.id, -32603, "failed to encode capability result"); continue }
				summary := fmt.aprintf(
					"ok: audit_primitives; primitives=%d; matches=%d; generation=%d; truncated=%t",
					len(input.primitives),
					match_count,
					result.generation,
					result.truncated,
					allocator = context.temp_allocator,
				)
				mcp_write_call_result(request.id, string(payload), summary = summary)
			case "lookup_symbols": mcp_run_batch(request.id, &state, request.params.arguments, "lookup_symbols", "search")
			case "inspect_symbol": mcp_run_batch(request.id, &state, request.params.arguments, "inspect_symbol", "inspect")
			case "definition_and_references": mcp_run_batch(request.id, &state, request.params.arguments, "definition_and_references", "definition_and_references")
			case "call_graph": mcp_run_batch(request.id, &state, request.params.arguments, "call_graph", "call_graph")
			case "file_outline": mcp_run_batch(request.id, &state, request.params.arguments, "file_outline", "outline")
			case "package_api": mcp_run_batch(request.id, &state, request.params.arguments, "package_api", "package-api")
			case "imports": mcp_run_batch(request.id, &state, request.params.arguments, "imports", "imports")
			case "diagnostics": mcp_run_batch(request.id, &state, request.params.arguments, "diagnostics", "diagnostics")
			case "impact_analysis": mcp_run_batch(request.id, &state, request.params.arguments, "impact_analysis", "impact_analysis")
			case "rename": mcp_run_batch(request.id, &state, request.params.arguments, "rename", "rename")
			case: mcp_write_error(request.id, -32602, "unknown tool name")
			}
		case:
			mcp_write_error(request.id, -32601, "method not found")
		}
		mcp_usage_finish()
	}
	mcp_usage_context = nil
	if catalog_watcher_started {
		watcher.stop(&catalog_watcher)
	}
}

ensure_daemon :: proc(root: string, paths: transport.Runtime_Paths) -> bool {
	socket, connected := transport.connect(paths.socket_path)
	if connected {
		posix.close(socket)
		return true
	}
	return start_daemon(root, paths)
}

watch_roots_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, index in a {
		if value != b[index] {
			return false
		}
	}
	return true
}

write_response :: proc(socket: posix.FD, response: service.Response) -> bool {
	data, marshal_error := json.marshal(response, allocator = context.temp_allocator)
	if marshal_error != nil {
		return false
	}
	return transport.send_message(socket, data)
}

run_daemon :: proc(root: string) {
	paths, paths_ok := transport.runtime_paths(root)
	if !paths_ok {
		fmt.eprintln("daemon: failed to create runtime paths")
		os.exit(1)
	}
	defer transport.runtime_paths_destroy(&paths)
	if !os.exists(paths.directory) {
		directory_error := os.make_directory_all(paths.directory)
		if directory_error != nil {
		fmt.eprintln(
			"daemon: failed to create the runtime directory:",
			paths.directory,
			directory_error,
		)
		os.exit(1)
		}
	}

	lock_file, locked := transport.acquire_lock(paths.lock_path)
	if !locked {
		fmt.eprintln("daemon: another process owns the root lock")
		os.exit(0)
	}
	defer posix.close(lock_file)

	listener, listening := transport.listen(paths.socket_path)
	if !listening {
		fmt.eprintln("daemon: failed to listen on the Unix socket")
		os.exit(1)
	}
	defer posix.close(listener)
	defer transport.remove_socket(paths.socket_path)

	pid_text := fmt.aprintf(
		"%d\n",
		posix.getpid(),
		allocator = context.temp_allocator,
	)
	if os.write_entire_file(paths.pid_path, pid_text) != nil {
		fmt.eprintln("daemon: failed to write the PID file")
		os.exit(1)
	}
	defer os.remove(paths.pid_path)

	state: analysis.Analysis_Context
	if !analysis.context_init(&state, root) {
		fmt.eprintln("daemon: failed to build the initial analysis index")
		os.exit(1)
	}
	defer analysis.context_destroy(&state)

	file_watchers: [2]watcher.Watcher
	active_watcher := 0
	if !watcher.start(&file_watchers[active_watcher], state.watch_roots[:]) {
		fmt.eprintln("daemon: failed to start FSEvents")
		os.exit(1)
	}
	defer watcher.stop(&file_watchers[0])
	defer watcher.stop(&file_watchers[1])

	idle_seconds := 0
	for {
		free_all(context.temp_allocator)
		poll_descriptor := posix.pollfd {
			fd = listener,
			events = {.IN},
		}
		poll_result := posix.poll(&poll_descriptor, 1, 1000)
		if poll_result == 0 {
			idle_seconds += 1
			if idle_seconds >= IDLE_TIMEOUT_SECONDS {
				return
			}
			continue
		}
		if poll_result < 0 {
			fmt.eprintln("daemon: socket poll failed")
			os.exit(1)
		}
		idle_seconds = 0

		client := posix.accept(listener, nil, nil)
		if client == -1 {
			continue
		}

		request_data, received := transport.receive_message_with_timeout(
			client,
			REQUEST_READ_TIMEOUT,
			context.temp_allocator,
		)
		if !received {
			posix.close(client)
			continue
		}
		request: service.Request
		if decode_error := json.unmarshal(
			request_data,
			&request,
			allocator = context.temp_allocator,
		); decode_error != nil {
			write_response(client, service.Response{error = "invalid request"})
			posix.close(client)
			continue
		}

		if request.command == "stop" {
			write_response(
				client,
				service.Response{ok = true, payload = `{"stopped":true}`},
			)
			posix.close(client)
			return
		}

		current_watcher := &file_watchers[active_watcher]
		watcher.flush(current_watcher)
		if watcher.consume_dirty(current_watcher) {
			candidate: analysis.Analysis_Context
			if !analysis.context_build_candidate(&state, &candidate) {
				watcher.mark_dirty(current_watcher)
				write_response(
					client,
					service.Response{error = "failed to rebuild the analysis index"},
				)
				posix.close(client)
				continue
			}

			if watch_roots_equal(
				state.watch_roots[:],
				candidate.watch_roots[:],
			) {
				analysis.context_publish_candidate(&state, &candidate)
			} else {
				replacement_index := 1 - active_watcher
				replacement := &file_watchers[replacement_index]
				if !watcher.start(replacement, candidate.watch_roots[:]) {
					analysis.context_destroy(&candidate)
					watcher.mark_dirty(current_watcher)
					write_response(
						client,
						service.Response{
							error = "failed to watch the rebuilt analysis index",
						},
					)
					posix.close(client)
					continue
				}

				watcher.stop(current_watcher)
				analysis.context_publish_candidate(&state, &candidate)
				active_watcher = replacement_index
				watcher.mark_dirty(replacement)
			}
		}

		response := service.execute(
			&state,
			request,
			persistent = true,
			allocator = context.temp_allocator,
		)
		write_response(client, response)
		posix.close(client)
	}
}

// Symbol-list commands whose payloads are a plain []Symbol JSON array.
symbol_list_command :: proc(command: string) -> bool {
	switch command {
	case "outline", "search", "package-api":
		return true
	}
	return false
}

// Convert a compact []Symbol JSON payload into TSV rows. The daemon always
// speaks JSON; the client down-converts so the wire protocol stays unchanged.
write_payload_symbols_tsv :: proc(payload: string) {
	symbols: []analysis.Symbol
	if decode_error := json.unmarshal_string(payload, &symbols, allocator = context.temp_allocator); decode_error != nil {
		fail("the command payload is not a symbol list and cannot be written as TSV")
	}
	write_symbols_tsv(symbols)
}

run_client :: proc(
	root: string,
	compact: bool,
	tsv: bool,
	arguments: []string,
) {
	paths, paths_ok := transport.runtime_paths(root)
	if !paths_ok {
		fail(fmt.aprintf(
			"daemon socket path is too long: %s",
			paths.socket_path,
			allocator = context.temp_allocator,
		))
	}
	defer transport.runtime_paths_destroy(&paths)

	command := arguments[0]
	if command == "stop" {
		response, contacted := send_request(
			paths.socket_path,
			"stop",
			nil,
			true,
		)
		if !contacted {
			fmt.println(`{"stopped":false}`)
			return
		}
		if !response.ok {
			fail(response.error)
		}
		fmt.println(response.payload)
		return
	}

	if command == "restart" {
		_, _ = send_request(paths.socket_path, "stop", nil, true)
		for attempt := 0; attempt < 100; attempt += 1 {
			socket, connected := transport.connect(paths.socket_path)
			if !connected {
				break
			}
			posix.close(socket)
			time.sleep(10 * time.Millisecond)
		}
		command = "status"
	}

	if !ensure_daemon(root, paths) {
		fail("failed to start the analysis daemon")
	}
	response, contacted := send_request(
		paths.socket_path,
		command,
		arguments[1:],
		compact,
	)
	if !contacted {
		fail("failed to contact the analysis daemon")
	}
	if !response.ok {
		fail(response.error)
	}
	if tsv && symbol_list_command(command) {
		write_payload_symbols_tsv(response.payload)
		return
	}
	fmt.println(response.payload)
}

main :: proc() {
	root, root_explicit, compact, tsv, arguments := parse_arguments()
	defer delete(root)

	if len(arguments) == 0 || arguments[0] == "help" {
		print_usage()
		return
	}
	if arguments[0] == "version" {
		fmt.println("hw-odin-analyze", service.VERSION)
		return
	}
	if arguments[0] == "__daemon" {
		run_daemon(root)
		return
	}
	if arguments[0] == "capability-audit" {
		if len(arguments) != 1 {
			fail("capability-audit accepts JSON through stdin and no positional arguments")
		}
		run_capability_client(root, compact)
		return
	}
	if arguments[0] == "mcp" {
		if len(arguments) != 1 {
			fail("mcp accepts no positional arguments")
		}
		run_mcp(root)
		return
	}
	if arguments[0] == "usage" {
		run_usage_report(root, root_explicit, compact, arguments[:])
		return
	}
	run_client(root, compact, tsv, arguments[:])
}
