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
	is_builtin:    bool,
	occurrences_complete: bool,
}

Analysis_Context :: struct {
	root:        string,
	config:      Config,
	arena:       virtual.Arena,
	files:       [dynamic]File_Record,
	symbols:     [dynamic]Symbol,
	occurrences: [dynamic]Occurrence,
	imports:     [dynamic]Import,
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
	state.files = make([dynamic]File_Record)
	state.symbols = make([dynamic]Symbol)
	state.occurrences = make([dynamic]Occurrence)
	state.imports = make([dynamic]Import)
	state.watch_roots = make([dynamic]string)
	state.initialized = true
	return true
}

context_build_index :: proc(state: ^Analysis_Context) -> bool {
	if !scan_and_parse(state) {
		return false
	}
	return resolve_occurrences(state)
}

context_init :: proc(state: ^Analysis_Context, root: string) -> bool {
	if !context_allocate_index(state) {
		return false
	}
	state.root = strings.clone(root)
	state.config = load_config(root)
	if !context_build_index(state) {
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
	config_destroy(&state.config)
	delete(state.files)
	delete(state.symbols)
	delete(state.occurrences)
	delete(state.imports)
	for root in state.watch_roots {
		delete(root)
	}
	delete(state.watch_roots)
	virtual.arena_destroy(&state.arena)
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
	candidate.root = strings.clone(state.root)
	candidate.config = config_clone(&state.config)
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
	}
}
