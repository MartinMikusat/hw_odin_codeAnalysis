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
	arguments: analysis.Capability_Audit_Input,
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
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_stream(os.stdin))
	defer bufio.scanner_destroy(&scanner)
	for bufio.scanner_scan(&scanner) {
		free_all(context.temp_allocator)
		watcher.flush(&catalog_watcher)
		if watcher.consume_dirty(&catalog_watcher) {
			candidate: analysis.Capability_Catalog
			if _, candidate_ok := analysis.capability_catalog_init(&candidate, root); candidate_ok {
				candidate.generation = catalog.generation + 1
				previous := catalog
				catalog = candidate
				analysis.capability_catalog_destroy(&previous)
			} else {
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
				`{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"hw-odin-analyze","version":"0.2.0"}}`,
			)
		case "notifications/initialized":
			continue
		case "ping":
			mcp_write_result(request.id, `{}`)
		case "tools/list":
			mcp_write_result(
				request.id,
				`{"tools":[{"name":"audit_primitives","title":"Audit Odin primitives","description":"Checks up to 64 planned implementation primitives against the active Odin base/core/vendor libraries and every non-excluded Odin workspace project in one deterministic query. Exact normalized symbols are available; ranked overlaps are candidates; not_found is limited to the indexed search.","inputSchema":{"type":"object","additionalProperties":false,"required":["target_project","primitives"],"properties":{"target_project":{"type":"string","minLength":1,"description":"Workspace-relative project directory."},"primitives":{"type":"array","maxItems":64,"items":{"type":"object","additionalProperties":false,"required":["id","need","search_terms"],"properties":{"id":{"type":"string","minLength":1},"need":{"type":"string","minLength":1},"search_terms":{"type":"array","items":{"type":"string","minLength":1}}}}}}}}]}`,
			)
		case "tools/call":
			if request.params.name != "audit_primitives" {
				mcp_write_error(request.id, -32602, "unknown tool name")
				continue
			}
			result, audit_error, audit_ok := analysis.capability_audit_catalog(
				&catalog,
				request.params.arguments,
				allocator = context.temp_allocator,
			)
			if !audit_ok {
				mcp_write_call_result(request.id, audit_error, true)
				continue
			}
			payload, marshal_error := json.marshal(
				result,
				allocator = context.temp_allocator,
			)
			if marshal_error != nil {
				mcp_write_error(request.id, -32603, "failed to encode capability result")
				continue
			}
			mcp_write_call_result(request.id, string(payload))
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
