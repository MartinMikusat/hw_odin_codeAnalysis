package workflow

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

PROFILE_SECONDS_DEFAULT :: 30
PROFILE_SECONDS_MAX :: 600
PROFILE_TOP_DEFAULT :: 20
PROGRAM_LINES :: 5
STACK_DEPTH_MAX :: 512
LINE_ADDRESSES_MAX :: 400

Profile_Options :: struct {
	root:    string,
	command: []string,
	seconds: int,
	top:     int,
}

XML_Tag :: struct {
	name:    string,
	attributes: string,
	closing: bool,
	empty:   bool,
	end:     int,
}

Profile_Binary :: struct {
	name: string,
	path: string,
	uuid: string,
	base: i64,
}

Profile_Frame :: struct {
	name:    string,
	address: i64,
	binary:  string,
}

Cost :: struct {
	key:    string,
	weight: i64,
}

Address_Cost :: struct {
	frame:  string,
	weight: i64,
}

next_tag :: proc(source: string, start: int) -> (tag: XML_Tag, ok: bool) {
	open := strings.index_byte(source[start:], '<')
	if open < 0 {
		return
	}
	open += start + 1
	quoted := false
	end := open
	for end < len(source) && (quoted || source[end] != '>') {
		if source[end] == '"' {
			quoted = !quoted
		}
		end += 1
	}
	if end >= len(source) {
		return
	}
	body := source[open:end]
	tag.end = end + 1
	if strings.has_prefix(body, "/") {
		tag.closing = true
		body = body[1:]
	}
	if strings.has_suffix(body, "/") {
		tag.empty = true
		body = body[:len(body) - 1]
	}
	space := strings.index_byte(body, ' ')
	if space < 0 {
		tag.name = body
	} else {
		tag.name = body[:space]
		tag.attributes = body[space:]
	}
	return tag, true
}

attribute :: proc(attributes, name: string) -> string {
	key := strings.concatenate({" ", name, `="`}, context.temp_allocator)
	start := strings.index(attributes, key)
	if start < 0 {
		return ""
	}
	start += len(key)
	end := strings.index_byte(attributes[start:], '"')
	if end < 0 {
		return ""
	}
	return attributes[start:start + end]
}

decode_entities :: proc(value: string) -> string {
	if !strings.contains_rune(value, '&') {
		return value
	}
	result := value
	pairs := [?][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", `"`}, {"&apos;", "'"}, {"&amp;", "&"}}
	for pair in pairs {
		result, _ = strings.replace_all(result, pair[0], pair[1], context.temp_allocator)
	}
	return result
}

Profile_Totals :: struct {
	samples:   int,
	weight:    i64,
	self:      map[string]i64,
	inclusive: map[string]i64,
	addresses: map[string]Address_Cost,
	frames:    map[string]Profile_Frame,
	binaries:  map[string]Profile_Binary,
}

accumulate_profile :: proc(source: string) -> Profile_Totals {
	allocator := context.temp_allocator
	totals := Profile_Totals{
		self = make(map[string]i64, allocator = allocator),
		inclusive = make(map[string]i64, allocator = allocator),
		addresses = make(map[string]Address_Cost, allocator = allocator),
		frames = make(map[string]Profile_Frame, allocator = allocator),
		binaries = make(map[string]Profile_Binary, allocator = allocator),
	}
	weights := make(map[string]i64, allocator = allocator)
	backtraces := make(map[string][]string, allocator = allocator)
	stack := make([dynamic]string, allocator)
	counted := make(map[string]bool, allocator = allocator)
	row_weight: i64
	row_stack: []string
	backtrace_id := ""
	frame_id := ""
	position := 0
	for {
		tag := next_tag(source, position) or_break
		position = tag.end
		id := attribute(tag.attributes, "id")
		reference := attribute(tag.attributes, "ref")
		switch tag.name {
		case "row":
			if !tag.closing {
				row_weight = 0
				row_stack = nil
				continue
			}
			if row_weight == 0 || len(row_stack) == 0 {
				continue
			}
			totals.samples += 1
			totals.weight += row_weight
			clear(&counted)
			for key, depth in row_stack {
				frame := totals.frames[key] or_continue
				label := fmt.tprintf(
					"%s  [%s]", short_name(frame.name), totals.binaries[frame.binary].name,
				)
				if depth == 0 {
					totals.self[label] += row_weight
					cost := totals.addresses[key]
					cost.frame = key
					cost.weight += row_weight
					totals.addresses[key] = cost
				}
				if label not_in counted {
					counted[label] = true
					totals.inclusive[label] += row_weight
				}
			}
		case "weight":
			if tag.closing {
				continue
			}
			if reference != "" {
				row_weight = weights[reference]
			} else {
				end := strings.index_byte(source[position:], '<')
				if end >= 0 {
					value, _ := strconv.parse_i64(source[position:position + end], 10)
					row_weight = value
					weights[id] = value
				}
			}
		case "tagged-backtrace", "backtrace":
			if reference != "" {
				row_stack = backtraces[reference]
			} else if !tag.closing {
				if tag.name == "tagged-backtrace" || backtrace_id == "" {
					backtrace_id = id
					clear(&stack)
				}
				if tag.empty {
					backtrace_id = ""
				}
			} else if backtrace_id != "" && len(stack) > 0 {
				copied := make([]string, len(stack), allocator)
				copy(copied, stack[:])
				backtraces[backtrace_id] = copied
				row_stack = copied
				if tag.name == "tagged-backtrace" {
					backtrace_id = ""
				}
			}
		case "frame":
			if tag.closing {
				frame_id = ""
				continue
			}
			key := reference
			if reference == "" {
				key = id
				address_text := strings.trim_prefix(attribute(tag.attributes, "addr"), "0x")
				address, _ := strconv.parse_i64(address_text, 16)
				totals.frames[key] = {name = decode_entities(attribute(tag.attributes, "name")), address = address}
				if !tag.empty {
					frame_id = key
				}
			}
			if len(stack) < STACK_DEPTH_MAX {
				append(&stack, key)
			}
		case "binary":
			if tag.closing {
				continue
			}
			key := reference
			if reference == "" {
				key = id
				base_text := strings.trim_prefix(attribute(tag.attributes, "load-addr"), "0x")
				base, _ := strconv.parse_i64(base_text, 16)
				totals.binaries[key] = {
					name = decode_entities(attribute(tag.attributes, "name")),
					path = decode_entities(attribute(tag.attributes, "path")),
					uuid = strings.to_lower(attribute(tag.attributes, "UUID"), allocator),
					base = base,
				}
			}
			if frame_id != "" {
				frame := totals.frames[frame_id]
				frame.binary = key
				totals.frames[frame_id] = frame
			}
		}
	}
	return totals
}

short_name :: proc(name: string) -> string {
	specialization := strings.index(name, ":proc")
	return specialization < 0 ? name : name[:specialization]
}

source_label :: proc(symbolized: string) -> string {
	binary := strings.index(symbolized, " (in ")
	location := strings.last_index(symbolized, ") (")
	if binary < 0 || location < binary || !strings.has_suffix(symbolized, ")") {
		return symbolized
	}
	return fmt.tprintf(
		"%s  %s", symbolized[location + 3:len(symbolized) - 1], short_name(symbolized[:binary]),
	)
}

costliest :: proc(values: map[string]i64) -> []Cost {
	result := make([dynamic]Cost, context.temp_allocator)
	for key, weight in values {
		append(&result, Cost{key = key, weight = weight})
	}
	slice.sort_by(result[:], proc(a, b: Cost) -> bool {
		return a.weight > b.weight || (a.weight == b.weight && a.key < b.key)
	})
	return result[:]
}

source_line_costs :: proc(options: Profile_Options, totals: Profile_Totals) -> (costs: []Cost, note: string) {
	addresses := make([dynamic]Address_Cost, context.temp_allocator)
	for _, value in totals.addresses {
		append(&addresses, value)
	}
	slice.sort_by(addresses[:], proc(a, b: Address_Cost) -> bool {return a.weight > b.weight})
	symbols := project_symbols(options.root)
	program := options.command[0]
	adjacent := strings.concatenate({program, ".dSYM"}, context.temp_allocator)
	if os.is_directory(adjacent) {
		for uuid, dwarf in bundle_uuids({adjacent}) {
			symbols[uuid] = dwarf
		}
	}
	grouped := make(map[string][dynamic]Address_Cost, allocator = context.temp_allocator)
	for value in addresses[:min(len(addresses), LINE_ADDRESSES_MAX)] {
		frame := totals.frames[value.frame]
		if totals.binaries[frame.binary].uuid not_in symbols {
			continue
		}
		list := grouped[frame.binary]
		if list == nil {
			list = make([dynamic]Address_Cost, context.temp_allocator)
		}
		append(&list, value)
		grouped[frame.binary] = list
	}
	if len(grouped) == 0 {
		return nil, "no debug symbols match the profiled binary; build with -debug and run dsymutil for source lines"
	}
	lines := make(map[string]i64, allocator = context.temp_allocator)
	for binary_key, list in grouped {
		binary := totals.binaries[binary_key]
		requested := make([]i64, len(list), context.temp_allocator)
		for value, index in list {
			requested[index] = totals.frames[value.frame].address - 1
		}
		symbolized := symbolize(symbols[binary.uuid], binary.base, requested)
		if symbolized == nil {
			continue
		}
		for line, index in symbolized {
			lines[source_label(line)] += list[index].weight
		}
	}
	return costliest(lines), ""
}

write_costs :: proc(builder: ^strings.Builder, title: string, costs: []Cost, total: i64, top: int) {
	fmt.sbprintfln(builder, "%s:", title)
	for cost, index in costs {
		if index >= top {
			break
		}
		fmt.sbprintfln(
			builder, "  %5.1f%% %8.1f ms  %s",
			100 * f64(cost.weight) / f64(total), f64(cost.weight) / 1e6, cost.key,
		)
	}
}

profile :: proc(options: Profile_Options) -> (text: string, ok: bool) {
	if len(options.command) == 0 {
		return "perf profile: provide a command after --", false
	}
	options := options
	if options.seconds <= 0 {options.seconds = PROFILE_SECONDS_DEFAULT}
	if options.top <= 0 {options.top = PROFILE_TOP_DEFAULT}
	options.seconds = min(options.seconds, PROFILE_SECONDS_MAX)
	command := make([]string, len(options.command), context.temp_allocator)
	copy(command, options.command)
	if strings.contains_rune(command[0], '/') {
		working, _ := os.get_working_directory(context.temp_allocator)
		command[0] = absolute(working, command[0])
	}
	options.command = command
	directory, directory_error := os.make_directory_temp("", "hw-odin-profile-*", context.temp_allocator)
	if directory_error != nil {
		return "perf profile: no temporary directory could be created", false
	}
	defer os.remove_all(directory)
	trace := join(directory, "run.trace")
	table := join(directory, "samples.xml")
	record := make([dynamic]string, context.temp_allocator)
	append(
		&record, "xcrun", "xctrace", "record", "--template", "Time Profiler",
		"--time-limit", fmt.tprintf("%ds", options.seconds), "--output", trace,
		"--target-stdout", join(directory, "target.log"), "--launch", "--",
	)
	append(&record, ..command)
	recorded := run(record[:], "", time.Duration(options.seconds + 180) * time.Second)
	if !os.exists(trace) {
		return fmt.tprintf("perf profile: recording failed\n%s", recorded.output), false
	}
	exported := run({
		"xcrun", "xctrace", "export", "--input", trace, "--xpath",
		`/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]`, "--output", table,
	})
	source, found := read_text(table)
	if !succeeded(exported) || !found {
		return fmt.tprintf("perf profile: export failed or exceeded the size limit\n%s", exported.output), false
	}
	totals := accumulate_profile(source)
	builder := strings.builder_make(context.temp_allocator)
	if output, logged := read_text(join(directory, "target.log")); logged {
		lines := strings.split_lines(strings.trim_space(output), context.temp_allocator)
		fmt.sbprintln(&builder, "program output, last lines:")
		for line in lines[max(0, len(lines) - PROGRAM_LINES):] {
			fmt.sbprintfln(&builder, "  %s", line)
		}
	}
	if totals.samples == 0 {
		fmt.sbprintln(&builder, "perf profile: no running samples were recorded; lengthen the scenario")
		return strings.to_string(builder), false
	}
	fmt.sbprintfln(
		&builder, "profile: %s | %d samples, %.1f ms of CPU time",
		filepath.base(command[0]), totals.samples, f64(totals.weight) / 1e6,
	)
	write_costs(&builder, "self time by procedure", costliest(totals.self), totals.weight, options.top)
	write_costs(&builder, "inclusive time by procedure", costliest(totals.inclusive), totals.weight, options.top)
	lines, note := source_line_costs(options, totals)
	if note != "" {
		fmt.sbprintfln(&builder, "source lines: %s", note)
	} else {
		write_costs(&builder, "self time by source line", lines, totals.weight, options.top)
	}
	return strings.to_string(builder), true
}
