package tests

import "core:os"
import "core:encoding/json"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "code_analysis:analysis"

@(test)
scan_bounds_report_the_failed_limit_and_release_the_context :: proc(t: ^testing.T) {
	root, main_path, stable_path, ok := temporary_workspace(t)
	if !ok {return}
	defer destroy_temporary_workspace(root, main_path, stable_path)
	Case :: struct {
		limits: analysis.Scan_Limits,
		error: analysis.Scan_Error,
	}
	cases := [?]Case {
		{{entries = 1}, .Too_Many_Entries},
		{{project_files = 1}, .Too_Many_Files},
		{{file_bytes = 1}, .File_Too_Large},
		{{total_bytes = 1}, .Total_Too_Large},
	}
	for item in cases {
		state: analysis.Analysis_Context
		error: analysis.Scan_Error
		testing.expect(t, !analysis.context_init(&state, root, item.limits, &error))
		testing.expect_value(t, error, item.error)
		testing.expect(t, !state.initialized)
		analysis.context_destroy(&state)
	}
}

@(test)
scan_can_skip_documents_and_keeps_limits_on_rebuild :: proc(t: ^testing.T) {
	root, main_path, stable_path, ok := temporary_workspace(t)
	if !ok {return}
	defer destroy_temporary_workspace(root, main_path, stable_path)
	document, _ := filepath.join({root, "large.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(document, strings.repeat("x", 1024, context.temp_allocator)) == nil)
	state: analysis.Analysis_Context
	defer analysis.context_destroy(&state)
	error: analysis.Scan_Error
	limits := analysis.Scan_Limits{entries = 3, file_bytes = 64, skip_documents = true}
	testing.expect(t, analysis.context_init(&state, root, limits, &error))
	testing.expect_value(t, len(state.documents), 0)
	extra, _ := filepath.join({root, "extra.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(extra, "extra") == nil)
	candidate: analysis.Analysis_Context
	defer analysis.context_destroy(&candidate)
	testing.expect(t, !analysis.context_build_candidate(&state, &candidate))
	testing.expect(t, state.initialized)
	testing.expect_value(t, state.generation, 1)
}

@(test)
bounded_file_read_checks_empty_exact_and_oversized_files :: proc(t: ^testing.T) {
	root, main_path, stable_path, ok := temporary_workspace(t)
	if !ok {return}
	defer destroy_temporary_workspace(root, main_path, stable_path)
	for source in ([3]string{"", "1234", "12345"}) {
		testing.expect(t, os.write_entire_file(main_path, source) == nil)
		data, error := analysis.read_bounded_file(main_path, 4, context.allocator)
		if len(source) > 4 {
			testing.expect_value(t, error, analysis.Scan_Error.File_Too_Large)
			testing.expect_value(t, len(data), 0)
		} else {
			testing.expect_value(t, error, analysis.Scan_Error.None)
			testing.expect_value(t, string(data), source)
		}
		delete(data)
	}
	testing.expect(t, os.write_entire_file(main_path, "") == nil)
	empty, error := analysis.read_bounded_file(main_path, 0, context.allocator)
	defer delete(empty)
	testing.expect_value(t, error, analysis.Scan_Error.None)
}

@(test)
collection_discovery_can_be_separate_from_imported_dependency_analysis :: proc(t: ^testing.T) {
	root, main_path, stable_path, ok := temporary_workspace(t)
	if !ok {return}
	defer destroy_temporary_workspace(root, main_path, stable_path)
	library, library_path, library_stable, library_ok := temporary_workspace(t)
	if !library_ok {return}
	defer destroy_temporary_workspace(library, library_path, library_stable)
	testing.expect(t, os.write_entire_file(main_path, "package demo\n") == nil)
	testing.expect(t, os.write_entire_file(stable_path, "package demo\n") == nil)
	large_source := strings.concatenate({"package available\nanswer :: 42\n//", strings.repeat("x", 1024, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(library_path, large_source) == nil)
	testing.expect(t, os.write_entire_file(library_stable, "package available\n") == nil)
	collections := [?]analysis.Collection_Config{{name = "available", path = library}}
	config, marshal_error := json.marshal(analysis.Config{collections = collections[:]}, allocator = context.temp_allocator)
	testing.expect(t, marshal_error == nil)
	config_path, _ := filepath.join({root, "code-analysis.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(config_path, config) == nil)
	limits := analysis.Scan_Limits{file_bytes = 64, dependency_file_bytes = 2048, skip_collection_roots = true}
	state: analysis.Analysis_Context
	defer analysis.context_destroy(&state)
	testing.expect(t, analysis.context_init(&state, root, limits))
	for file in state.files {testing.expect(t, file.package_name != "available")}
	analysis.context_destroy(&state)
	testing.expect(t, os.write_entire_file(main_path, "package demo\nimport \"available:.\"\nvalue :: available.answer\n") == nil)
	testing.expect(t, analysis.context_init(&state, root, limits))
	found := false
	for file in state.files {if file.package_name == "available" {found = true}}
	testing.expect(t, found)
}
