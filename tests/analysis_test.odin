package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "code_analysis:analysis"
import "code_analysis:service"
import "code_analysis:transport"
import "code_analysis:watcher"

INITIAL_MAIN_SOURCE :: `package fixture

original :: proc() {}
`

UPDATED_MAIN_SOURCE :: `package fixture

original :: proc() {}
added :: proc() {}
`

STABLE_SOURCE :: `package fixture

stable :: proc() {}
`

EXCLUDED_SOURCE :: `package excluded

excluded_name :: proc() {}
`

COLLECTION_SOURCE :: `package collection

collection_name :: proc() {}
`

INITIAL_CONFIG :: `{
    "exclude_paths": ["excluded"]
}`

RELOADED_CONFIG :: `{
    "collections": [
        {
            "name": "test_collection",
            "path": "../collection"
        }
    ],
    "exclude_paths": ["ignored"]
}`

temporary_workspace :: proc(t: ^testing.T) -> (
	root: string,
	main_path: string,
	stable_path: string,
	ok: bool,
) {
	root_error: os.Error
	root, root_error = os.make_directory_temp(
		"",
		"hw-odin-analysis-*",
		context.allocator,
	)
	testing.expect_value(t, root_error, nil)
	if root_error != nil {
		return
	}

	main_path, _ = filepath.join({root, "main.odin"}, context.allocator)
	stable_path, _ = filepath.join({root, "stable.odin"}, context.allocator)
	main_error := os.write_entire_file(main_path, INITIAL_MAIN_SOURCE)
	stable_error := os.write_entire_file(stable_path, STABLE_SOURCE)
	testing.expect_value(t, main_error, nil)
	testing.expect_value(t, stable_error, nil)
	ok = main_error == nil && stable_error == nil
	return
}

destroy_temporary_workspace :: proc(
	root: string,
	main_path: string,
	stable_path: string,
) {
	_ = os.change_mode(stable_path, os.Permissions_Default_File)
	_ = os.remove_all(root)
	delete(main_path)
	delete(stable_path)
	delete(root)
}

watch_roots_contain :: proc(state: ^analysis.Analysis_Context, path: string) -> bool {
	normalized, path_error := os.get_absolute_path(path, context.temp_allocator)
	if path_error != nil {
		return false
	}
	for root in state.watch_roots {
		if root == normalized {
			return true
		}
	}
	return false
}

fixture_context :: proc() -> (state: analysis.Analysis_Context, ok: bool) {
	root, root_error := os.get_absolute_path(
		"tests/fixtures/workspace",
		context.temp_allocator,
	)
	if root_error != nil {
		return
	}
	ok = analysis.context_init(&state, root)
	return
}

fixture_context_at :: proc(path: string) -> (
	state: analysis.Analysis_Context,
	ok: bool,
) {
	root, root_error := os.get_absolute_path(path, context.temp_allocator)
	if root_error != nil {
		return
	}
	ok = analysis.context_init(&state, root)
	return
}

@(test)
timed_transport_receive_releases_the_next_request :: proc(t: ^testing.T) {
	stalled: [2]posix.FD
	socket_error := posix.socketpair(.UNIX, .STREAM, .IP, &stalled)
	testing.expect_value(t, socket_error, posix.result(.OK))
	if socket_error != .OK {
		return
	}
	defer posix.close(stalled[0])
	defer posix.close(stalled[1])

	testing.expect(
		t,
		transport.send_all(stalled[1], []byte{0}),
	)
	started := time.tick_now()
	stalled_data, stalled_ok := transport.receive_message_with_timeout(
		stalled[0],
		20 * time.Millisecond,
	)
	elapsed := time.tick_since(started)
	delete(stalled_data)
	testing.expect(t, !stalled_ok)
	testing.expect(t, elapsed < 250 * time.Millisecond)

	next: [2]posix.FD
	socket_error = posix.socketpair(.UNIX, .STREAM, .IP, &next)
	testing.expect_value(t, socket_error, posix.result(.OK))
	if socket_error != .OK {
		return
	}
	defer posix.close(next[0])
	defer posix.close(next[1])

	expected_text := `{"command":"status"}`
	expected := transmute([]byte)expected_text
	testing.expect(t, transport.send_message(next[1], expected))
	received, received_ok := transport.receive_message_with_timeout(
		next[0],
		20 * time.Millisecond,
	)
	defer delete(received)
	testing.expect(t, received_ok)
	testing.expect_value(t, string(received), expected_text)
}

@(test)
configuration_digest_tracks_effective_values :: proc(t: ^testing.T) {
	root, main_path, stable_path, workspace_ok := temporary_workspace(t)
	if !workspace_ok {
		if root != "" {
			destroy_temporary_workspace(root, main_path, stable_path)
		}
		return
	}
	defer destroy_temporary_workspace(root, main_path, stable_path)

	config_path, _ := filepath.join(
		{root, "code-analysis.json"},
		context.allocator,
	)
	defer delete(config_path)

	state: analysis.Analysis_Context
	testing.expect(t, analysis.context_init(&state, root))
	if !state.initialized {
		return
	}
	defer analysis.context_destroy(&state)

	default_digest := strings.clone(state.config_digest)
	defer delete(default_digest)
	testing.expect(t, default_digest != "")
	testing.expect_value(
		t,
		os.write_entire_file(
			config_path,
			`{
			    "exclude_paths": [".git", "build", ".cache"],
			    "odin_command": "odin"
			}`,
		),
		nil,
	)
	testing.expect(t, analysis.context_rebuild(&state))
	testing.expect_value(t, state.config_digest, default_digest)

	testing.expect_value(
		t,
		os.write_entire_file(
			config_path,
			`{"checker_args":["-strict-style"]}`,
		),
		nil,
	)
	testing.expect(t, analysis.context_rebuild(&state))
	testing.expect(t, state.config_digest != default_digest)
}

@(test)
configuration_reload_is_transactional :: proc(t: ^testing.T) {
	parent, parent_error := os.make_directory_temp(
		"",
		"hw-odin-config-*",
		context.allocator,
	)
	testing.expect_value(t, parent_error, nil)
	if parent_error != nil {
		return
	}
	defer {
		_ = os.remove_all(parent)
		delete(parent)
	}

	root, _ := filepath.join({parent, "app"}, context.allocator)
	excluded_root, _ := filepath.join(
		{root, "excluded"},
		context.allocator,
	)
	collection_root, _ := filepath.join(
		{parent, "collection"},
		context.allocator,
	)
	defer delete(root)
	defer delete(excluded_root)
	defer delete(collection_root)

	testing.expect_value(t, os.make_directory_all(excluded_root), nil)
	testing.expect_value(t, os.make_directory_all(collection_root), nil)
	main_path, _ := filepath.join({root, "main.odin"}, context.allocator)
	excluded_path, _ := filepath.join(
		{excluded_root, "excluded.odin"},
		context.allocator,
	)
	collection_path, _ := filepath.join(
		{collection_root, "collection.odin"},
		context.allocator,
	)
	config_path, _ := filepath.join(
		{root, "code-analysis.json"},
		context.allocator,
	)
	defer delete(main_path)
	defer delete(excluded_path)
	defer delete(collection_path)
	defer delete(config_path)

	testing.expect_value(
		t,
		os.write_entire_file(main_path, INITIAL_MAIN_SOURCE),
		nil,
	)
	testing.expect_value(
		t,
		os.write_entire_file(excluded_path, EXCLUDED_SOURCE),
		nil,
	)
	testing.expect_value(
		t,
		os.write_entire_file(collection_path, COLLECTION_SOURCE),
		nil,
	)
	testing.expect_value(
		t,
		os.write_entire_file(config_path, INITIAL_CONFIG),
		nil,
	)

	state: analysis.Analysis_Context
	testing.expect(t, analysis.context_init(&state, root))
	if !state.initialized {
		return
	}
	defer analysis.context_destroy(&state)

	generation := state.generation
	file_count := len(state.files)
	watch_root_count := len(state.watch_roots)
	digest := strings.clone(state.config_digest)
	defer delete(digest)
	testing.expect_value(
		t,
		len(analysis.search(&state, "excluded_name", context.temp_allocator)),
		0,
	)
	testing.expect(t, !watch_roots_contain(&state, collection_root))

	testing.expect_value(
		t,
		os.write_entire_file(config_path, `{"exclude_paths":[`),
		nil,
	)
	candidate: analysis.Analysis_Context
	testing.expect(t, !analysis.context_build_candidate(&state, &candidate))
	testing.expect(t, !candidate.initialized)
	testing.expect_value(t, state.generation, generation)
	testing.expect_value(t, len(state.files), file_count)
	testing.expect_value(t, len(state.watch_roots), watch_root_count)
	testing.expect_value(t, state.config_digest, digest)

	testing.expect_value(
		t,
		os.write_entire_file(config_path, RELOADED_CONFIG),
		nil,
	)
	testing.expect(t, analysis.context_build_candidate(&state, &candidate))
	if !candidate.initialized {
		return
	}
	defer analysis.context_destroy(&candidate)

	testing.expect_value(t, state.generation, generation)
	testing.expect_value(t, state.config_digest, digest)
	testing.expect_value(t, candidate.generation, generation + 1)
	testing.expect_value(t, len(candidate.files), file_count + 2)
	testing.expect(t, candidate.config_digest != digest)
	testing.expect(t, watch_roots_contain(&candidate, collection_root))
	testing.expect_value(
		t,
		len(
			analysis.search(
				&candidate,
				"excluded_name",
				context.temp_allocator,
			),
		),
		1,
	)
	testing.expect_value(
		t,
		len(
			analysis.search(
				&candidate,
				"collection_name",
				context.temp_allocator,
			),
		),
		1,
	)

	analysis.context_publish_candidate(&state, &candidate)
	testing.expect(t, !candidate.initialized)
	testing.expect_value(t, state.generation, generation + 1)
	testing.expect(t, state.config_digest != digest)
	testing.expect(t, watch_roots_contain(&state, collection_root))
}

@(test)
outline_and_search :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	symbols := analysis.outline(&state, "main.odin", context.temp_allocator)
	testing.expect_value(t, len(symbols), 3)
	found := analysis.search(&state, "gree", context.temp_allocator)
	testing.expect_value(t, len(found), 1)
	testing.expect_value(t, found[0].name, "greet")
}

@(test)
definition_and_type_definition :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	definition := analysis.location_for_position(
		&state,
		"main.odin",
		15,
		6,
		context.temp_allocator,
	)
	testing.expect_value(t, definition.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, definition.locations[0].name, "greet")

	type_definition := analysis.type_definition_for_position(
		&state,
		"main.odin",
		14,
		2,
		context.temp_allocator,
	)
	testing.expect_value(t, type_definition.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, type_definition.locations[0].name, "Person")
}

@(test)
field_and_import_selectors :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	field := analysis.location_for_position(
		&state,
		"main.odin",
		10,
		16,
		context.temp_allocator,
	)
	testing.expect_value(t, field.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, field.locations[0].name, "name")

	imported := analysis.location_for_position(
		&state,
		"main.odin",
		16,
		10,
		context.temp_allocator,
	)
	testing.expect_value(t, imported.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, imported.locations[0].name, "ping")
}

@(test)
references_and_calls :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	references := analysis.references(
		&state,
		"main.odin",
		9,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, len(references), 2)
	callers := analysis.callers(
		&state,
		"main.odin",
		9,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, len(callers), 1)
	testing.expect_value(t, callers[0].name, "run")
}

@(test)
diagnostics_accept_valid_workspace :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	diagnostics, diagnostics_ok := analysis.run_diagnostics(
		&state,
		state.root,
		context.temp_allocator,
	)
	testing.expect(t, diagnostics_ok)
	testing.expect_value(t, len(diagnostics), 0)
}

@(test)
rename_plan_is_non_mutating_and_collision_checked :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	testing.expect(t, analysis.rename_is_safe(&state, "main.odin", 9, 1, "welcome"))
	testing.expect(t, !analysis.rename_is_safe(&state, "main.odin", 9, 1, "run"))
	edits := analysis.rename_plan(
		&state,
		"main.odin",
		9,
		1,
		"welcome",
		context.temp_allocator,
	)
	testing.expect_value(t, len(edits), 2)
}

@(test)
selector_completion_uses_receiver_type :: proc(t: ^testing.T) {
	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	fields := analysis.completion(
		&state,
		"main.odin",
		10,
		20,
		context.temp_allocator,
	)
	testing.expect_value(t, len(fields), 1)
	testing.expect_value(t, fields[0].name, "name")

	imports := analysis.completion(
		&state,
		"main.odin",
		16,
		13,
		context.temp_allocator,
	)
	testing.expect_value(t, len(imports), 1)
	testing.expect_value(t, imports[0].name, "ping")

	unqualified := analysis.completion(
		&state,
		"main.odin",
		15,
		1,
		context.temp_allocator,
	)
	found_local := false
	found_explicit_import_member := false
	for symbol in unqualified {
		if symbol.name == "value" {
			found_local = true
		}
		if symbol.name == "ping" {
			found_explicit_import_member = true
		}
	}
	testing.expect(t, found_local)
	testing.expect(t, !found_explicit_import_member)
}

@(test)
failed_rebuild_preserves_published_generation :: proc(t: ^testing.T) {
	root, main_path, stable_path, workspace_ok := temporary_workspace(t)
	if !workspace_ok {
		if root != "" {
			destroy_temporary_workspace(root, main_path, stable_path)
		}
		return
	}
	defer destroy_temporary_workspace(root, main_path, stable_path)

	state: analysis.Analysis_Context
	testing.expect(t, analysis.context_init(&state, root))
	if !state.initialized {
		return
	}
	defer analysis.context_destroy(&state)

	generation := state.generation
	file_count := len(state.files)
	symbol_count := len(state.symbols)
	original := analysis.search(&state, "original", context.temp_allocator)
	testing.expect_value(t, len(original), 1)

	testing.expect_value(
		t,
		os.write_entire_file(main_path, UPDATED_MAIN_SOURCE),
		nil,
	)
	testing.expect_value(t, os.change_mode(stable_path, os.Permissions{}), nil)

	for _ in 0 ..< 2 {
		testing.expect(t, !analysis.context_rebuild(&state))
		testing.expect_value(t, state.generation, generation)
		testing.expect_value(t, len(state.files), file_count)
		testing.expect_value(t, len(state.symbols), symbol_count)
		testing.expect_value(
			t,
			len(analysis.search(&state, "original", context.temp_allocator)),
			1,
		)
		testing.expect_value(
			t,
			len(analysis.search(&state, "added", context.temp_allocator)),
			0,
		)
	}

	testing.expect_value(
		t,
		os.change_mode(stable_path, os.Permissions_Default_File),
		nil,
	)
	testing.expect(t, analysis.context_rebuild(&state))
	testing.expect_value(t, state.generation, generation + 1)
	testing.expect_value(
		t,
		len(analysis.search(&state, "added", context.temp_allocator)),
		1,
	)
}

@(test)
failed_initial_build_releases_context :: proc(t: ^testing.T) {
	root, main_path, stable_path, workspace_ok := temporary_workspace(t)
	if !workspace_ok {
		if root != "" {
			destroy_temporary_workspace(root, main_path, stable_path)
		}
		return
	}
	defer destroy_temporary_workspace(root, main_path, stable_path)

	testing.expect_value(t, os.change_mode(stable_path, os.Permissions{}), nil)
	state: analysis.Analysis_Context
	testing.expect(t, !analysis.context_init(&state, root))
	testing.expect(t, !state.initialized)
	analysis.context_destroy(&state)
}

@(test)
dirty_watcher_can_be_rearmed :: proc(t: ^testing.T) {
	value: watcher.Watcher
	watcher.mark_dirty(&value)
	testing.expect(t, watcher.consume_dirty(&value))
	testing.expect(t, !watcher.consume_dirty(&value))
	watcher.mark_dirty(&value)
	testing.expect(t, watcher.consume_dirty(&value))
}

@(test)
unimported_symbols_remain_unresolved :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/scopes")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	location := analysis.location_for_position(
		&state,
		"unimported/main.odin",
		4,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, location.resolution, analysis.Resolution_Kind.Unresolved)

	type_location := analysis.type_definition_for_position(
		&state,
		"unimported/main.odin",
		7,
		1,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		type_location.resolution,
		analysis.Resolution_Kind.Unresolved,
	)

	hidden_references := analysis.references(
		&state,
		"hidden/hidden.odin",
		3,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, len(hidden_references), 1)
	hidden_callers := analysis.callers(
		&state,
		"hidden/hidden.odin",
		3,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, len(hidden_callers), 0)

	rename_response := service.execute(
		&state,
		service.Request {
			version = 1,
			command = "rename",
			arguments = []string{
				"unimported/main.odin",
				"4",
				"1",
				"renamed",
			},
			compact = true,
		},
		allocator = context.temp_allocator,
	)
	testing.expect_value(t, rename_response.error, "rename target is unresolved")
}

@(test)
using_imports_follow_scope_and_ambiguity :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/scopes")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	exact := analysis.location_for_position(
		&state,
		"exact/main.odin",
		6,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, exact.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, exact.locations[0].path, "using_one/one.odin")
	using_import_found := false
	for import_value in state.imports {
		if import_value.path == "exact/main.odin" && import_value.is_using {
			using_import_found = true
			break
		}
	}
	testing.expect(t, using_import_found)

	visible_type := analysis.type_definition_for_position(
		&state,
		"exact/main.odin",
		9,
		1,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		visible_type.resolution,
		analysis.Resolution_Kind.Exact,
	)
	testing.expect_value(t, visible_type.locations[0].name, "Visible_Type")

	ambiguous := analysis.location_for_position(
		&state,
		"ambiguous/main.odin",
		7,
		1,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		ambiguous.resolution,
		analysis.Resolution_Kind.Ambiguous,
	)
	testing.expect_value(t, len(ambiguous.locations), 2)

	shadowed := analysis.location_for_position(
		&state,
		"shadow/main.odin",
		9,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, shadowed.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, shadowed.locations[0].path, "shadow/main.odin")

	builtin_shadow := analysis.location_for_position(
		&state,
		"shadow/main.odin",
		10,
		1,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		builtin_shadow.resolution,
		analysis.Resolution_Kind.Exact,
	)
	testing.expect_value(
		t,
		builtin_shadow.locations[0].path,
		"shadow/main.odin",
	)

	qualified := analysis.location_for_position(
		&state,
		"qualified/main.odin",
		6,
		5,
		context.temp_allocator,
	)
	testing.expect_value(t, qualified.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, qualified.locations[0].path, "using_one/one.odin")

	qualified_type := analysis.type_definition_for_position(
		&state,
		"qualified/main.odin",
		9,
		1,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		qualified_type.resolution,
		analysis.Resolution_Kind.Exact,
	)
	testing.expect_value(
		t,
		qualified_type.locations[0].name,
		"Visible_Type",
	)

	unknown := analysis.location_for_position(
		&state,
		"unknown/main.odin",
		6,
		9,
		context.temp_allocator,
	)
	testing.expect_value(t, unknown.resolution, analysis.Resolution_Kind.Unresolved)
}

@(test)
builtins_are_navigable_and_read_only :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/scopes")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	location := analysis.location_for_position(
		&state,
		"builtin/main.odin",
		4,
		8,
		context.temp_allocator,
	)
	testing.expect_value(t, location.resolution, analysis.Resolution_Kind.Exact)
	if len(location.locations) != 1 {
		return
	}
	testing.expect(t, filepath.is_abs(location.locations[0].path))
	testing.expect(
		t,
		strings.has_suffix(
			location.locations[0].path,
			"/base/builtin/builtin.odin",
		),
	)

	type_location := analysis.type_definition_for_position(
		&state,
		"builtin/main.odin",
		7,
		1,
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		type_location.resolution,
		analysis.Resolution_Kind.Exact,
	)
	testing.expect_value(t, type_location.locations[0].name, "int")

	rename_response := service.execute(
		&state,
		service.Request {
			version = 1,
			command = "rename",
			arguments = []string{
				"builtin/main.odin",
				"4",
				"8",
				"length",
			},
			compact = true,
		},
	)
	testing.expect_value(
		t,
		rename_response.error,
		"rename target is a read-only built-in",
	)
}

@(test)
completion_respects_package_visibility :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/scopes")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	using_values := analysis.completion(
		&state,
		"exact/main.odin",
		6,
		1,
		context.temp_allocator,
	)
	found_using := false
	found_builtin := false
	found_unrelated := false
	for symbol in using_values {
		if symbol.name == "available" && symbol.path == "using_one/one.odin" {
			found_using = true
		}
		if symbol.name == "len" && analysis.symbol_is_builtin(&state, symbol) {
			found_builtin = true
		}
		if symbol.name == "hidden" {
			found_unrelated = true
		}
	}
	testing.expect(t, found_using)
	testing.expect(t, found_builtin)
	testing.expect(t, !found_unrelated)

	explicit_values := analysis.completion(
		&state,
		"qualified/main.odin",
		6,
		1,
		context.temp_allocator,
	)
	found_explicit_member := false
	for symbol in explicit_values {
		if symbol.name == "available" {
			found_explicit_member = true
			break
		}
	}
	testing.expect(t, !found_explicit_member)

	shadowed_values := analysis.completion(
		&state,
		"shadow/main.odin",
		9,
		1,
		context.temp_allocator,
	)
	available_path := ""
	len_path := ""
	for symbol in shadowed_values {
		if symbol.name == "available" {
			available_path = symbol.path
		}
		if symbol.name == "len" {
			len_path = symbol.path
		}
	}
	testing.expect_value(t, available_path, "shadow/main.odin")
	testing.expect_value(t, len_path, "shadow/main.odin")
}

@(test)
external_dependencies_are_followed_once :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/external_app")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	location := analysis.location_for_position(
		&state,
		"main.odin",
		6,
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, location.resolution, analysis.Resolution_Kind.Exact)
	testing.expect(t, filepath.is_abs(location.locations[0].path))
	testing.expect(
		t,
		strings.has_suffix(
			location.locations[0].path,
			"/external_dependency/dependency.odin",
		),
	)

	leaf := analysis.search(&state, "leaf_name", context.temp_allocator)
	testing.expect_value(t, len(leaf), 1)
	testing.expect(t, filepath.is_abs(leaf[0].path))
	testing.expect(t, len(state.watch_roots) >= 3)

	completion := analysis.completion(
		&state,
		"main.odin",
		6,
		1,
		context.temp_allocator,
	)
	found_direct_dependency := false
	found_transitive_dependency := false
	for symbol in completion {
		if symbol.name == "dependency_name" {
			found_direct_dependency = true
		}
		if symbol.name == "leaf_name" {
			found_transitive_dependency = true
		}
	}
	testing.expect(t, found_direct_dependency)
	testing.expect(t, !found_transitive_dependency)

	rename_response := service.execute(
		&state,
		service.Request {
			version = 1,
			command = "rename",
			arguments = []string{
				"main.odin",
				"6",
				"1",
				"renamed_dependency",
			},
			compact = true,
		},
	)
	testing.expect_value(
		t,
		rename_response.error,
		"rename target is in a read-only dependency",
	)
	testing.expect_value(t, rename_response.payload, "")
}

@(test)
configured_collection_symbols_remain_renameable :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/configured_app")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	rename_response := service.execute(
		&state,
		service.Request {
			version = 1,
			command = "rename",
			arguments = []string{
				"main.odin",
				"6",
				"1",
				"renamed_configured",
			},
			compact = true,
		},
		allocator = context.temp_allocator,
	)
	testing.expect(t, rename_response.ok)
	testing.expect_value(t, rename_response.error, "")
	testing.expect(t, strings.contains(rename_response.payload, "renamed_configured"))

	edits := analysis.rename_plan(
		&state,
		"main.odin",
		6,
		1,
		"renamed_configured",
		context.temp_allocator,
	)
	testing.expect_value(t, len(edits), 2)
}
