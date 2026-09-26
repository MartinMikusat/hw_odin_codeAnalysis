package analysis

import "base:runtime"
import "core:mem/virtual"
import "core:odin/ast"
import "core:os"
import "core:strings"

File_Record :: struct {
	id:            File_ID,
	path:          string,
	relative_path: string,
	package_name:  string,
	package_directory: string,
	source:        string,
	ast_file:      ast.File,
	is_builtin:    bool,
	occurrences_complete: bool,
}

Analysis_Context :: struct {
	scan:        Scan_State,
	root:        string,
	odin_root:   string,
	config:      Config,
	config_digest: string,
	arena:       virtual.Arena,
	project_arena: virtual.Arena,
	// Toolchain records are a contiguous prefix. Project records follow them and
	// are replaced by context_rebuild_project.
	toolchain_files:       int,
	toolchain_symbols:     int,
	toolchain_imports:     int,
	toolchain_occurrences: int,
	parse_toolchain: bool,
	files:       [dynamic]File_Record,
	symbols:     [dynamic]Symbol,
	occurrences: [dynamic]Occurrence,
	imports:     [dynamic]Import,
	documents:   [dynamic]Document_Record,
	files_by_path: map[string]File_ID,
	files_by_package: map[string][dynamic]File_ID,
	symbols_by_name: Symbol_Name_Index,
	symbols_by_path: map[string][dynamic]Symbol_ID,
	symbols_by_package: map[string][dynamic]Symbol_ID,
	symbols_by_owner_type: map[string][dynamic]Symbol_ID,
	symbols_by_kind: map[Symbol_Kind][dynamic]Symbol_ID,
	occurrences_by_symbol: map[Symbol_ID][dynamic]int,
	occurrences_by_path: map[string][dynamic]int,
	imports_by_path: map[string][dynamic]int,
	watch_roots: [dynamic]string,
	builtin_path: string,
	generation:  u64,
	initialized: bool,
}

context_allocate_index :: proc(state: ^Analysis_Context) -> bool {
	if state == nil {
		return false
	}
	if virtual.arena_init_growing(&state.arena) != nil {
		return false
	}
	if virtual.arena_init_growing(&state.project_arena) != nil {
		virtual.arena_destroy(&state.arena)
		return false
	}
	state.files = make([dynamic]File_Record)
	state.symbols = make([dynamic]Symbol)
	state.occurrences = make([dynamic]Occurrence)
	state.imports = make([dynamic]Import)
	state.documents = make([dynamic]Document_Record)
	state.watch_roots = make([dynamic]string)
	state.initialized = true
	return true
}

append_index_value :: proc(
	$K: typeid,
	index: ^map[K][dynamic]int,
	key: K,
	value: int,
	allocator: runtime.Allocator,
) {
	values, found := index^[key]
	if !found {
		values = make([dynamic]int, allocator)
	}
	append(&values, value)
	index^[key] = values
}

append_symbol_index_value :: proc(
	$K: typeid,
	index: ^map[K][dynamic]Symbol_ID,
	key: K,
	value: Symbol_ID,
	allocator: runtime.Allocator,
) {
	values, found := index^[key]
	if !found {
		values = make([dynamic]Symbol_ID, allocator)
	}
	append(&values, value)
	index^[key] = values
}

append_file_index_value :: proc(
	index: ^map[string][dynamic]File_ID,
	key: string,
	value: File_ID,
	allocator: runtime.Allocator,
) {
	values, found := index^[key]
	if !found {
		values = make([dynamic]File_ID, allocator)
	}
	append(&values, value)
	index^[key] = values
}

context_base_allocator :: proc(state: ^Analysis_Context) -> runtime.Allocator {
	return virtual.arena_allocator(&state.arena)
}

context_project_allocator :: proc(state: ^Analysis_Context) -> runtime.Allocator {
	return virtual.arena_allocator(&state.project_arena)
}

// Map tables stay in the base arena. A list's backing arena is chosen by the
// first record appended to it: toolchain lists outlive a project reset.
context_list_allocator :: proc(state: ^Analysis_Context, toolchain: bool) -> runtime.Allocator {
	if toolchain {
		return context_base_allocator(state)
	}
	return context_project_allocator(state)
}

context_ensure_declaration_maps :: proc(state: ^Analysis_Context) {
	if state.files_by_path != nil {
		return
	}
	allocator := context_base_allocator(state)
	state.files_by_path = make(map[string]File_ID, allocator = allocator)
	state.files_by_package = make(map[string][dynamic]File_ID, allocator = allocator)
	state.symbols_by_name = make(Symbol_Name_Index, allocator = allocator)
	state.symbols_by_path = make(map[string][dynamic]Symbol_ID, allocator = allocator)
	state.symbols_by_package = make(map[string][dynamic]Symbol_ID, allocator = allocator)
	state.symbols_by_owner_type = make(map[string][dynamic]Symbol_ID, allocator = allocator)
	state.symbols_by_kind = make(map[Symbol_Kind][dynamic]Symbol_ID, allocator = allocator)
	state.imports_by_path = make(map[string][dynamic]int, allocator = allocator)
}

context_index_range :: proc(
	state: ^Analysis_Context,
	file_from, symbol_from, import_from: int,
) {
	assert(file_from >= 0 && file_from <= len(state.files))
	assert(symbol_from >= 0 && symbol_from <= len(state.symbols))
	assert(import_from >= 0 && import_from <= len(state.imports))
	for file in state.files[file_from:] {
		toolchain := int(file.id) < state.toolchain_files
		allocator := context_list_allocator(state, toolchain)
		state.files_by_path[file.relative_path] = file.id
		append_file_index_value(&state.files_by_package, file.package_directory, file.id, allocator)
	}
	for symbol in state.symbols[symbol_from:] {
		toolchain := int(symbol.id) < state.toolchain_symbols
		allocator := context_list_allocator(state, toolchain)
		append_symbol_index_value(string, &state.symbols_by_name, symbol.name, symbol.id, allocator)
		append_symbol_index_value(string, &state.symbols_by_path, symbol.path, symbol.id, allocator)
		append_symbol_index_value(
			string,
			&state.symbols_by_package,
			symbol.package_directory,
			symbol.id,
			allocator,
		)
		if symbol.owner_type != "" {
			append_symbol_index_value(
				string,
				&state.symbols_by_owner_type,
				symbol.owner_type,
				symbol.id,
				allocator,
			)
		}
		append_symbol_index_value(Symbol_Kind, &state.symbols_by_kind, symbol.kind, symbol.id, allocator)
	}
	for import_index in import_from ..< len(state.imports) {
		imported := state.imports[import_index]
		allocator := context_list_allocator(state, import_index < state.toolchain_imports)
		append_index_value(string, &state.imports_by_path, imported.path, import_index, allocator)
	}
}

context_build_occurrence_path_index :: proc(state: ^Analysis_Context) {
	allocator := context_project_allocator(state)
	state.occurrences_by_path = make(map[string][dynamic]int, allocator = allocator)
	for occurrence, occurrence_index in state.occurrences {
		append_index_value(
			string,
			&state.occurrences_by_path,
			occurrence.path,
			occurrence_index,
			allocator,
		)
	}
}

context_build_occurrence_symbol_index :: proc(state: ^Analysis_Context) {
	allocator := context_project_allocator(state)
	state.occurrences_by_symbol = make(map[Symbol_ID][dynamic]int, allocator = allocator)
	for occurrence, occurrence_index in state.occurrences {
		if int(occurrence.symbol) < 0 {
			continue
		}
		append_index_value(
			Symbol_ID,
			&state.occurrences_by_symbol,
			occurrence.symbol,
			occurrence_index,
			allocator,
		)
	}
}

resolve_odin_root :: proc(allocator := context.allocator) -> (string, bool) {
	process_state, stdout, _, process_error := os.process_exec(
		os.Process_Desc{command = []string{"hw-odin", "toolchain", "root"}},
		context.temp_allocator,
	)
	if process_error != nil || process_state.exit_code != 0 {
		return "", false
	}
	root := strings.trim_space(string(stdout))
	if root == "" {
		return "", false
	}
	resolved, path_error := os.get_absolute_path(root, allocator)
	if path_error != nil {
		return "", false
	}
	return resolved, true
}

context_finish_index :: proc(
	state: ^Analysis_Context,
	file_from, symbol_from, import_from, resolve_from: int,
) -> bool {
	context_partition_layers(state)
	context_ensure_declaration_maps(state)
	context_index_range(state, file_from, symbol_from, import_from)
	context_build_occurrence_path_index(state)
	if !resolve_occurrences(state, resolve_from) {
		return false
	}
	context_build_occurrence_symbol_index(state)
	context_assert_layers(state)
	return true
}

context_build_index :: proc(state: ^Analysis_Context) -> bool {
	if !scan_and_parse(state) {
		return false
	}
	return context_finish_index(state, 0, 0, 0, 0)
}

context_prepare :: proc(state: ^Analysis_Context, root: string) -> bool {
	if !context_allocate_index(state) {
		return false
	}
	state.root = normalized_path(root)
	odin_root_ok: bool
	state.odin_root, odin_root_ok = resolve_odin_root()
	if !odin_root_ok {
		context_destroy(state)
		return false
	}
	config_ok: bool
	state.config, state.config_digest, config_ok = load_config(root)
	if !config_ok {
		context_destroy(state)
		return false
	}
	return true
}

context_init :: proc(state: ^Analysis_Context, root: string, limits := Scan_Limits{}, scan_error: ^Scan_Error = nil) -> bool {
	if scan_error != nil {scan_error^ = .None}
	if state == nil {return false}
	state.scan.limits = limits
	if !context_prepare(state, root) {
		return false
	}
	if !context_build_index(state) {
		if scan_error != nil {scan_error^ = state.scan.error}
		context_destroy(state)
		return false
	}
	state.generation = 1
	return true
}

context_destroy :: proc(state: ^Analysis_Context) {
	if state == nil || !state.initialized {
		return
	}
	delete(state.root)
	delete(state.odin_root)
	config_destroy(&state.config)
	delete(state.config_digest)
	delete(state.files)
	delete(state.symbols)
	delete(state.occurrences)
	delete(state.imports)
	delete(state.documents)
	for root in state.watch_roots {
		delete(root)
	}
	delete(state.watch_roots)
	virtual.arena_destroy(&state.arena)
	virtual.arena_destroy(&state.project_arena)
	state^ = {}
}

context_build_candidate :: proc(
	state: ^Analysis_Context,
	candidate: ^Analysis_Context,
) -> bool {
	if state == nil || !state.initialized || candidate == nil {
		return false
	}

	if !context_allocate_index(candidate) {
		return false
	}
	candidate.scan.limits = state.scan.limits
	candidate.root = strings.clone(state.root)
	odin_root_ok: bool
	candidate.odin_root, odin_root_ok = resolve_odin_root()
	if !odin_root_ok {
		context_destroy(candidate)
		return false
	}
	config_ok: bool
	candidate.config, candidate.config_digest, config_ok = load_config(state.root)
	if !config_ok {
		context_destroy(candidate)
		return false
	}
	if !context_build_index(candidate) {
		context_destroy(candidate)
		return false
	}
	candidate.generation = state.generation + 1
	return true
}

context_publish_candidate :: proc(
	state: ^Analysis_Context,
	candidate: ^Analysis_Context,
) {
	assert(state != nil && state.initialized)
	assert(candidate != nil && candidate.initialized)
	previous := state^
	state^ = candidate^
	candidate^ = previous
	context_destroy(candidate)
}

context_rebuild :: proc(state: ^Analysis_Context) -> bool {
	if state == nil || !state.initialized {
		return false
	}
	candidate: Analysis_Context
	if !context_build_candidate(state, &candidate) {
		return false
	}
	context_publish_candidate(state, &candidate)
	return true
}

status :: proc(state: ^Analysis_Context, persistent := false) -> Status {
	return Status {
		root = state.root,
		file_count = len(state.files),
		symbol_count = len(state.symbols),
		occurrence_count = len(state.occurrences),
		generation = state.generation,
		persistent = persistent,
		config_digest = state.config_digest,
	}
}
