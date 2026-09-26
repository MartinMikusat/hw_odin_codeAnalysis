package analysis

import "core:mem/virtual"
import "core:strings"

// Keeps the toolchain prefix and replaces the project layer. See
// docs/incremental-project-rebuild.md. A failed config load leaves the context
// alone. A failure after the project layer is discarded destroys it.

context_rebuild_project :: proc(state: ^Analysis_Context, root: string, scan_error: ^Scan_Error = nil) -> bool {
	assert(state != nil)
	if scan_error != nil {scan_error^ = .None}
	if !state.initialized || len(root) == 0 || state.toolchain_files == 0 {
		return false
	}
	config, digest, config_ok := load_config(root)
	if !config_ok {
		return false
	}

	file_from := state.toolchain_files
	symbol_from := state.toolchain_symbols
	import_from := state.toolchain_imports
	resolve_from := state.toolchain_occurrences
	context_remove_project_entries(state)
	context_truncate_project_layer(state)
	context_install_project(state, root, config, digest)
	if !scan_and_parse(state, true) {
		if scan_error != nil {scan_error^ = state.scan.error}
		context_destroy(state)
		return false
	}
	if !context_finish_index(state, file_from, symbol_from, import_from, resolve_from) {
		context_destroy(state)
		return false
	}
	state.generation += 1
	assert(state.generation > 1)
	return true
}

context_install_project :: proc(
	state: ^Analysis_Context,
	root: string,
	config: Config,
	digest: string,
) {
	assert(state != nil)
	assert(len(root) > 0)
	canonical := normalized_path(root, context.temp_allocator)
	if state.root != canonical {
		delete(state.root)
		state.root = strings.clone(canonical)
	}
	config_destroy(&state.config)
	delete(state.config_digest)
	state.config = config
	state.config_digest = digest
}

context_drop_project_watch_roots :: proc(state: ^Analysis_Context) {
	assert(state != nil)
	assert(len(state.odin_root) > 0)
	for index := len(state.watch_roots) - 1; index >= 0; index -= 1 {
		if path_is_within(state.odin_root, state.watch_roots[index]) {
			continue
		}
		delete(state.watch_roots[index])
		unordered_remove(&state.watch_roots, index)
	}
}

context_remove_project_entries :: proc(state: ^Analysis_Context) {
	assert(state.files_by_path != nil)
	assert(state.toolchain_files <= len(state.files))
	assert(state.toolchain_symbols <= len(state.symbols))
	assert(state.toolchain_imports <= len(state.imports))
	for index := len(state.files) - 1; index >= state.toolchain_files; index -= 1 {
		file := state.files[index]
		_, found := state.files_by_path[file.relative_path]
		assert(found)
		delete_key(&state.files_by_path, file.relative_path)
		pop_tail_id(&state.files_by_package, file.package_directory, file.id)
	}
	for index := len(state.symbols) - 1; index >= state.toolchain_symbols; index -= 1 {
		symbol := state.symbols[index]
		pop_tail_id(&state.symbols_by_name, symbol.name, symbol.id)
		pop_tail_id(&state.symbols_by_path, symbol.path, symbol.id)
		pop_tail_id(&state.symbols_by_package, symbol.package_directory, symbol.id)
		if symbol.owner_type != "" {
			pop_tail_id(&state.symbols_by_owner_type, symbol.owner_type, symbol.id)
		}
		pop_tail_id(&state.symbols_by_kind, symbol.kind, symbol.id)
	}
	for index := len(state.imports) - 1; index >= state.toolchain_imports; index -= 1 {
		pop_tail_id(&state.imports_by_path, state.imports[index].path, index)
	}
}

pop_tail_id :: proc(index: ^map[$K][dynamic]$V, key: K, id: V) {
	values, found := index[key]
	assert(found)
	assert(len(values) > 0)
	assert(values[len(values) - 1] == id)
	pop(&values)
	if len(values) == 0 {
		// The backing belongs to the project arena and dies with the reset.
		delete_key(index, key)
		return
	}
	index[key] = values
}

context_truncate_project_layer :: proc(state: ^Analysis_Context) {
	assert(state.toolchain_files <= len(state.files))
	assert(state.toolchain_occurrences <= len(state.occurrences))
	resize(&state.files, state.toolchain_files)
	resize(&state.symbols, state.toolchain_symbols)
	resize(&state.imports, state.toolchain_imports)
	resize(&state.occurrences, state.toolchain_occurrences)
	clear(&state.documents)
	// Occurrence maps are rebuilt in the project arena. Drop the headers before
	// the reset reclaims their buckets.
	// ponytail: deleted project keys leave tombstone headers in the base-arena
	// maps. Lookups never read a tombstone. Upgrade path: rebuild a map in
	// place if a probe ever has to scrub one.
	state.occurrences_by_path = {}
	state.occurrences_by_symbol = {}
	virtual.arena_free_all(&state.project_arena)
	assert(state.project_arena.total_used == 0)
	context_assert_maps(state, false)
}

context_partition_layers :: proc(state: ^Analysis_Context) {
	assert(state != nil)
	assert(len(state.odin_root) > 0)
	context_partition_files(state)
	context_partition_symbols(state)
	context_partition_imports(state)
	context_partition_occurrences(state)
}

context_partition_files :: proc(state: ^Analysis_Context) {
	leading := 0
	toolchain_count := 0
	for &file in state.files {
		if !path_is_within(state.odin_root, file.path) {
			break
		}
		leading += 1
	}
	leading_paths := make([]string, leading, context.temp_allocator)
	for index in 0 ..< leading {
		leading_paths[index] = state.files[index].path
	}
	for &file in state.files {
		if path_is_within(state.odin_root, file.path) {
			toolchain_count += 1
		}
	}
	if !context_files_are_split(state, toolchain_count) {
		ordered := make([]File_Record, len(state.files), context.temp_allocator)
		cursor := 0
		for &file in state.files {
			if path_is_within(state.odin_root, file.path) {
				ordered[cursor] = file
				cursor += 1
			}
		}
		assert(cursor == toolchain_count)
		for &file in state.files {
			if !path_is_within(state.odin_root, file.path) {
				ordered[cursor] = file
				cursor += 1
			}
		}
		assert(cursor == len(state.files))
		for file, index in ordered {
			state.files[index] = file
			state.files[index].id = File_ID(index)
		}
	}
	for path, index in leading_paths {
		assert(state.files[index].path == path)
		assert(len(path) == 0 || raw_data(state.files[index].path) == raw_data(path))
	}
	for &file, index in state.files {
		assert(file.id == File_ID(index))
	}
	state.toolchain_files = toolchain_count
	assert(state.toolchain_files <= len(state.files))
}

context_files_are_split :: proc(state: ^Analysis_Context, toolchain_count: int) -> bool {
	assert(toolchain_count >= 0 && toolchain_count <= len(state.files))
	for file, index in state.files {
		if path_is_within(state.odin_root, file.path) != (index < toolchain_count) {
			return false
		}
	}
	return true
}

context_partition_symbols :: proc(state: ^Analysis_Context) {
	leading := 0
	toolchain_count := 0
	for &symbol in state.symbols {
		if !path_is_within(state.odin_root, symbol.path) {
			break
		}
		leading += 1
	}
	leading_paths := make([]string, leading, context.temp_allocator)
	for index in 0 ..< leading {
		leading_paths[index] = state.symbols[index].path
	}
	for &symbol in state.symbols {
		if path_is_within(state.odin_root, symbol.path) {
			toolchain_count += 1
		}
	}
	split := true
	for symbol, index in state.symbols {
		if path_is_within(state.odin_root, symbol.path) != (index < toolchain_count) {
			split = false
			break
		}
	}
	if !split {
		ordered := make([]Symbol, len(state.symbols), context.temp_allocator)
		remap := make([]Symbol_ID, len(state.symbols), context.temp_allocator)
		cursor := 0
		for &symbol, index in state.symbols {
			if path_is_within(state.odin_root, symbol.path) {
				ordered[cursor] = symbol
				remap[index] = Symbol_ID(cursor)
				cursor += 1
			}
		}
		assert(cursor == toolchain_count)
		for &symbol, index in state.symbols {
			if !path_is_within(state.odin_root, symbol.path) {
				ordered[cursor] = symbol
				remap[index] = Symbol_ID(cursor)
				cursor += 1
			}
		}
		assert(cursor == len(state.symbols))
		for symbol, index in ordered {
			state.symbols[index] = symbol
			state.symbols[index].id = Symbol_ID(index)
		}
		for &occurrence in state.occurrences {
			if int(occurrence.symbol) < 0 {
				continue
			}
			assert(int(occurrence.symbol) < len(remap))
			occurrence.symbol = remap[int(occurrence.symbol)]
		}
	}
	for path, index in leading_paths {
		assert(state.symbols[index].path == path)
		assert(len(path) == 0 || raw_data(state.symbols[index].path) == raw_data(path))
	}
	for &symbol, index in state.symbols {
		assert(symbol.id == Symbol_ID(index))
	}
	state.toolchain_symbols = toolchain_count
	assert(state.toolchain_symbols <= len(state.symbols))
}

context_partition_imports :: proc(state: ^Analysis_Context) {
	leading := 0
	toolchain_count := 0
	for imported in state.imports {
		if !path_is_within(state.odin_root, imported.path) {
			break
		}
		leading += 1
	}
	leading_paths := make([]string, leading, context.temp_allocator)
	for index in 0 ..< leading {
		leading_paths[index] = state.imports[index].path
	}
	for imported in state.imports {
		if path_is_within(state.odin_root, imported.path) {
			toolchain_count += 1
		}
	}
	split := true
	for imported, index in state.imports {
		if path_is_within(state.odin_root, imported.path) != (index < toolchain_count) {
			split = false
			break
		}
	}
	if !split {
		ordered := make([]Import, len(state.imports), context.temp_allocator)
		cursor := 0
		for imported in state.imports {
			if path_is_within(state.odin_root, imported.path) {
				ordered[cursor] = imported
				cursor += 1
			}
		}
		assert(cursor == toolchain_count)
		for imported in state.imports {
			if !path_is_within(state.odin_root, imported.path) {
				ordered[cursor] = imported
				cursor += 1
			}
		}
		assert(cursor == len(state.imports))
		for imported, index in ordered {
			state.imports[index] = imported
		}
	}
	for path, index in leading_paths {
		assert(state.imports[index].path == path)
		assert(len(path) == 0 || raw_data(state.imports[index].path) == raw_data(path))
	}
	state.toolchain_imports = toolchain_count
	assert(state.toolchain_imports <= len(state.imports))
}

context_partition_occurrences :: proc(state: ^Analysis_Context) {
	leading := 0
	toolchain_count := 0
	for occurrence in state.occurrences {
		if !path_is_within(state.odin_root, occurrence.path) {
			break
		}
		leading += 1
	}
	leading_paths := make([]string, leading, context.temp_allocator)
	for index in 0 ..< leading {
		leading_paths[index] = state.occurrences[index].path
	}
	for occurrence in state.occurrences {
		if path_is_within(state.odin_root, occurrence.path) {
			toolchain_count += 1
		}
	}
	split := true
	for occurrence, index in state.occurrences {
		if path_is_within(state.odin_root, occurrence.path) != (index < toolchain_count) {
			split = false
			break
		}
	}
	if !split {
		ordered := make([]Occurrence, len(state.occurrences), context.temp_allocator)
		cursor := 0
		for occurrence in state.occurrences {
			if path_is_within(state.odin_root, occurrence.path) {
				ordered[cursor] = occurrence
				cursor += 1
			}
		}
		assert(cursor == toolchain_count)
		for occurrence in state.occurrences {
			if !path_is_within(state.odin_root, occurrence.path) {
				ordered[cursor] = occurrence
				cursor += 1
			}
		}
		assert(cursor == len(state.occurrences))
		for occurrence, index in ordered {
			state.occurrences[index] = occurrence
		}
	}
	for path, index in leading_paths {
		assert(state.occurrences[index].path == path)
		assert(len(path) == 0 || raw_data(state.occurrences[index].path) == raw_data(path))
	}
	state.toolchain_occurrences = toolchain_count
	assert(state.toolchain_occurrences <= len(state.occurrences))
}

context_assert_layers :: proc(state: ^Analysis_Context) {
	assert(state.toolchain_files <= len(state.files))
	assert(state.toolchain_symbols <= len(state.symbols))
	assert(state.toolchain_imports <= len(state.imports))
	assert(state.toolchain_occurrences <= len(state.occurrences))
	for &file, index in state.files {
		assert(file.id == File_ID(index))
		assert(path_is_within(state.odin_root, file.path) == (index < state.toolchain_files))
	}
	for &symbol, index in state.symbols {
		assert(symbol.id == Symbol_ID(index))
		assert(path_is_within(state.odin_root, symbol.path) == (index < state.toolchain_symbols))
	}
	for imported, index in state.imports {
		assert(path_is_within(state.odin_root, imported.path) == (index < state.toolchain_imports))
	}
	for occurrence, index in state.occurrences {
		assert(path_is_within(state.odin_root, occurrence.path) == (index < state.toolchain_occurrences))
	}
	context_assert_maps(state, true)
}

context_assert_maps :: proc(state: ^Analysis_Context, project_live: bool) {
	assert(state.files_by_path != nil)
	for path, id in state.files_by_path {
		assert(int(id) >= 0 && int(id) < len(state.files))
		assert(state.files[int(id)].relative_path == path)
		toolchain := int(id) < state.toolchain_files
		if !project_live {
			assert(toolchain)
		}
		context_assert_string_key(state, path, toolchain)
	}
	context_assert_id_map(state, state.files_by_package, state.toolchain_files, project_live)
	context_assert_id_map(state, state.symbols_by_name, state.toolchain_symbols, project_live)
	context_assert_id_map(state, state.symbols_by_path, state.toolchain_symbols, project_live)
	context_assert_id_map(state, state.symbols_by_package, state.toolchain_symbols, project_live)
	context_assert_id_map(state, state.symbols_by_owner_type, state.toolchain_symbols, project_live)
	context_assert_id_map(state, state.symbols_by_kind, state.toolchain_symbols, project_live)
	context_assert_id_map(state, state.imports_by_path, state.toolchain_imports, project_live)
}

context_assert_id_map :: proc(
	state: ^Analysis_Context,
	lists: map[$K][dynamic]$V,
	limit: int,
	project_live: bool,
) {
	for key, values in lists {
		toolchain := context_assert_id_list(state, values[:], limit, project_live)
		when K == string {
			context_assert_string_key(state, key, toolchain)
		}
		// Non-string keys (symbol kind) have no arena backing. The blank
		// assignments keep that instantiation from looking unused.
		_ = key
		_ = toolchain
	}
}

context_assert_id_list :: proc(
	state: ^Analysis_Context,
	values: []$V,
	limit: int,
	project_live: bool,
) -> (toolchain: bool) {
	assert(len(values) > 0)
	seen_project := false
	previous := -1
	for id in values {
		current := int(id)
		assert(current > previous)
		project := current >= limit
		if !project_live {
			assert(!project)
		}
		if seen_project {
			assert(project)
		}
		if project {
			seen_project = true
		} else {
			toolchain = true
		}
		previous = current
	}
	length := len(values) * size_of(V)
	in_base := context_bytes_in_arena(&state.arena, raw_data(values), length)
	in_project := context_bytes_in_arena(&state.project_arena, raw_data(values), length)
	if toolchain {
		assert(in_base)
		assert(!in_project)
	} else {
		assert(!in_base)
		assert(in_project)
	}
	return
}

context_assert_string_key :: proc(state: ^Analysis_Context, key: string, toolchain: bool) {
	if len(key) == 0 {
		return
	}
	in_base := context_bytes_in_arena(&state.arena, raw_data(key), len(key))
	in_project := context_bytes_in_arena(&state.project_arena, raw_data(key), len(key))
	if toolchain {
		assert(in_base)
		assert(!in_project)
	} else {
		assert(!in_base)
		assert(in_project)
	}
}

context_bytes_in_arena :: proc(arena: ^virtual.Arena, data: rawptr, length: int) -> bool {
	assert(arena != nil)
	if data == nil || length <= 0 {
		return false
	}
	start := uintptr(data)
	end := start + uintptr(length)
	block := arena.curr_block
	for block != nil {
		block_start := uintptr(block.base)
		block_end := block_start + uintptr(block.reserved)
		if start >= block_start && end <= block_end {
			return true
		}
		block = block.prev
	}
	return false
}
