package workflow

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

PIN_COUNT_MAX :: 64
PINNED_FILES :: [?]string{"dependencies.lock", "scripts/dependencies.sh", "scripts/check_dependencies.py"}
REVISION_LENGTH :: 40

Pin :: struct {
	name:     string,
	path:     string,
	revision: string,
}

Pin_State :: enum {
	Current,
	Advanced,
	Dirty,
	Diverged,
	Missing,
}

Pin_Result :: struct {
	pin:   Pin,
	head:  string,
	state: Pin_State,
}

Pinned_File :: struct {
	name:     string,
	path:     string,
	original: string,
	updated:  string,
}

Pin_Report :: struct {
	files:   []Pinned_File,
	results: []Pin_Result,
	error:   string,
}

is_revision :: proc(value: string) -> bool {
	if len(value) != REVISION_LENGTH {
		return false
	}
	for character in value {
		switch character {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

json_string :: proc(object: json.Object, key: string) -> string {
	value, found := object[key]
	if !found {
		return ""
	}
	text, is_string := value.(json.String)
	return is_string ? string(text) : ""
}

parse_pins :: proc(text: string) -> (pins: []Pin, ok: bool) {
	list := make([dynamic]Pin, context.temp_allocator)
	if strings.has_prefix(strings.trim_left_space(text), "{") {
		value, parse_error := json.parse_string(text, allocator = context.temp_allocator)
		if parse_error != nil {
			return nil, false
		}
		root, is_object := value.(json.Object)
		if !is_object {
			return nil, false
		}
		if repositories, found := root["repositories"]; found {
			array, is_array := repositories.(json.Array)
			if !is_array {
				return nil, false
			}
			for item in array {
				object := item.(json.Object) or_return
				append(&list, Pin{
					name = json_string(object, "name"),
					path = json_string(object, "path"),
					revision = json_string(object, "revision"),
				})
			}
		} else {
			for name, item in root {
				object, entry_is_object := item.(json.Object)
				if !entry_is_object {
					continue
				}
				revision := json_string(object, "commit")
				if revision == "" {
					revision = json_string(object, "revision")
				}
				append(&list, Pin{name = name, revision = revision})
			}
		}
	} else {
		remaining := text
		for line in strings.split_lines_iterator(&remaining) {
			if strings.has_prefix(strings.trim_space(line), "#") {
				continue
			}
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) == 3 {
				append(&list, Pin{name = fields[0], revision = fields[2]})
			}
		}
	}
	if len(list) > PIN_COUNT_MAX {
		return nil, false
	}
	for pin in list {
		if pin.name == "" || !is_revision(pin.revision) {
			return nil, false
		}
	}
	slice.sort_by(list[:], proc(a, b: Pin) -> bool {return a.name < b.name})
	return list[:], true
}

pin_checkout :: proc(root: string, pin: Pin) -> string {
	if pin.path != "" {
		return absolute(root, pin.path)
	}
	shared := absolute(root, strings.concatenate({"../odin_libraries/", pin.name}, context.temp_allocator))
	if os.is_directory(shared) {
		return shared
	}
	return absolute(root, strings.concatenate({"../", pin.name}, context.temp_allocator))
}

git :: proc(directory: string, arguments: ..string) -> Run_Result {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", directory)
	append(&command, ..arguments)
	return run(command[:])
}

advance_pins :: proc(root: string) -> Pin_Report {
	report: Pin_Report
	files := make([dynamic]Pinned_File, context.temp_allocator)
	pinned_files := PINNED_FILES
	for name in pinned_files {
		path := join(root, name)
		if text, found := read_text(path); found {
			append(&files, Pinned_File{name = name, path = path, original = text, updated = text})
		}
	}
	if len(files) == 0 || files[0].name != pinned_files[0] {
		return report
	}
	pins, parsed := parse_pins(files[0].original)
	if !parsed {
		report.error = "dependencies.lock has an unsupported format; pins were not advanced"
		return report
	}
	results := make([dynamic]Pin_Result, context.temp_allocator)
	for pin in pins {
		result := Pin_Result{pin = pin}
		checkout := pin_checkout(root, pin)
		head := git(checkout, "rev-parse", "HEAD")
		result.head = strings.trim_space(head.output)
		if !succeeded(head) || !is_revision(result.head) {
			result.state = .Missing
		} else if result.head == pin.revision {
			result.state = .Current
		} else {
			status := git(checkout, "status", "--porcelain")
			if !succeeded(status) || len(strings.trim_space(status.output)) > 0 {
				result.state = .Dirty
			} else if !succeeded(git(checkout, "merge-base", "--is-ancestor", pin.revision, result.head)) {
				result.state = .Diverged
			} else {
				result.state = .Advanced
				for &file in files {
					file.updated, _ = strings.replace_all(
						file.updated, pin.revision, result.head, context.temp_allocator,
					)
				}
			}
		}
		append(&results, result)
	}
	report.results = results[:]
	for &file in files {
		if file.updated != file.original && os.write_entire_file(file.path, file.updated) != nil {
			report.error = fmt.tprintf("%s could not be written", file.name)
			file.updated = file.original
		}
	}
	report.files = files[:]
	return report
}

changed_pin_files :: proc(report: Pin_Report) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for file in report.files {
		if file.updated != file.original {
			append(&names, file.name)
		}
	}
	return strings.join(names[:], " and ", context.temp_allocator)
}

revert_pins :: proc(report: ^Pin_Report) -> bool {
	reverted := false
	for file in report.files {
		if file.updated == file.original {
			continue
		}
		current, found := read_text(file.path)
		if !found || current != file.updated {
			return false
		}
		if os.write_entire_file(file.path, file.original) != nil {
			return false
		}
		reverted = true
	}
	return reverted
}
