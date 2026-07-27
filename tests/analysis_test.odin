package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "code_analysis:analysis"
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
