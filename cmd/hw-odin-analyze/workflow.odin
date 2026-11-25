package main

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

daemon_query :: proc(root, command, argument: string) -> (string, bool) {
	paths, paths_ok := transport.runtime_paths(root, context.temp_allocator)
	if !paths_ok || !ensure_daemon(root, paths) {
		return "", false
	}
	response, contacted := send_request(
		paths.socket_path, command, {argument}, true, context.temp_allocator,
	)
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

split_command :: proc(arguments: []string) -> (options, command: []string) {
	separator, found := slice.linear_search(arguments, "--")
	if !found {
		return arguments, nil
	}
	return arguments[:separator], arguments[separator + 1:]
}

finish :: proc(text: string, ok: bool) {
	fmt.println(strings.trim_right_space(text))
	if !ok {
		os.exit(1)
	}
}

perform_check :: proc(options: workflow.Check_Options) -> bool {
	report := workflow.check(options)
	if !report.passed && report.error == "" {
		workflow.add_hints(daemon_query, &report)
	}
	fmt.println(strings.trim_right_space(workflow.format_check(report, options.shown)))
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
		fail(parse_error)
	}
	report := workflow.plan_edits(root, edits)
	if explicit {
		prefix := strings.concatenate({root, "/"}, context.temp_allocator)
		for file in report.files {
			if !strings.has_prefix(file.path, prefix) {
				fail(fmt.tprintf("%s is outside --root; nothing was written", file.path))
			}
		}
	}
	if len(report.errors) > 0 {
		for error in report.errors {
			fmt.eprintln(error)
		}
		fail(fmt.tprintf(
			"%d of %d edits did not apply; nothing was written", len(report.errors), len(edits),
		))
	}
	if write_error := workflow.commit_edits(report); write_error != "" {
		fail(write_error)
	}
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
		passed = perform_check({root = project, names = names[:]}) && passed
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
	if reason := workflow.guard_hook(source); reason != "" {
		fmt.eprintln(reason)
		os.exit(HOOK_BLOCK_EXIT_CODE)
	}
}

run_crash :: proc(root: string, explicit: bool, arguments: []string) {
	if len(arguments) > 0 && arguments[0] == "retain" {
		if len(arguments) != 3 {
			fail("usage: crash retain BINARY DSYM")
		}
		if retain_error := workflow.retain_symbols(arguments[1], arguments[2]); retain_error != "" {
			fail(retain_error)
		}
		return
	}
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
	finish(workflow.crash(options))
}

run_perf :: proc(root: string, explicit: bool, arguments: []string) {
	usage :: "perf requires profile, compare, trace or asm; see help"
	if len(arguments) == 0 {
		fail(usage)
	}
	options, command := split_command(arguments[1:])
	positional := make([dynamic]string, context.temp_allocator)
	name := ""
	seconds, top, runs := 0, 0, 0
	full := false
	for index := 0; index < len(options); index += 1 {
		switch options[index] {
		case "--name":
			name = option_value(options, &index)
		case "--seconds":
			seconds = parse_positive_option(
				"--seconds", option_value(options, &index), workflow.PROFILE_SECONDS_MAX,
			)
		case "--top":
			top = parse_positive_option("--top", option_value(options, &index), 1000)
		case "--runs":
			runs = parse_positive_option("--runs", option_value(options, &index), workflow.RUNS_MAX)
		case "--full":
			full = true
		case:
			append(&positional, options[index])
		}
	}
	project := project_root(root, explicit)
	switch arguments[0] {
	case "profile":
		finish(workflow.profile({root = project, command = command, seconds = seconds, top = top}))
	case "compare":
		finish(workflow.compare({root = project, name = name, command = command, runs = runs}))
	case "trace":
		if len(positional) != 1 {
			fail("usage: perf trace FILE [--top N]")
		}
		finish(workflow.trace_report(positional[0], top))
	case "asm":
		if len(positional) != 2 {
			fail("usage: perf asm BINARY SYMBOL [--full]")
		}
		finish(workflow.disassemble(positional[0], positional[1], full))
	case:
		fail(usage)
	}
}

run_show :: proc(root: string, explicit: bool, arguments: []string) {
	if len(arguments) != 1 {
		fail("usage: show NAME or show PACKAGE.NAME")
	}
	finish(workflow.show(daemon_query, project_root(root, explicit), arguments[0]))
}
