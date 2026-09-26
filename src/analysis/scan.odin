package analysis

import "base:runtime"
import "core:os"

// Zero limits preserve the standalone analyzer's existing scope. Embedded callers
// can bound every visited entry and source read, including followed dependencies.
Scan_Limits :: struct {
	entries:       int,
	project_files: int,
	file_bytes:    i64, // Non-toolchain sources; the installed toolchain is trusted.
	dependency_file_bytes: i64, // Optional separate bound outside the project root.
	total_bytes:   i64,
	skip_documents: bool,
	skip_collection_roots: bool, // Still resolve and follow imports from these collections.
}

Scan_Error :: enum {
	None,
	Too_Many_Entries,
	Too_Many_Files,
	File_Too_Large,
	Total_Too_Large,
	Read_Failed,
}

Scan_State :: struct {
	limits: Scan_Limits,
	error: Scan_Error,
	entries, project_files: int,
	bytes: i64,
}

scan_fail :: proc(state: ^Analysis_Context, error: Scan_Error) -> bool {
	state.scan.error = error
	return false
}

scan_entry :: proc(state: ^Analysis_Context) -> bool {
	if state.scan.limits.entries > 0 && state.scan.entries == state.scan.limits.entries {
		return scan_fail(state, .Too_Many_Entries)
	}
	state.scan.entries += 1
	return true
}

// Reads exactly the observed regular-file size. Growth or truncation during the
// read fails instead of publishing a partial file or growing beyond the budget.
read_bounded_file :: proc(path: string, limit: i64, allocator: runtime.Allocator) -> ([]byte, Scan_Error) {
	assert(limit >= -1) // -1 means unlimited; zero permits only an empty file.
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil || info.type != .Regular {return nil, .Read_Failed}
	file, open_error := os.open(path)
	if open_error != nil {return nil, .Read_Failed}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size < 0 || i64(int(size)) != size {return nil, .Read_Failed}
	if limit >= 0 && size > limit {return nil, .File_Too_Large}
	data, allocation_error := make([]byte, int(size), allocator)
	if allocation_error != nil {return nil, .Read_Failed}
	success := false
	defer if !success {delete(data, allocator)}
	read := 0
	for read < len(data) {
		count, error := os.read(file, data[read:])
		if error != nil || count == 0 {return nil, .Read_Failed}
		read += count
	}
	extra: [1]byte
	count, error := os.read(file, extra[:])
	if count != 0 || (error != nil && error != .EOF) {return nil, .Read_Failed}
	success = true
	return data, .None
}

scan_read_source :: proc(state: ^Analysis_Context, path: string, allocator: runtime.Allocator) -> ([]byte, bool) {
	limit := state.scan.limits.file_bytes
	if !path_is_within(state.root, path) && state.scan.limits.dependency_file_bytes > 0 {
		limit = state.scan.limits.dependency_file_bytes
	}
	if limit == 0 || path_is_within(state.odin_root, path) {limit = -1}
	remaining := state.scan.limits.total_bytes - state.scan.bytes
	if state.scan.limits.total_bytes > 0 {
		assert(remaining >= 0)
		if limit < 0 || remaining < limit {limit = remaining}
	}
	data, error := read_bounded_file(path, limit, allocator)
	if error != .None {
		if error == .File_Too_Large && state.scan.limits.total_bytes > 0 && limit == remaining {
			error = .Total_Too_Large
		}
		return nil, scan_fail(state, error)
	}
	state.scan.bytes += i64(len(data))
	return data, true
}
