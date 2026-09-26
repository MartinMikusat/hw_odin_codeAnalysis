package tests

import "core:fmt"
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
capability_audit_finds_active_standard_library_symbols :: proc(t: ^testing.T) {
	root, root_error := os.get_absolute_path(
		"tests/fixtures/workspace",
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, nil)
	if root_error != nil {
		return
	}
	input := analysis.Capability_Audit_Input {
		target_project = ".",
		primitives = []analysis.Capability_Primitive{
			{
				id = "weekday",
				need = "calculate a weekday",
				search_terms = []string{"datetime.day_of_week", "day_of_week"},
			},
		},
	}
	result, _, audit_ok := analysis.capability_audit_workspace(
		root,
		input,
		context.temp_allocator,
	)
	testing.expect(t, audit_ok)
	if !audit_ok || len(result.results) != 1 {
		return
	}
	testing.expect_value(t, result.results[0].status, "available")
	testing.expect(t, len(result.results[0].matches) > 0)
	if len(result.results[0].matches) > 0 {
		testing.expect_value(t, result.results[0].matches[0].name, "day_of_week")
		testing.expect_value(t, result.results[0].matches[0].source, "odin.core")
		testing.expect_value(t, result.results[0].matches[0].import_path, "core:time/datetime")
		testing.expect_value(t, result.results[0].matches[0].qualified_symbol, "datetime.day_of_week")
		testing.expect(t, len(result.results[0].matches[0].excerpt) > 0)
	}
}

@(test)
capability_audit_applies_structural_constraints :: proc(t: ^testing.T) {
	root, root_error := os.get_absolute_path("tests/fixtures/workspace", context.temp_allocator)
	testing.expect_value(t, root_error, nil)
	if root_error != nil {
		return
	}
	input := analysis.Capability_Audit_Input {
		target_project = ".",
		primitives = []analysis.Capability_Primitive{
			{
				id = "greet",
				need = "format a greeting",
				search_terms = []string{"greet"},
				kind = "procedure",
				parameter_types = []string{"^Person"},
				result_types = []string{"string"},
				target_platform = "darwin",
			},
			{
				id = "wrong-result",
				need = "format a greeting",
				search_terms = []string{"greet"},
				result_types = []string{"bool"},
			},
			{
				id = "unknown-ownership",
				need = "format a greeting with caller ownership",
				search_terms = []string{"greet"},
				ownership_requirement = "caller_owned",
			},
		},
	}
	result, _, audit_ok := analysis.capability_audit_workspace(root, input, context.temp_allocator)
	testing.expect(t, audit_ok)
	if !audit_ok || len(result.results) != 3 {
		return
	}
	testing.expect_value(t, result.results[0].status, "available")
	for match in result.results[1].matches {
		testing.expect(t, match.name != "greet")
	}
	testing.expect_value(t, result.results[2].status, "not_found")
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
			    "odin_command": "hw-odin"
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
nested_shadowing_and_sibling_procedures_resolve_nearest_scope :: proc(t: ^testing.T) {
	state, ok := fixture_context_at("tests/fixtures/scopes")
	testing.expect(t, ok)
	if !ok { return }
	defer analysis.context_destroy(&state)

	nested := analysis.location_for_position(&state, "nested/main.odin", 9, 7, context.temp_allocator)
	testing.expect_value(t, nested.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, nested.locations[0].range.start.line, 8)

	outer := analysis.location_for_position(&state, "nested/main.odin", 11, 6, context.temp_allocator)
	testing.expect_value(t, outer.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, outer.locations[0].range.start.line, 6)

	sibling := analysis.location_for_position(&state, "nested/main.odin", 15, 6, context.temp_allocator)
	testing.expect_value(t, sibling.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, sibling.locations[0].range.start.line, 3)

	alpha_field := analysis.location_for_position(&state, "nested/main.odin", 22, 12, context.temp_allocator)
	beta_field := analysis.location_for_position(&state, "nested/main.odin", 23, 11, context.temp_allocator)
	testing.expect_value(t, alpha_field.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, beta_field.resolution, analysis.Resolution_Kind.Exact)
	testing.expect_value(t, alpha_field.locations[0].owner_type, "Alpha")
	testing.expect_value(t, beta_field.locations[0].owner_type, "Beta")
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

@(test)
platform_variants_resolve_to_the_host_file :: proc(t: ^testing.T) {
	// Only pick_darwin.odin builds for the macOS/arm64 host; the Windows, amd64,
	// and js variants of pick would otherwise make the call ambiguous.
	when ODIN_OS != .Darwin || ODIN_ARCH != .arm64 {return}
	state, ok := fixture_context_at("tests/fixtures/platforms")
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)

	pick_files := 0
	for file in state.files {
		if strings.has_prefix(file.relative_path, "pick") || file.relative_path == "tagged.odin" {
			pick_files += 1
			testing.expect_value(t, file.relative_path, "pick_darwin.odin")
		}
	}
	testing.expect_value(t, pick_files, 1)
	resolved := false
	for occurrence in state.occurrences {
		if occurrence.name != "pick" || occurrence.path != "main.odin" {continue}
		testing.expect(t, int(occurrence.symbol) >= 0)
		if int(occurrence.symbol) >= 0 {
			resolved = state.symbols[int(occurrence.symbol)].path == "pick_darwin.odin"
		}
	}
	testing.expect(t, resolved)
}

@(test)
file_name_suffixes_select_the_target :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		builds: bool,
	}
	cases := []Case {
		{"main.odin", true},
		{"file_darwin.odin", true},
		{"file_windows.odin", false},
		{"file_js.odin", false},
		{"file_arm64.odin", true},
		{"file_amd64.odin", false},
		{"file_darwin_arm64.odin", true},
		{"file_darwin_amd64.odin", false},
		{"file_linux_arm64.odin", false},
		{"my_helper.odin", true},
	}
	for entry in cases {
		builds := analysis.file_name_builds_for(entry.name, .Darwin, .arm64)
		testing.expectf(t, builds == entry.builds, "%s: expected %v", entry.name, entry.builds)
	}
}

context_catalog :: proc(
	state: ^analysis.Analysis_Context,
	project_only: bool,
) -> map[string]int {
	counts := make(map[string]int, context.temp_allocator)
	for file in state.files {
		if project_only && analysis.path_is_within(state.odin_root, file.path) {
			continue
		}
		key := fmt.tprintf("file\t%s\t%s", file.relative_path, file.package_name)
		counts[key] += 1
	}
	for symbol in state.symbols {
		if project_only && analysis.path_is_within(state.odin_root, symbol.path) {
			continue
		}
		key := fmt.tprintf("symbol\t%v\t%s\t%s", symbol.kind, symbol.name, symbol.path)
		counts[key] += 1
	}
	for imported in state.imports {
		if project_only && analysis.path_is_within(state.odin_root, imported.path) {
			continue
		}
		key := fmt.tprintf(
			"import\t%s\t%s\t%s\t%s\t%v",
			imported.path,
			imported.import_path,
			imported.alias,
			imported.resolved_path,
			imported.is_using,
		)
		counts[key] += 1
	}
	for occurrence in state.occurrences {
		if project_only && analysis.path_is_within(state.odin_root, occurrence.path) {
			continue
		}
		symbol_name, symbol_path := "", ""
		if int(occurrence.symbol) >= 0 {
			symbol := state.symbols[int(occurrence.symbol)]
			symbol_name = symbol.name
			symbol_path = symbol.path
		}
		key := fmt.tprintf(
			"use\t%s\t%s\t%s\t%s",
			occurrence.name,
			occurrence.path,
			symbol_name,
			symbol_path,
		)
		counts[key] += 1
	}
	return counts
}

expect_same_catalog :: proc(t: ^testing.T, left, right: map[string]int) {
	testing.expect_value(t, len(left), len(right))
	for key, count in left {
		testing.expectf(t, right[key] == count, "%s: expected %d, got %d", key, count, right[key])
	}
}

builtin_len_id :: proc(state: ^analysis.Analysis_Context) -> analysis.Symbol_ID {
	for symbol in state.symbols {
		if symbol.name == "len" && strings.contains(symbol.path, "builtin") {
			return symbol.id
		}
	}
	return -1
}

@(test)
project_rebuild_matches_a_full_index_without_growing_the_toolchain_arena :: proc(
	t: ^testing.T,
) {
	root, root_error := os.get_absolute_path("tests/fixtures/workspace", context.temp_allocator)
	testing.expect_value(t, root_error, nil)
	if root_error != nil {
		return
	}

	state, ok := fixture_context()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer analysis.context_destroy(&state)
	len_id := builtin_len_id(&state)
	testing.expect(t, int(len_id) >= 0)
	testing.expect(t, state.toolchain_files > 0)
	testing.expect(t, state.toolchain_files < len(state.files))

	testing.expect(t, analysis.context_rebuild_project(&state, root))
	base_used := state.arena.total_used
	testing.expect(t, base_used > 0)
	testing.expect_value(t, builtin_len_id(&state), len_id)
	testing.expect_value(t, state.generation, u64(2))

	fresh, fresh_ok := fixture_context()
	testing.expect(t, fresh_ok)
	if !fresh_ok {
		return
	}
	defer analysis.context_destroy(&fresh)
	expect_same_catalog(t, context_catalog(&state, false), context_catalog(&fresh, false))

	testing.expect(t, analysis.context_rebuild_project(&state, root))
	testing.expect_value(t, state.arena.total_used, base_used)
	testing.expect(t, analysis.context_rebuild_project(&state, root))
	testing.expect_value(t, state.arena.total_used, base_used)
	testing.expect_value(t, builtin_len_id(&state), len_id)
	testing.expect_value(t, state.generation, u64(4))
}

@(test)
project_rebuild_loads_a_new_toolchain_package_and_can_switch_roots :: proc(t: ^testing.T) {
	made, made_error := os.make_directory_temp("", "hw-odin-rebuild-*", context.allocator)
	testing.expect_value(t, made_error, nil)
	if made_error != nil {
		return
	}
	defer {
		_ = os.remove_all(made)
		delete(made)
	}
	other_made, other_error := os.make_directory_temp("", "hw-odin-rebuild-other-*", context.allocator)
	testing.expect_value(t, other_error, nil)
	if other_error != nil {
		return
	}
	defer {
		_ = os.remove_all(other_made)
		delete(other_made)
	}
	// The analyzer compares normalized file paths against the root. Temp
	// directories on macOS sit behind the /var -> /private/var symlink.
	root, root_error := os.get_absolute_path(made, context.allocator)
	testing.expect_value(t, root_error, nil)
	if root_error != nil {
		return
	}
	defer delete(root)
	other, other_path_error := os.get_absolute_path(other_made, context.allocator)
	testing.expect_value(t, other_path_error, nil)
	if other_path_error != nil {
		return
	}
	defer delete(other)

	main_path, _ := filepath.join({root, "main.odin"}, context.allocator)
	defer delete(main_path)
	other_path, _ := filepath.join({other, "main.odin"}, context.allocator)
	defer delete(other_path)
	plain := transmute([]byte)string("package demo\n\nvalue :: 1\n")
	imported := transmute([]byte)string("package demo\n\nimport \"core:fmt\"\n\nvalue :: proc() {\n\tfmt.println(value)\n}\n")
	other_source := transmute([]byte)string("package other\n\nname :: \"other\"\n")
	testing.expect(t, os.write_entire_file(main_path, plain) == nil)
	testing.expect(t, os.write_entire_file(other_path, other_source) == nil)

	state: analysis.Analysis_Context
	testing.expect(t, analysis.context_init(&state, root))
	if !state.initialized {
		return
	}
	defer analysis.context_destroy(&state)
	toolchain_files := state.toolchain_files

	testing.expect(t, os.write_entire_file(main_path, imported) == nil)
	testing.expect(t, analysis.context_rebuild_project(&state, root))
	testing.expect(t, state.toolchain_files > toolchain_files)
	loaded_files := state.toolchain_files
	with_import, with_ok := fixture_context_at(root)
	testing.expect(t, with_ok)
	if !with_ok {
		return
	}
	defer analysis.context_destroy(&with_import)
	expect_same_catalog(t, context_catalog(&state, false), context_catalog(&with_import, false))

	testing.expect(t, os.write_entire_file(main_path, plain) == nil)
	testing.expect(t, analysis.context_rebuild_project(&state, root))
	testing.expect_value(t, state.toolchain_files, loaded_files)
	without_import, without_ok := fixture_context_at(root)
	testing.expect(t, without_ok)
	if !without_ok {
		return
	}
	defer analysis.context_destroy(&without_import)
	expect_same_catalog(t, context_catalog(&state, true), context_catalog(&without_import, true))
	testing.expect(t, state.toolchain_files > without_import.toolchain_files)

	testing.expect(t, analysis.context_rebuild_project(&state, other))
	switched, switched_ok := fixture_context_at(other)
	testing.expect(t, switched_ok)
	if !switched_ok {
		return
	}
	defer analysis.context_destroy(&switched)
	expect_same_catalog(t, context_catalog(&state, true), context_catalog(&switched, true))
	testing.expect(t, state.toolchain_files >= loaded_files)
}
