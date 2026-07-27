package analysis

import "core:encoding/json"
import "core:fmt"
import "core:hash"
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

config_hash_u64 :: proc(seed, value: u64) -> u64 {
	bytes: [8]byte
	for index in 0 ..< len(bytes) {
		bytes[index] = byte(value >> u64(index * 8))
	}
	return hash.fnv64a(bytes[:], seed)
}

config_hash_string :: proc(seed: u64, value: string) -> u64 {
	result := config_hash_u64(seed, u64(len(value)))
	return hash.fnv64a(transmute([]byte)value, result)
}

config_digest :: proc(
	config: ^Config,
	allocator := context.allocator,
) -> string {
	digest: u64 = 0xcbf29ce484222325
	digest = config_hash_string(digest, config.odin_command)
	digest = config_hash_u64(digest, u64(len(config.checker_args)))
	for value in config.checker_args {
		digest = config_hash_string(digest, value)
	}
	digest = config_hash_u64(digest, u64(len(config.collections)))
	for collection in config.collections {
		digest = config_hash_string(digest, collection.name)
		digest = config_hash_string(digest, collection.path)
	}
	digest = config_hash_u64(digest, u64(len(config.exclude_paths)))
	for value in config.exclude_paths {
		digest = config_hash_string(digest, value)
	}
	return fmt.aprintf("%016x", digest, allocator = allocator)
}

load_config :: proc(
	root: string,
	allocator := context.allocator,
) -> (Config, string, bool) {
	config := default_config(allocator)
	path, _ := filepath.join({root, "code-analysis.json"}, allocator)
	defer delete(path, allocator)

	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		if !os.exists(path) {
			digest := config_digest(&config, allocator)
			return config, digest, true
		}
		config_destroy(&config, allocator)
		return {}, "", false
	}

	parsed: Config
	defer config_destroy(&parsed, allocator)
	if parse_error := json.unmarshal(data, &parsed, allocator = allocator); parse_error != nil {
		config_destroy(&config, allocator)
		return {}, "", false
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
	if len(parsed.checker_args) > 0 {
		config.checker_args = parsed.checker_args
		parsed.checker_args = nil
	}
	if len(parsed.collections) > 0 {
		config.collections = parsed.collections
		parsed.collections = nil
	}
	digest := config_digest(&config, allocator)
	return config, digest, true
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
