package transport

import "core:c"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

MAX_MESSAGE_SIZE :: 16 * 1024 * 1024
LOCK_EX          :: c.int(2)
LOCK_NB          :: c.int(4)

foreign import System "system:System"

foreign System {
	flock :: proc(fd: posix.FD, operation: c.int) -> c.int ---
}

Runtime_Paths :: struct {
	directory:   string,
	socket_path: string,
	pid_path:    string,
	lock_path:   string,
}

runtime_paths :: proc(
	root: string,
	allocator := context.allocator,
) -> (paths: Runtime_Paths, ok: bool) {
	cache_directory, cache_error := os.user_cache_dir(context.temp_allocator)
	if cache_error != nil {
		return
	}
	root_hash := hash.fnv64a(transmute([]byte)root)
	key := fmt.aprintf("%016x", root_hash, allocator = context.temp_allocator)
	directory, _ := filepath.join(
		{cache_directory, "hw_odin_codeAnalysis", key},
		context.temp_allocator,
	)
	paths.directory = strings.clone(directory, allocator)
	paths.socket_path, _ = filepath.join(
		{directory, "daemon.sock"},
		allocator,
	)
	paths.pid_path, _ = filepath.join({directory, "daemon.pid"}, allocator)
	paths.lock_path, _ = filepath.join({directory, "daemon.lock"}, allocator)
	ok = len(paths.socket_path) < 104
	return
}

runtime_paths_destroy :: proc(
	paths: ^Runtime_Paths,
	allocator := context.allocator,
) {
	if paths == nil {
		return
	}
	delete(paths.directory, allocator)
	delete(paths.socket_path, allocator)
	delete(paths.pid_path, allocator)
	delete(paths.lock_path, allocator)
	paths^ = {}
}

acquire_lock :: proc(path: string) -> (file: posix.FD, ok: bool) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	file = posix.open(
		path_c,
		{.RDWR, .CREAT},
		posix.mode_t{.IRUSR, .IWUSR},
	)
	if file == -1 {
		return file, false
	}
	if flock(file, LOCK_EX | LOCK_NB) != 0 {
		posix.close(file)
		return -1, false
	}
	return file, true
}

make_address :: proc(path: string) -> (address: posix.sockaddr_un, ok: bool) {
	if len(path) == 0 || len(path) >= len(address.sun_path) {
		return
	}
	address.sun_len = u8(size_of(address))
	address.sun_family = .UNIX
	for byte, index in transmute([]byte)path {
		address.sun_path[index] = byte
	}
	ok = true
	return
}

connect :: proc(path: string) -> (socket: posix.FD, ok: bool) {
	address, address_ok := make_address(path)
	if !address_ok {
		return -1, false
	}
	socket = posix.socket(.UNIX, .STREAM)
	if socket == -1 {
		return socket, false
	}
	if posix.connect(
		socket,
		(^posix.sockaddr)(rawptr(&address)),
		posix.socklen_t(size_of(address)),
	) != .OK {
		posix.close(socket)
		return -1, false
	}
	return socket, true
}

listen :: proc(path: string) -> (socket: posix.FD, ok: bool) {
	address, address_ok := make_address(path)
	if !address_ok {
		return -1, false
	}
	socket = posix.socket(.UNIX, .STREAM)
	if socket == -1 {
		return socket, false
	}
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	posix.unlink(path_c)
	if posix.bind(
		socket,
		(^posix.sockaddr)(rawptr(&address)),
		posix.socklen_t(size_of(address)),
	) != .OK {
		posix.close(socket)
		return -1, false
	}
	if posix.listen(socket, 16) != .OK {
		posix.close(socket)
		posix.unlink(path_c)
		return -1, false
	}
	return socket, true
}

remove_socket :: proc(path: string) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	posix.unlink(path_c)
}

send_all :: proc(socket: posix.FD, data: []byte) -> bool {
	sent := uint(0)
	for sent < len(data) {
		count := posix.send(
			socket,
			raw_data(data[sent:]),
			len(data) - sent,
			{},
		)
		if count <= 0 {
			return false
		}
		sent += uint(count)
	}
	return true
}

receive_all :: proc(socket: posix.FD, data: []byte) -> bool {
	received := uint(0)
	for received < len(data) {
		count := posix.recv(
			socket,
			raw_data(data[received:]),
			len(data) - received,
			{},
		)
		if count <= 0 {
			return false
		}
		received += uint(count)
	}
	return true
}

send_message :: proc(socket: posix.FD, data: []byte) -> bool {
	if len(data) > MAX_MESSAGE_SIZE {
		return false
	}
	length := u32(len(data))
	header := [4]byte {
		byte(length >> 24),
		byte(length >> 16),
		byte(length >> 8),
		byte(length),
	}
	return send_all(socket, header[:]) && send_all(socket, data)
}

receive_message :: proc(
	socket: posix.FD,
	allocator := context.allocator,
) -> (data: []byte, ok: bool) {
	header: [4]byte
	if !receive_all(socket, header[:]) {
		return
	}
	length :=
		u32(header[0]) << 24 |
		u32(header[1]) << 16 |
		u32(header[2]) << 8 |
		u32(header[3])
	if length > MAX_MESSAGE_SIZE {
		return
	}
	data = make([]byte, int(length), allocator)
	if length > 0 && !receive_all(socket, data) {
		delete(data, allocator)
		data = nil
		return
	}
	ok = true
	return
}
