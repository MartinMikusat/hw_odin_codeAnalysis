package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "code_analysis:transport"
import "code_analysis:workflow"

HOOK_BLOCK_EXIT_CODE :: 2
CHECKED_PROJECTS_MAX :: 8

read_standard_input :: proc(maximum: int) -> (string, bool) {
	data := make([dynamic]u8, context.temp_allocator)
	buffer: [64 * 1024]u8
	for len(data) <= maximum {
		count, read_error := os.read(os.stdin, buffer[:])
		if count > 0 {
			append(&data, ..buffer[:count])
		}
		if read_error == .EOF || read_error == .Broken_Pipe || (count == 0 && read_error == nil) {
			return string(data[:]), true
		}
		if read_error != nil {
			return "", false
		}
	}
	return "", false
}

daemon_query :: proc(root, command: string, arguments: ..string) -> (string, bool) {
	paths, paths_ok := transport.runtime_paths(root, context.temp_allocator)
	if !paths_ok || !ensure_daemon(root, paths) {
		track_daemon_failure()
		return "", false
	}
	response, contacted := send_request(
		paths.socket_path, command, arguments, true, context.temp_allocator,
	)
	if !contacted {
		track_daemon_failure()
	}
	return response.payload, contacted && response.ok
}

project_root :: proc(root: string, explicit: bool) -> string {
	return explicit ? root : workflow.find_project_root(root)
}

option_value :: proc(arguments: []string, index: ^int) -> string {
	if index^ + 1 >= len(arguments) {
		fail(fmt.tprintf("%s requires a value", arguments[index^]))
	}
	index^ += 1
	return arguments[index^]
}

finish :: proc(text: string, ok: bool) {
	fmt.println(strings.trim_right_space(text))
	tracked.event.output_bytes = len(text)
	track_finish()
	if !ok {
		os.exit(1)
	}
}

perform_check :: proc(options: workflow.Check_Options, via := "") -> bool {
	if !tracked.active {
		track_start("check", options.root, via)
	}
	report := workflow.check(options)
	if !report.passed && report.error == "" {
		workflow.add_hints(daemon_query, &report)
	}
	text := strings.trim_right_space(workflow.format_check(report, options.shown))
	fmt.println(text)
	track_check_report(report, text)
	track_finish()
	return report.passed
}

run_check :: proc(root: string, explicit: bool, arguments: []string) {
	options := workflow.Check_Options{root = project_root(root, explicit)}
	names := make([dynamic]string, context.temp_allocator)
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--no-pins":
			options.no_pins = true
		case "--max":
			options.shown = parse_positive_option("--max", option_value(arguments, &index), 10000)
		case:
			if strings.has_prefix(arguments[index], "-") {
				fail(fmt.tprintf("unknown check option %s", arguments[index]))
			}
			append(&names, arguments[index])
		}
	}
	options.names = names[:]
	if !perform_check(options) {
		os.exit(1)
	}
}

run_edit :: proc(root: string, explicit: bool, arguments: []string) {
	skip_check := false
	names := make([dynamic]string, context.temp_allocator)
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--no-check":
			skip_check = true
		case "--check":
			append(&names, option_value(arguments, &index))
		case:
			fail("edit reads hunks from standard input; options are --no-check and --check NAME")
		}
	}
	source, read := read_standard_input(workflow.EDIT_INPUT_BYTES_MAX)
	if !read {
		fail("the edit input could not be read or is too large")
	}
	edits, parse_error := workflow.parse_edits(source)
	if parse_error != "" {
		tracked.event.outcome, tracked.event.reason = "rejected", "bad-input"
		fail(parse_error)
	}
	tracked.event.hunks = len(edits)
	report := workflow.plan_edits(root, edits)
	if explicit {
		prefix := strings.concatenate({root, "/"}, context.temp_allocator)
		for file in report.files {
			if !strings.has_prefix(file.path, prefix) {
				tracked.event.outcome, tracked.event.reason = "rejected", "outside-root"
				fail(fmt.tprintf("%s is outside --root; nothing was written", file.path))
			}
		}
	}
	if len(report.errors) > 0 {
		for error in report.errors {
			fmt.eprintln(error)
		}
		tracked.event.outcome, tracked.event.reason = "rejected", report.rejection
		first_error := report.errors[0]
		if newline := strings.index_byte(first_error, '\n'); newline >= 0 {
			first_error = first_error[:newline]
		}
		tracked.event.detail = first_error
		fail(fmt.tprintf(
			"%d of %d edits did not apply; nothing was written", len(report.errors), len(edits),
		))
	}
	if write_error := workflow.commit_edits(report); write_error != "" {
		tracked.event.reason = "write"
		fail(write_error)
	}
	tracked.event.results = len(report.files)
	projects := make([dynamic]string, context.temp_allocator)
	for file in report.files {
		fmt.printfln(
			"%s %s (%d hunk%s)", file.created ? "created" : "edited",
			workflow.display_path(root, file.path), file.applied, file.applied == 1 ? "" : "s",
		)
		if !strings.has_suffix(file.path, ".odin") {
			continue
		}
		project := explicit ? root : workflow.find_project_root(filepath.dir(file.path))
		if !slice.contains(projects[:], project) {
			append(&projects, project)
		}
	}
	track_finish()
	if skip_check {
		return
	}
	passed := true
	for project, index in projects {
		if index >= CHECKED_PROJECTS_MAX {
			break
		}
		if len(projects) > 1 {
			fmt.printfln("project %s", project)
		}
		passed = perform_check({root = project, names = names[:]}, "edit") && passed
	}
	if !passed {
		fmt.println("the edits were written; fix the check errors with further edits")
		os.exit(1)
	}
}

run_guard :: proc() {
	source, read := read_standard_input(workflow.GUARD_COMMAND_BYTES_MAX)
	if !read {
		return
	}
	verdict := workflow.guard_hook(source)
	for observation in verdict.observations {
		record_shell_event(
			verdict, "shell", "observed", observation.kind, observation.detail, observation.directory,
		)
	}
	if verdict.block_reason != "" {
		record_shell_event(verdict, "guard", "blocked", verdict.block_kind, "", verdict.directory)
	}
	if verdict.decision_json {
		Decision :: struct {
			decision: string `json:"decision,omitempty"`,
			reason:   string `json:"reason,omitempty"`,
		}
		answer := Decision{}
		if verdict.block_reason != "" {
			answer = {"deny", verdict.block_reason}
		}
		data, _ := json.marshal(answer, allocator = context.temp_allocator)
		fmt.println(string(data))
		return
	}
	if verdict.block_reason != "" {
		fmt.eprintln(verdict.block_reason)
		os.exit(HOOK_BLOCK_EXIT_CODE)
	}
}

run_crash :: proc(root: string, explicit: bool, arguments: []string) {
	options := workflow.Crash_Options{root = project_root(root, explicit)}
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--app":
			options.app = option_value(arguments, &index)
		case "--report":
			options.report = option_value(arguments, &index)
		case "--devlog":
			options.devlog = option_value(arguments, &index)
		case:
			fail("crash options are --app NAME, --report FILE and --devlog DIRECTORY")
		}
	}
	text, ok, has_report := workflow.crash(options)
	if !ok {
		tracked.event.outcome = text == workflow.NO_REPORT ? "not-found" : "error"
		tracked.event.detail = text
	} else if !has_report {
		tracked.event.reason = "journal-only"
	} else if strings.contains(text, workflow.SYMBOLS_MATCHED) {
		tracked.event.reason = "symbolized"
	} else {
		tracked.event.reason = "no-symbols"
	}
	finish(text, ok)
}

run_uses :: proc(root: string, explicit: bool, arguments: []string) {
	if len(arguments) != 1 {
		fail("usage: uses NAME or uses PACKAGE.NAME")
	}
	text, found, ok := workflow.uses(daemon_query, project_root(root, explicit), arguments[0])
	tracked.event.results = found
	if !ok && tracked.event.outcome == "" {
		tracked.event.outcome, tracked.event.detail = "not-found", arguments[0]
	}
	finish(text, ok)
}

run_show :: proc(root: string, explicit: bool, arguments: []string) {
	if len(arguments) != 1 {
		fail("usage: show NAME or show PACKAGE.NAME")
	}
	text, found := workflow.show(daemon_query, project_root(root, explicit), arguments[0])
	if !found && tracked.event.outcome == "" {
		tracked.event.outcome, tracked.event.detail = "not-found", arguments[0]
	}
	finish(text, found)
}
