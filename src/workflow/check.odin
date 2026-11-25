package workflow

import "core:fmt"
import "core:strings"
import "core:time"

SHOWN_DEFAULT :: 40
TAIL_LINES :: 40
OTHER_LINES_MAX :: 20
COMPILER_ERROR_LIMIT :: 36

Check_Options :: struct {
	root:    string,
	names:   []string,
	no_pins: bool,
	shown:   int,
}

Step_Report :: struct {
	step:      Check_Step,
	result:    Run_Result,
	output:    Compiler_Output,
	retried:   bool,
	ran:       bool,
}

Check_Report :: struct {
	root:     string,
	pins:     Pin_Report,
	steps:    []Step_Report,
	reverted: bool,
	error:    string,
	passed:   bool,
}

compiler_crashed :: proc(output: string) -> bool {
	return strings.contains(output, "LLVM ERROR") ||
		(strings.contains(output, "Assertion Failure:") && strings.contains(output, "src/")) ||
		strings.contains(output, "This is a compiler error")
}

run_step :: proc(root: string, step: Check_Step) -> Step_Report {
	report := Step_Report{step = step, ran = true}
	report.result = run(step.command, root)
	if !succeeded(report.result) && compiler_crashed(report.result.output) {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, ..step.command)
		if step.forwards_flags {
			append(&command, "-thread-count:1")
		}
		report.retried = true
		report.result = run(command[:], root)
	}
	report.output = parse_compiler_output(report.result.output)
	return report
}

check :: proc(options: Check_Options) -> Check_Report {
	report := Check_Report{root = options.root}
	steps, steps_error := check_steps(options.root)
	if steps_error != "" {
		report.error = steps_error
		return report
	}
	selected := make([dynamic]Check_Step, context.temp_allocator)
	if len(options.names) == 0 {
		append(&selected, ..steps)
	}
	for name in options.names {
		found := false
		for step in steps {
			if step.name == name {
				append(&selected, step)
				found = true
			}
		}
		if !found {
			names := make([dynamic]string, context.temp_allocator)
			for step in steps {
				append(&names, step.name)
			}
			report.error = fmt.tprintf(
				"unknown check %q; available: %s",
				name, strings.join(names[:], ", ", context.temp_allocator),
			)
			return report
		}
	}
	if !options.no_pins {
		report.pins = advance_pins(options.root)
	}
	results := make([dynamic]Step_Report, context.temp_allocator)
	report.passed = true
	for step in selected {
		result := run_step(options.root, step)
		report.passed = report.passed && succeeded(result.result)
		append(&results, result)
	}
	report.steps = results[:]
	if !report.passed {
		report.reverted = revert_pins(&report.pins)
	}
	return report
}

write_pins :: proc(builder: ^strings.Builder, report: Check_Report) {
	if report.pins.error != "" {
		fmt.sbprintfln(builder, "pins: %s", report.pins.error)
	}
	for result in report.pins.results {
		short_pin := result.pin.revision[:8]
		switch result.state {
		case .Current:
		case .Advanced:
			if report.reverted {
				fmt.sbprintfln(
					builder, "pin %s: %s -> %s was tried and reverted because the check failed",
					result.pin.name, short_pin, result.head[:8],
				)
			} else {
				fmt.sbprintfln(
					builder, "pin %s: advanced %s -> %s; commit %s with this work",
					result.pin.name, short_pin, result.head[:8], changed_pin_files(report.pins),
				)
			}
		case .Dirty:
			fmt.sbprintfln(
				builder, "pin %s: checkout is ahead of %s but has uncommitted changes; not advanced",
				result.pin.name, short_pin,
			)
		case .Diverged:
			fmt.sbprintfln(
				builder, "pin %s: checkout history does not contain %s; stop and report",
				result.pin.name, short_pin,
			)
		case .Missing:
			fmt.sbprintfln(builder, "pin %s: checkout was not found", result.pin.name)
		}
	}
}

display_path :: proc(root, path: string) -> string {
	toolchain :: "/hw_odin_toolchain/versions/"
	if start := strings.index(path, toolchain); start >= 0 {
		rest := path[start + len(toolchain):]
		if slash := strings.index_byte(rest, '/'); slash >= 0 {
			return strings.concatenate({"odin:", rest[slash + 1:]}, context.temp_allocator)
		}
	}
	prefix := strings.concatenate({root, "/"}, context.temp_allocator)
	return strings.trim_prefix(path, prefix)
}

format_check :: proc(report: Check_Report, shown_limit: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	if report.error != "" {
		fmt.sbprintfln(&builder, "check: ERROR %s", report.error)
		return strings.to_string(builder)
	}
	fmt.sbprintf(&builder, "check: %s", report.passed ? "PASSED" : "FAILED")
	for step in report.steps {
		errors, warnings := 0, 0
		for diagnostic in step.output.diagnostics {
			if diagnostic.warning {warnings += 1} else {errors += 1}
		}
		fmt.sbprintf(
			&builder, " | %s %s errors=%d warnings=%d %.1fs",
			step.step.name, succeeded(step.result) ? "ok" : "failed", errors, warnings,
			time.duration_seconds(step.result.duration),
		)
	}
	strings.write_byte(&builder, '\n')
	write_pins(&builder, report)
	shown := 0
	limit := shown_limit > 0 ? shown_limit : SHOWN_DEFAULT
	for step in report.steps {
		if step.step.workspace_gate != "" {
			fmt.sbprintfln(&builder, "[%s] compile gate: %s", step.step.name, step.step.workspace_gate)
		}
		if step.retried {
			fmt.sbprintfln(&builder, "[%s] the compiler crashed and the step was run again", step.step.name)
		}
		if step.result.timed_out {
			fmt.sbprintfln(
				&builder, "[%s] timed out and was stopped; confirm that no compiler process remains",
				step.step.name,
			)
		}
		errors := 0
		for pass in 0 ..< 2 {
			for diagnostic in step.output.diagnostics {
				if diagnostic.warning != (pass == 1) {
					continue
				}
				if pass == 0 {errors += 1}
				if shown >= limit {
					continue
				}
				shown += 1
				fmt.sbprintfln(
					&builder, "[%s] %s:%d:%d %s: %s", step.step.name,
					display_path(report.root, diagnostic.path), diagnostic.line, diagnostic.column,
					diagnostic.warning ? "warning" : "error", diagnostic.message,
				)
				for detail in diagnostic.details {
					fmt.sbprintfln(&builder, "    %s", detail)
				}
				if diagnostic.hint != "" {
					fmt.sbprintfln(&builder, "    hint: %s", diagnostic.hint)
				}
			}
		}
		if errors >= COMPILER_ERROR_LIMIT {
			fmt.sbprintfln(&builder, "[%s] the compiler stopped at its error limit; more errors may exist", step.step.name)
		}
		for line, index in step.output.other {
			if index >= OTHER_LINES_MAX {
				break
			}
			fmt.sbprintfln(&builder, "[%s] %s", step.step.name, line)
		}
		if !succeeded(step.result) && errors == 0 {
			lines := strings.split_lines(strings.trim_space(step.result.output), context.temp_allocator)
			fmt.sbprintfln(
				&builder, "[%s] exit %d without compiler errors; last output:",
				step.step.name, step.result.exit_code,
			)
			for line in lines[max(0, len(lines) - TAIL_LINES):] {
				fmt.sbprintfln(&builder, "    %s", line)
			}
		}
	}
	total := 0
	for step in report.steps {
		total += len(step.output.diagnostics)
	}
	if total > shown {
		fmt.sbprintfln(&builder, "%d more diagnostics are hidden; raise --max to list them", total - shown)
	}
	return strings.to_string(builder)
}
