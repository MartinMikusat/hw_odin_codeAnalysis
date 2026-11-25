package workflow

import "core:path/filepath"
import "core:slice"
import "core:strings"

OBSERVATIONS_MAX :: 8

Observation :: struct {
	kind:      string,
	detail:    string,
	directory: string,
}

odin_compiler_kind :: proc(values: []string, directory: string) -> string {
	program := filepath.base(values[0])
	arguments := values[1:]
	switch program {
	case "hw-odin", "odin":
		if len(arguments) > 0 {
			switch arguments[0] {
			case "check":
				return "direct-check"
			case "build", "run", "test":
				return "direct-build"
			}
		}
	case "sh", "bash", "zsh":
		for argument, index in arguments {
			if argument == "-n" {
				return ""
			}
			if !strings.has_prefix(argument, "-") {
				return odin_compiler_kind(arguments[index:], directory)
			}
		}
	case "build.sh":
		if is_odin_project(filepath.dir(absolute(directory, values[0]))) {
			return slice.contains(arguments, "check") ? "direct-check" : "direct-build"
		}
	}
	return ""
}

shell_kind :: proc(words: []string, directory: string) -> string {
	values := command_words(words)
	if len(values) == 0 || slice.contains(values, "--help") || slice.contains(values, "-help") {
		return ""
	}
	program := filepath.base(values[0])
	if program == "hw-odin-analyze" {
		return ""
	}
	if kind := odin_compiler_kind(values, directory); kind != "" {
		return kind
	}
	if program == "ols-query" {
		return "ols-query"
	}
	crash_work := program == "lldb" || program == "atos"
	for value in values {
		crash_work = crash_work || strings.contains(value, "DiagnosticReports")
	}
	if crash_work {
		return in_odin_project(directory) ? "manual-crash" : ""
	}
	switch program {
	case "grep", "rg", "ag", "ugrep":
		for value, index in values[1:] {
			typed := value == "--type=odin" || value == "-todin" ||
				(value == "odin" && (values[index] == "-t" || values[index] == "--type"))
			if typed || strings.contains(value, ".odin") ||
			   (strings.contains(value, "::") && in_odin_project(directory)) {
				return "text-search"
			}
		}
	case "cat", "sed", "head", "tail", "nl", "awk":
		for value in values[1:] {
			if strings.has_prefix(value, ">") || strings.has_prefix(value, "-i") {
				return ""
			}
		}
		if mentions_odin_file(values[1:]) {
			return "file-read"
		}
	}
	return ""
}

in_odin_project :: proc(directory: string) -> bool {
	return is_odin_project(find_project_root(directory))
}

observe_command :: proc(command, working_directory: string) -> []Observation {
	if len(command) > GUARD_COMMAND_BYTES_MAX {
		return nil
	}
	result := make([dynamic]Observation, context.temp_allocator)
	directory := working_directory
	for pipeline in shell_pipelines(command) {
		for stage in pipeline {
			values := command_words(stage.words)
			if len(values) == 2 && values[0] == "cd" && !strings.contains_rune(values[1], '$') {
				directory = absolute(directory, values[1])
			}
			kind := shell_kind(stage.words, directory)
			if kind == "" || len(result) >= OBSERVATIONS_MAX {
				continue
			}
			known := false
			for observation in result {
				known = known || observation.kind == kind
			}
			if known {
				continue
			}
			detail := ""
			if kind == "direct-check" || kind == "direct-build" {
				detail = strings.join(values, " ", context.temp_allocator)
			}
			append(&result, Observation{kind, detail, directory})
		}
	}
	return result[:]
}
