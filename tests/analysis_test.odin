package tests

import "core:os"
import "core:testing"

import "code_analysis:analysis"

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
