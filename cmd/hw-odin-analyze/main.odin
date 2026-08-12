package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "code_analysis:analysis"
import "code_analysis:service"
import "code_analysis:transport"
import "code_analysis:watcher"

IDLE_TIMEOUT_SECONDS :: 15 * 60
REQUEST_READ_TIMEOUT :: 1 * time.Second

usage :: proc() {
	fmt.println(`hw-odin-analyze [--root PATH] [--compact] COMMAND

Commands:
  capability-audit < INPUT.json
  mcp
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
  help`)
}

fail :: proc(message: string) -> ! {
	fmt.eprintln("hw-odin-analyze:", message)
	os.exit(1)
}

parse_arguments :: proc() -> (
	root: string,
	compact: bool,
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
		} else {
			append(&arguments, argument)
		}
	}
	return
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

MCP_Request_Params :: struct {
	name:      string,
	arguments: json.Value,
}

MCP_Query :: struct {
	query: string,
	symbol_id: int,
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

MCP_Batch_Result :: struct {
	generation: u64,
	config_digest: string,
	compiler_release: string,
	compiler_root: string,
	indexed_roots: []string,
	excluded_paths: []string,
	fsevents_flushed: bool,
	query_scope: string,
	result_limit: int,
	truncated: bool,
	results: []json.Value,
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

mcp_write :: proc(value: any) {
	data, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	if marshal_error != nil {
		return
	}
	fmt.println(string(data))
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

mcp_execute_query :: proc(
	state: ^analysis.Analysis_Context,
	command: string,
	input_query: MCP_Query,
) -> (json.Value, string, bool) {
	query := input_query
	if query.generation != 0 && query.generation != state.generation {
		return {}, "query generation does not match the published index", false
	}
	if query.symbol_id > 0 {
		if query.symbol_id >= len(state.symbols) {
			return {}, "symbol_id is outside the published generation", false
		}
		symbol := state.symbols[query.symbol_id]
		query.file = symbol.path
		query.line = symbol.range.start.line
		query.column = symbol.range.start.column
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
	return value, "", true
}

mcp_composite_value :: proc(value: any) -> (json.Value, bool) {
	data, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	if marshal_error != nil { return {}, false }
	return mcp_parse_value(string(data))
}

mcp_execute_composite :: proc(
	state: ^analysis.Analysis_Context,
	mode: string,
	query: MCP_Query,
) -> (json.Value, string, bool) {
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
	}
	payload, marshal_error := json.marshal(
		MCP_Batch_Result{
			generation = state.generation,
			config_digest = state.config_digest,
			compiler_release = filepath.base(state.odin_root),
			compiler_root = state.odin_root,
			indexed_roots = state.watch_roots[:],
			excluded_paths = state.config.exclude_paths,
			fsevents_flushed = true,
			query_scope = state.root,
			result_limit = 64,
			truncated = false,
			results = results,
		},
		allocator = context.temp_allocator,
	)
	if marshal_error != nil { mcp_write_error(id, -32603, "failed to encode batch result"); return }
	mcp_write_call_result(id, string(payload))
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
) {
	content := [1]MCP_Content{{type = "text", text = payload}}
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

run_mcp :: proc(root: string) {
	state: analysis.Analysis_Context
	if !analysis.context_init(&state, root) {
		fail("failed to build the initial analysis index")
	}
	defer analysis.context_destroy(&state)
	catalog: analysis.Capability_Catalog
	if catalog_error, catalog_ok := analysis.capability_catalog_init(&catalog, root); !catalog_ok {
		fail(catalog_error)
	}
	defer analysis.capability_catalog_destroy(&catalog)
	catalog_watcher: watcher.Watcher
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
	defer watcher.stop(&catalog_watcher)
	watcher.flush(&catalog_watcher)
	_ = watcher.consume_dirty(&catalog_watcher)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_stream(os.stdin))
	defer bufio.scanner_destroy(&scanner)
	for bufio.scanner_scan(&scanner) {
		free_all(context.temp_allocator)
		watcher.flush(&catalog_watcher)
		if watcher.consume_dirty(&catalog_watcher) {
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
			} else {
				if catalog_ok { analysis.capability_catalog_destroy(&candidate) }
				if analysis_ok { analysis.context_destroy(&analysis_candidate) }
				watcher.mark_dirty(&catalog_watcher)
			}
		}
		line := strings.trim_space(bufio.scanner_text(&scanner))
		if line == "" {
			continue
		}
		request: MCP_Request
		if decode_error := json.unmarshal(
			transmute([]byte)line,
			&request,
			allocator = context.temp_allocator,
		); decode_error != nil {
			mcp_write_error({}, -32700, "invalid JSON-RPC request")
			continue
		}
		if request.jsonrpc != "2.0" {
			mcp_write_error(request.id, -32600, "jsonrpc must be 2.0")
			continue
		}
		switch request.method {
		case "initialize":
			mcp_write_result(
				request.id,
				`{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"hw-odin-analyze","version":"0.3.0"}}`,
			)
		case "notifications/initialized":
			continue
		case "ping":
			mcp_write_result(request.id, `{}`)
		case "tools/list":
			audit_schema, _ := mcp_parse_value(`{"type":"object","additionalProperties":false,"required":["target_project","primitives"],"properties":{"target_project":{"type":"string","minLength":1},"primitives":{"type":"array","maxItems":64,"items":{"type":"object","required":["id","need","search_terms"]}}}}`)
			batch_schema, _ := mcp_parse_value(`{"type":"object","additionalProperties":false,"required":["queries"],"properties":{"queries":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"object","additionalProperties":false,"properties":{"query":{"type":"string"},"symbol_id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":1},"file":{"type":"string"},"line":{"type":"integer","minimum":1},"column":{"type":"integer","minimum":1},"new_name":{"type":"string"},"scope":{"enum":["workspace"]}}}}}}`)
			tools := [11]MCP_Tool{
				{name = "audit_primitives", description = "Find reusable Odin capabilities in retained workspace and standard-library indexes.", input_schema = audit_schema},
				{name = "lookup_symbols", description = "Batch exact or fuzzy symbol searches.", input_schema = batch_schema},
				{name = "inspect_symbol", description = "Batch symbol inspections at source positions.", input_schema = batch_schema},
				{name = "definition_and_references", description = "Batch definition and complete indexed reference queries.", input_schema = batch_schema},
				{name = "call_graph", description = "Batch direct caller and callee queries.", input_schema = batch_schema},
				{name = "file_outline", description = "Batch ordered file outlines.", input_schema = batch_schema},
				{name = "package_api", description = "Batch public package API queries.", input_schema = batch_schema},
				{name = "imports", description = "Batch resolved import queries.", input_schema = batch_schema},
				{name = "diagnostics", description = "Batch compiler-authoritative diagnostic queries.", input_schema = batch_schema},
				{name = "impact_analysis", description = "Batch read-only symbol impact queries.", input_schema = batch_schema},
				{name = "rename", description = "Batch checked non-mutating rename plans.", input_schema = batch_schema},
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
				payload, marshal_error := json.marshal(result, allocator = context.temp_allocator)
				if marshal_error != nil { mcp_write_error(request.id, -32603, "failed to encode capability result"); continue }
				mcp_write_call_result(request.id, string(payload))
			case "lookup_symbols": mcp_run_batch(request.id, &state, request.params.arguments, "search")
			case "inspect_symbol": mcp_run_batch(request.id, &state, request.params.arguments, "inspect")
			case "definition_and_references": mcp_run_batch(request.id, &state, request.params.arguments, "definition_and_references")
			case "call_graph": mcp_run_batch(request.id, &state, request.params.arguments, "call_graph")
			case "file_outline": mcp_run_batch(request.id, &state, request.params.arguments, "outline")
			case "package_api": mcp_run_batch(request.id, &state, request.params.arguments, "package-api")
			case "imports": mcp_run_batch(request.id, &state, request.params.arguments, "imports")
			case "diagnostics": mcp_run_batch(request.id, &state, request.params.arguments, "diagnostics")
			case "impact_analysis": mcp_run_batch(request.id, &state, request.params.arguments, "impact_analysis")
			case "rename": mcp_run_batch(request.id, &state, request.params.arguments, "rename")
			case: mcp_write_error(request.id, -32602, "unknown tool name")
			}
		case:
			mcp_write_error(request.id, -32601, "method not found")
		}
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

run_client :: proc(
	root: string,
	compact: bool,
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
	fmt.println(response.payload)
}

main :: proc() {
	root, compact, arguments := parse_arguments()
	defer delete(root)

	if len(arguments) == 0 || arguments[0] == "help" {
		usage()
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
	run_client(root, compact, arguments[:])
}
