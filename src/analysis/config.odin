package analysis

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

Collection_Config :: struct {
	name: string,
	path: string,
}

Config :: struct {
	odin_command:  string,
	checker_args:  []string,
	collections:   []Collection_Config,
	exclude_paths: []string,
}

default_config :: proc(allocator := context.allocator) -> Config {
	config := Config{odin_command = strings.clone("odin", allocator)}
	config.exclude_paths = make([]string, 3, allocator)
	config.exclude_paths[0] = strings.clone(".git", allocator)
	config.exclude_paths[1] = strings.clone("build", allocator)
	config.exclude_paths[2] = strings.clone(".cache", allocator)
	return config
}

load_config :: proc(root: string, allocator := context.allocator) -> Config {
	config := default_config(allocator)
	path, _ := filepath.join({root, "code-analysis.json"}, allocator)
	defer delete(path, allocator)

	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return config
	}

	parsed: Config
	if parse_error := json.unmarshal(data, &parsed, allocator = allocator); parse_error != nil {
		return config
	}

	if parsed.odin_command != "" {
		delete(config.odin_command, allocator)
		config.odin_command = parsed.odin_command
		parsed.odin_command = ""
	}
	if len(parsed.exclude_paths) > 0 {
		for value in config.exclude_paths {
			delete(value, allocator)
		}
		delete(config.exclude_paths, allocator)
		config.exclude_paths = parsed.exclude_paths
		parsed.exclude_paths = nil
	}
	config.checker_args = parsed.checker_args
	config.collections = parsed.collections
	return config
}

config_destroy :: proc(config: ^Config, allocator := context.allocator) {
	delete(config.odin_command, allocator)
	for value in config.checker_args {
		delete(value, allocator)
	}
	delete(config.checker_args, allocator)
	for collection in config.collections {
		delete(collection.name, allocator)
		delete(collection.path, allocator)
	}
	delete(config.collections, allocator)
	for value in config.exclude_paths {
		delete(value, allocator)
	}
	delete(config.exclude_paths, allocator)
	config^ = {}
}
