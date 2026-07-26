package main

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

usage :: proc() {
	fmt.println(`hw-odin-analyze [--root PATH] [--compact] COMMAND

Commands:
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

	for attempt := 0; attempt < 200; attempt += 1 {
		socket, connected := transport.connect(paths.socket_path)
		if connected {
			posix.close(socket)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

ensure_daemon :: proc(root: string, paths: transport.Runtime_Paths) -> bool {
	socket, connected := transport.connect(paths.socket_path)
	if connected {
		posix.close(socket)
		return true
	}
	return start_daemon(root, paths)
}

watch_paths :: proc(
	state: ^analysis.Analysis_Context,
	allocator := context.allocator,
) -> []string {
	paths := make([]string, 1 + len(state.config.collections), allocator)
	paths[0] = strings.clone(state.root, allocator)
	for collection, index in state.config.collections {
		path := collection.path
		if !filepath.is_abs(path) {
			path, _ = filepath.join({state.root, path}, context.temp_allocator)
		}
		absolute, absolute_error := os.get_absolute_path(path, allocator)
		if absolute_error != nil {
			paths[index + 1] = strings.clone(path, allocator)
		} else {
			paths[index + 1] = absolute
		}
	}
	return paths
}

destroy_watch_paths :: proc(paths: []string, allocator := context.allocator) {
	for path in paths {
		delete(path, allocator)
	}
	delete(paths, allocator)
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

	file_watcher: watcher.Watcher
	roots := watch_paths(&state)
	defer destroy_watch_paths(roots)
	if !watcher.start(&file_watcher, roots) {
		fmt.eprintln("daemon: failed to start FSEvents")
		os.exit(1)
	}
	defer watcher.stop(&file_watcher)

	idle_seconds := 0
	for {
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

		request_data, received := transport.receive_message(
			client,
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

		if watcher.consume_dirty(&file_watcher) {
			if !analysis.context_rebuild(&state) {
				write_response(
					client,
					service.Response{error = "failed to rebuild the analysis index"},
				)
				posix.close(client)
				continue
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
	run_client(root, compact, arguments[:])
}
