package workflow

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "code_analysis:analysis"

Check_Step :: struct {
	name:           string,
	command:        []string,
	forwards_flags: bool,
}

Project_Config :: struct {
	check: []Check_Step,
}

OLS_Collection :: struct {
	name: string,
	path: string,
}

OLS_Config :: struct {
	collections: []OLS_Collection,
}

join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

absolute :: proc(base, path: string) -> string {
	if filepath.is_abs(path) {
		cleaned, _ := filepath.clean(path, context.temp_allocator)
		return cleaned
	}
	return join(base, path)
}

read_text :: proc(path: string) -> (string, bool) {
	data, read_error := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data), read_error == nil
}

find_project_root :: proc(start: string) -> string {
	directory := start
	for _ in 0 ..< 32 {
		if os.exists(join(directory, ".git")) || os.exists(join(directory, "code-analysis.json")) {
			return directory
		}
		parent := filepath.dir(directory)
		if parent == directory || len(parent) == 0 {
			break
		}
		directory = parent
	}
	return start
}

directory_has_odin :: proc(directory: string) -> bool {
	entries, read_error := os.read_all_directory_by_path(directory, context.temp_allocator)
	if read_error != nil {
		return false
	}
	for entry in entries {
		if strings.has_suffix(entry.name, ".odin") {
			return true
		}
	}
	return false
}

is_odin_project :: proc(directory: string) -> bool {
	markers := [?]string{"code-analysis.json", "ols.json", "dependencies.lock"}
	for marker in markers {
		if os.exists(join(directory, marker)) {
			return true
		}
	}
	return directory_has_odin(directory) || directory_has_odin(join(directory, "src"))
}

check_steps :: proc(root: string) -> (steps: []Check_Step, error: string) {
	config_path := join(root, "code-analysis.json")
	if text, found := read_text(config_path); found {
		config: Project_Config
		if json.unmarshal_string(text, &config, allocator = context.temp_allocator) != nil {
			return nil, "code-analysis.json is not valid JSON"
		}
		for step in config.check {
			if step.name == "" || len(step.command) == 0 {
				return nil, "each check step in code-analysis.json needs a name and a command"
			}
		}
		if len(config.check) > 0 {
			return config.check, ""
		}
	}
	list := make([dynamic]Check_Step, context.temp_allocator)
	if gate, found := analysis.workspace_gate(root); found {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, "/bin/sh", "-c", gate)
		append(&list, Check_Step{name = "workspace", command = command[:]})
		return list[:], ""
	}
	if !is_odin_project(root) {
		return nil, "no Odin project was found; pass --root"
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "hw-odin", "check", root, "-no-entry-point")
	if text, found := read_text(join(root, "ols.json")); found {
		config: OLS_Config
		if json.unmarshal_string(text, &config, allocator = context.temp_allocator) == nil {
			for collection in config.collections {
				flag := strings.concatenate(
					{"-collection:", collection.name, "=", absolute(root, collection.path)},
					context.temp_allocator,
				)
				append(&command, flag)
			}
		}
	}
	append(&list, Check_Step{name = "check", command = command[:], forwards_flags = true})
	return list[:], ""
}
