package analysis

import "core:mem/virtual"
import "core:odin/ast"
import "core:strings"

File_Record :: struct {
	id:            File_ID,
	path:          string,
	relative_path: string,
	package_name:  string,
	package_directory: string,
	source:        string,
	ast_file:      ast.File,
}

Analysis_Context :: struct {
	root:        string,
	config:      Config,
	arena:       virtual.Arena,
	files:       [dynamic]File_Record,
	symbols:     [dynamic]Symbol,
	occurrences: [dynamic]Occurrence,
	imports:     [dynamic]Import,
	generation:  u64,
	initialized: bool,
}

context_init :: proc(state: ^Analysis_Context, root: string) -> bool {
	if state == nil {
		return false
	}
	if virtual.arena_init_growing(&state.arena) != nil {
		return false
	}
	state.root = strings.clone(root)
	state.config = load_config(root)
	state.files = make([dynamic]File_Record)
	state.symbols = make([dynamic]Symbol)
	state.occurrences = make([dynamic]Occurrence)
	state.imports = make([dynamic]Import)
	state.initialized = true
	return context_rebuild(state)
}

context_destroy :: proc(state: ^Analysis_Context) {
	if state == nil || !state.initialized {
		return
	}
	delete(state.root)
	config_destroy(&state.config)
	delete(state.files)
	delete(state.symbols)
	delete(state.occurrences)
	delete(state.imports)
	virtual.arena_destroy(&state.arena)
	state^ = {}
}

context_rebuild :: proc(state: ^Analysis_Context) -> bool {
	if state == nil || !state.initialized {
		return false
	}
	clear(&state.files)
	clear(&state.symbols)
	clear(&state.occurrences)
	clear(&state.imports)
	free_all(virtual.arena_allocator(&state.arena))

	if !scan_and_parse(state) {
		return false
	}
	resolve_occurrences(state)
	state.generation += 1
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
	}
}
