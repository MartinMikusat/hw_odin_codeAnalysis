package analysis

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
	root:        string,
	odin_root:   string,
	config:      Config,
	config_digest: string,
	arena:       virtual.Arena,
	files:       [dynamic]File_Record,
	symbols:     [dynamic]Symbol,
	occurrences: [dynamic]Occurrence,
	imports:     [dynamic]Import,
	documents:   [dynamic]Document_Record,
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
	state.documents = make([dynamic]Document_Record)
	state.watch_roots = make([dynamic]string)
	state.initialized = true
	return true
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
