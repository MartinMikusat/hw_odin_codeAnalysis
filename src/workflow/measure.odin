package workflow

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

RUNS_DEFAULT :: 10
RUNS_MAX :: 200
HISTORY_BYTES_MAX :: 4 * 1024 * 1024
DISASSEMBLY_LINES :: 200
SYMBOLS_LISTED :: 30

Compare_Options :: struct {
	root:    string,
	name:    string,
	command: []string,
	runs:    int,
}

Measurement :: struct {
	unix_ms:  i64,
	commit:   string,
	modified: bool,
	command:  string,
	seconds:  []f64,
}

Hyperfine_Result :: struct {
	times: []f64,
}

Hyperfine_Output :: struct {
	results: []Hyperfine_Result,
}

Statistics :: struct {
	median:    f64,
	deviation: f64,
	minimum:   f64,
	maximum:   f64,
}

shell_quote :: proc(arguments: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for argument, index in arguments {
		if index > 0 {
			strings.write_byte(&builder, ' ')
		}
		escaped, _ := strings.replace_all(argument, "'", `'\''`, context.temp_allocator)
		fmt.sbprintf(&builder, "'%s'", escaped)
	}
	return strings.to_string(builder)
}

median_of :: proc(values: []f64) -> f64 {
	assert(len(values) > 0)
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	middle := len(sorted) / 2
	return len(sorted) % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

statistics :: proc(values: []f64) -> Statistics {
	result := Statistics{median = median_of(values), minimum = values[0], maximum = values[0]}
	deviations := make([]f64, len(values), context.temp_allocator)
	for value, index in values {
		deviations[index] = math.abs(value - result.median)
		result.minimum = min(result.minimum, value)
		result.maximum = max(result.maximum, value)
	}
	result.deviation = median_of(deviations)
	return result
}

history_path :: proc(root, name: string) -> (path: string, ok: bool) {
	for character in name {
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return
		}
	}
	if name == "" {
		return
	}
	project := fmt.tprintf("%s-%08x", filepath.base(root), u32(hash.fnv64a(transmute([]byte)root)))
	directory := home_path("Library/Application Support/hw_odin_codeAnalysis/perf", project)
	if os.make_directory_all(directory) != nil && !os.is_directory(directory) {
		return
	}
	return join(directory, strings.concatenate({name, ".jsonl"}, context.temp_allocator)), true
}

compare :: proc(options: Compare_Options) -> (text: string, ok: bool) {
	if len(options.command) == 0 {
		return "perf compare: provide a command after --", false
	}
	path, valid := history_path(options.root, options.name)
	if !valid {
		return "perf compare: --name needs letters, digits, '-' or '_'", false
	}
	runs := options.runs > 0 ? min(options.runs, RUNS_MAX) : RUNS_DEFAULT
	directory, directory_error := os.make_directory_temp("", "hw-odin-compare-*", context.temp_allocator)
	if directory_error != nil {
		return "perf compare: no temporary directory could be created", false
	}
	defer os.remove_all(directory)
	exported := join(directory, "result.json")
	command_text := shell_quote(options.command)
	working, _ := os.get_working_directory(context.temp_allocator)
	measured := run({
		"hyperfine", "--shell=none", "--warmup", "1", "--runs", fmt.tprintf("%d", runs),
		"--export-json", exported, "--style", "none", command_text,
	}, working, 60 * time.Minute)
	source, found := read_text(exported)
	output: Hyperfine_Output
	if !succeeded(measured) || !found ||
	   json.unmarshal_string(source, &output, allocator = context.temp_allocator) != nil ||
	   len(output.results) != 1 || len(output.results[0].times) == 0 {
		return fmt.tprintf("perf compare: measurement failed\n%s", measured.output), false
	}
	commit := git(options.root, "rev-parse", "--short=12", "HEAD")
	status := git(options.root, "status", "--porcelain", "--untracked-files=no")
	current := Measurement{
		unix_ms = time.to_unix_nanoseconds(time.now()) / 1_000_000,
		commit = succeeded(commit) ? strings.trim_space(commit.output) : "unknown",
		modified = len(strings.trim_space(status.output)) > 0,
		command = command_text,
		seconds = output.results[0].times,
	}
	history, _ := read_text(path)
	baseline: Measurement
	has_baseline := false
	remaining := history
	for line in strings.split_lines_iterator(&remaining) {
		previous: Measurement
		if json.unmarshal_string(line, &previous, allocator = context.temp_allocator) != nil ||
		   len(previous.seconds) == 0 {
			continue
		}
		if previous.command == current.command &&
		   (previous.commit != current.commit || previous.modified != current.modified) {
			baseline = previous
			has_baseline = true
		}
	}
	line, encode_error := json.marshal(current, allocator = context.temp_allocator)
	if encode_error != nil {
		return "perf compare: the result could not be encoded", false
	}
	if len(history) > HISTORY_BYTES_MAX {
		newline := strings.index_byte(history[len(history) / 2:], '\n')
		history = newline < 0 ? "" : history[len(history) / 2 + newline + 1:]
	}
	appended := strings.concatenate({history, string(line), "\n"}, context.temp_allocator)
	if os.write_entire_file(path, appended) != nil {
		return "perf compare: the history could not be written", false
	}
	now := statistics(current.seconds)
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(
		&builder, "%s @ %s%s: median %.2f ms, deviation %.2f ms, range %.2f-%.2f ms, %d runs",
		options.name, current.commit, current.modified ? " (modified)" : "", now.median * 1000,
		now.deviation * 1000, now.minimum * 1000, now.maximum * 1000, len(current.seconds),
	)
	if !has_baseline {
		fmt.sbprintln(&builder, "no earlier result for another commit; this run is the baseline")
		return strings.to_string(builder), true
	}
	before := statistics(baseline.seconds)
	change := 100 * (now.median - before.median) / before.median
	noise := 100 * 3 * max(now.deviation, before.deviation) / before.median
	verdict := "within noise"
	if change > max(noise, 1) {
		verdict = "slower"
	} else if change < -max(noise, 1) {
		verdict = "faster"
	}
	fmt.sbprintfln(
		&builder, "baseline @ %s%s: median %.2f ms | change %.1f%%, noise band %.1f%% -> %s",
		baseline.commit, baseline.modified ? " (modified)" : "", before.median * 1000,
		change, noise, verdict,
	)
	return strings.to_string(builder), true
}

is_vector_instruction :: proc(operands: string) -> bool {
	markers := [?]string{".2d", ".4s", ".8h", ".16b", ".2s", ".4h", ".8b"}
	for marker in markers {
		if strings.contains(operands, marker) {
			return true
		}
	}
	return false
}

disassemble :: proc(binary, pattern: string, full: bool) -> (text: string, ok: bool) {
	listed := run({"nm", "-n", "-U", binary})
	if !succeeded(listed) {
		return fmt.tprintf("perf asm: symbols could not be listed\n%s", listed.output), false
	}
	matches := make([dynamic]string, context.temp_allocator)
	exact := ""
	output := listed.output
	for line in strings.split_lines_iterator(&output) {
		first := strings.index_byte(line, ' ')
		if first < 0 || first + 3 > len(line) {
			continue
		}
		kind := line[first + 1]
		if kind != 't' && kind != 'T' {
			continue
		}
		name := line[first + 3:]
		if name == pattern || name == strings.concatenate({"_", pattern}, context.temp_allocator) ||
		   strings.has_suffix(name, strings.concatenate({"::", pattern}, context.temp_allocator)) {
			exact = name
		}
		if strings.contains(name, pattern) {
			append(&matches, name)
		}
	}
	symbol := exact
	if symbol == "" && len(matches) == 1 {
		symbol = matches[0]
	}
	if symbol == "" {
		builder := strings.builder_make(context.temp_allocator)
		fmt.sbprintfln(
			&builder, "perf asm: %d symbols match %q; give one full name. " +
			"An inlined procedure has no symbol of its own.", len(matches), pattern,
		)
		for name, index in matches {
			if index >= SYMBOLS_LISTED {
				break
			}
			fmt.sbprintfln(&builder, "  %s", name)
		}
		return strings.to_string(builder), false
	}
	dumped := run({
		"xcrun", "llvm-objdump", "--disassemble", "--no-show-raw-insn",
		strings.concatenate({"--disassemble-symbols=", symbol}, context.temp_allocator), binary,
	})
	if !succeeded(dumped) {
		return fmt.tprintf("perf asm: disassembly failed\n%s", dumped.output), false
	}
	instructions := make([dynamic]string, context.temp_allocator)
	vectors, calls, checks := 0, 0, 0
	called := make(map[string]int, allocator = context.temp_allocator)
	body := dumped.output
	for line in strings.split_lines_iterator(&body) {
		colon := strings.index_byte(line, ':')
		if colon < 0 || colon + 1 >= len(line) || line[colon + 1] != '\t' && line[colon + 1] != ' ' {
			continue
		}
		instruction := strings.trim_space(line[colon + 1:])
		if instruction == "" || strings.has_prefix(instruction, "file format") {
			continue
		}
		append(&instructions, line)
		if is_vector_instruction(instruction) {
			vectors += 1
		}
		fields := strings.fields(instruction, context.temp_allocator)
		if fields[0] == "bl" || fields[0] == "blr" {
			calls += 1
			target := instruction
			if open := strings.index_byte(instruction, '<'); open >= 0 {
				target = strings.trim_suffix(instruction[open + 1:], ">")
			}
			called[target] += 1
			if strings.contains(target, "bounds_check") || strings.contains(target, "slice_expr_error") ||
			   strings.contains(target, "slice_handle_error") {
				checks += 1
			}
		}
	}
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(
		&builder, "%s: %d instructions, %d vector instructions, %d calls, %d bounds-check failure sites",
		symbol, len(instructions), vectors, calls, checks,
	)
	for target in costliest_counts(called) {
		fmt.sbprintfln(&builder, "  calls %s x%d", target.key, target.weight)
	}
	for instruction, index in instructions {
		if !full && index >= DISASSEMBLY_LINES {
			fmt.sbprintfln(&builder, "%d more instructions; pass --full", len(instructions) - index)
			break
		}
		fmt.sbprintln(&builder, instruction)
	}
	return strings.to_string(builder), true
}

costliest_counts :: proc(values: map[string]int) -> []Cost {
	widened := make(map[string]i64, allocator = context.temp_allocator)
	for key, value in values {
		widened[key] = i64(value)
	}
	return costliest(widened)
}
