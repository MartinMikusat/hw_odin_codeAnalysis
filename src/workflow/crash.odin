package workflow

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

SYMBOL_BUNDLES_MAX :: 512
SYMBOL_SEARCH_DEPTH :: 6
REPORT_SCAN_MAX :: 200
FRAMES_SHOWN :: 40
JOURNAL_LINES :: 15
FATAL_WINDOW_MS :: 120 * 1000

Crash_Options :: struct {
	root:   string,
	app:    string,
	report: string,
	devlog: string,
}

IPS_Header :: struct {
	app_name:   string,
	slice_uuid: string,
}

IPS_Frame :: struct {
	imageOffset:    i64,
	imageIndex:     int,
	symbol:         string,
	symbolLocation: i64,
	sourceFile:     string,
	sourceLine:     int,
}

IPS_Thread :: struct {
	name:   string,
	queue:  string,
	frames: []IPS_Frame,
}

IPS_Image :: struct {
	base: i64,
	uuid: string,
	name: string,
}

IPS_Exception :: struct {
	type:    string,
	signal:  string,
	subtype: string,
}

IPS_Body :: struct {
	captureTime:    string,
	exception:      IPS_Exception,
	faultingThread: int,
	threads:        []IPS_Thread,
	usedImages:     []IPS_Image,
}

File_Time :: struct {
	path: string,
	time: time.Time,
}

normalized_name :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	lowered := strings.to_lower(value, context.temp_allocator)
	for character in lowered {
		switch character {
		case 'a' ..= 'z', '0' ..= '9':
			strings.write_rune(&builder, character)
		}
	}
	return strings.to_string(builder)
}

home_path :: proc(parts: ..string) -> string {
	home, _ := os.user_home_dir(context.temp_allocator)
	path := home
	for part in parts {
		path = join(path, part)
	}
	return path
}

newest_first :: proc(a, b: File_Time) -> bool {
	return time.diff(b.time, a.time) > 0
}

crash_reports :: proc() -> []File_Time {
	directory := home_path("Library/Logs/DiagnosticReports")
	entries, read_error := os.read_all_directory_by_path(directory, context.temp_allocator)
	if read_error != nil {
		return nil
	}
	reports := make([dynamic]File_Time, context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, ".ips") {
			append(&reports, File_Time{path = entry.fullpath, time = entry.modification_time})
		}
	}
	slice.sort_by(reports[:], newest_first)
	return reports[:]
}

find_report :: proc(options: Crash_Options) -> (path: string, ok: bool) {
	if options.report != "" {
		return options.report, true
	}
	wanted := normalized_name(options.app)
	if wanted == "" {
		wanted = strings.trim_prefix(normalized_name(filepath.base(options.root)), "hw")
	}
	if wanted == "" {
		return
	}
	for report, index in crash_reports() {
		if index >= REPORT_SCAN_MAX {
			break
		}
		text := read_text(report.path) or_continue
		newline := strings.index_byte(text, '\n')
		if newline < 0 {
			continue
		}
		header: IPS_Header
		if json.unmarshal_string(text[:newline], &header, allocator = context.temp_allocator) != nil {
			continue
		}
		if strings.contains(normalized_name(header.app_name), wanted) {
			return report.path, true
		}
	}
	return
}

collect_symbol_bundles :: proc(directory: string, depth: int, bundles: ^[dynamic]string) {
	if depth > SYMBOL_SEARCH_DEPTH || len(bundles) >= SYMBOL_BUNDLES_MAX {
		return
	}
	entries, read_error := os.read_all_directory_by_path(directory, context.temp_allocator)
	if read_error != nil {
		return
	}
	for entry in entries {
		if entry.type != .Directory {
			continue
		}
		if strings.has_suffix(entry.name, ".dSYM") {
			if len(bundles) < SYMBOL_BUNDLES_MAX {
				append(bundles, entry.fullpath)
			}
		} else if !strings.has_prefix(entry.name, ".") {
			collect_symbol_bundles(entry.fullpath, depth + 1, bundles)
		}
	}
}

bundle_uuids :: proc(bundles: []string) -> map[string]string {
	result := make(map[string]string, allocator = context.temp_allocator)
	if len(bundles) == 0 {
		return result
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "dwarfdump", "--uuid")
	append(&command, ..bundles)
	output := run(command[:]).output
	for line in strings.split_lines_iterator(&output) {
		if !strings.has_prefix(line, "UUID: ") {
			continue
		}
		rest := line[len("UUID: "):]
		space := strings.index_byte(rest, ' ')
		close := strings.index(rest, ") ")
		if space < 0 || close < 0 {
			continue
		}
		uuid := strings.to_lower(rest[:space], context.temp_allocator)
		if uuid not_in result {
			result[uuid] = rest[close + 2:]
		}
	}
	return result
}

project_symbols :: proc(root: string) -> map[string]string {
	bundles := make([dynamic]string, context.temp_allocator)
	entries, read_error := os.read_all_directory_by_path(root, context.temp_allocator)
	if read_error == nil {
		for entry in entries {
			if entry.type == .Directory && strings.has_suffix(entry.name, ".dSYM") {
				append(&bundles, entry.fullpath)
			}
		}
	}
	collect_symbol_bundles(join(root, "build"), 0, &bundles)
	return bundle_uuids(bundles[:])
}

symbolize :: proc(dwarf: string, base: i64, addresses: []i64) -> []string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "atos", "-o", dwarf, "-arch", "arm64", "-l", fmt.tprintf("0x%x", base))
	for address in addresses {
		append(&command, fmt.tprintf("0x%x", address))
	}
	result := run(command[:])
	if !succeeded(result) {
		return nil
	}
	lines := strings.split_lines(strings.trim_right(result.output, "\n"), context.temp_allocator)
	if len(lines) < len(addresses) {
		return nil
	}
	return lines[len(lines) - len(addresses):]
}

capture_time_ms :: proc(value: string) -> (milliseconds: i64, ok: bool) {
	fields := strings.fields(value, context.temp_allocator)
	if len(fields) != 3 || len(fields[2]) != 5 || len(fields[1]) < 8 {
		return
	}
	clock := fields[1][:8]
	stamp := strings.concatenate(
		{fields[0], "T", clock, fields[2][:3], ":", fields[2][3:]}, context.temp_allocator,
	)
	parsed, consumed := time.rfc3339_to_time_utc(stamp)
	if consumed == 0 {
		return
	}
	return time.to_unix_nanoseconds(parsed) / 1_000_000, true
}

Journal_Record :: struct {
	timestampMs: i64,
	kind:        string,
	severity:    string,
	outcome:     string,
	feature:     string,
	operation:   string,
	reason:      string,
	message:     string,
	source:      string,
	line:        int,
}

journal_records :: proc(path: string) -> []Journal_Record {
	records := make([dynamic]Journal_Record, context.temp_allocator)
	text, found := read_text(path)
	if !found {
		return nil
	}
	for line in strings.split_lines_iterator(&text) {
		record: Journal_Record
		if json.unmarshal_string(line, &record, allocator = context.temp_allocator) == nil {
			append(&records, record)
		}
	}
	return records[:]
}

write_journal :: proc(builder: ^strings.Builder, directory: string, crash_ms: i64) -> (assertion: string) {
	for record in journal_records(join(directory, "fatal.jsonl")) {
		if abs(record.timestampMs - crash_ms) > FATAL_WINDOW_MS {
			continue
		}
		text := fmt.tprintf(
			"%+.1fs %s: %s (%s:%d)", f64(record.timestampMs - crash_ms) / 1000, record.kind,
			record.message, record.source, record.line,
		)
		fmt.sbprintfln(builder, "fatal   %s", text)
		if record.kind == "assertion" && assertion == "" {
			assertion = text
		}
	}
	before := make([dynamic]Journal_Record, context.temp_allocator)
	for record in journal_records(join(directory, "devlog.jsonl")) {
		if record.timestampMs <= crash_ms + 1000 && record.timestampMs >= crash_ms - FATAL_WINDOW_MS {
			append(&before, record)
		}
	}
	for record in before[max(0, len(before) - JOURNAL_LINES):] {
		fmt.sbprintfln(
			builder, "journal %+.1fs %s %s/%s %s (%s:%d) %s",
			f64(record.timestampMs - crash_ms) / 1000, record.severity, record.feature,
			record.operation, record.outcome, record.source, record.line, record.reason,
		)
	}
	return
}

write_archived_log :: proc(builder: ^strings.Builder, dwarf: string) {
	marker := strings.index(dwarf, "/build/crashes/")
	if marker < 0 {
		return
	}
	bundle := strings.index(dwarf, ".dSYM/")
	if bundle < 0 {
		return
	}
	archive := filepath.dir(dwarf[:bundle])
	entries, read_error := os.read_all_directory_by_path(archive, context.temp_allocator)
	if read_error != nil {
		return
	}
	for entry in entries {
		if !strings.has_suffix(entry.name, ".log") {
			continue
		}
		text := read_text(entry.fullpath) or_continue
		lines := strings.split_lines(strings.trim_space(text), context.temp_allocator)
		fmt.sbprintfln(builder, "archived error output %s:", entry.fullpath)
		for line in lines[max(0, len(lines) - JOURNAL_LINES):] {
			fmt.sbprintfln(builder, "    %s", line)
		}
	}
}

crash :: proc(options: Crash_Options) -> (text: string, ok: bool) {
	path, found := find_report(options)
	if !found {
		return "crash: no matching report in ~/Library/Logs/DiagnosticReports; pass --app or --report", false
	}
	source, read := read_text(path)
	if !read {
		return fmt.tprintf("crash: %s could not be read", path), false
	}
	newline := strings.index_byte(source, '\n')
	if newline < 0 {
		return "crash: the report has no body", false
	}
	header: IPS_Header
	body: IPS_Body
	if json.unmarshal_string(source[:newline], &header, allocator = context.temp_allocator) != nil ||
	   json.unmarshal_string(source[newline + 1:], &body, allocator = context.temp_allocator) != nil {
		return "crash: the report is not in the expected format", false
	}
	if body.faultingThread < 0 || body.faultingThread >= len(body.threads) {
		return "crash: the report names no faulting thread", false
	}
	thread := body.threads[body.faultingThread]
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&builder, "report: %s", path)
	fmt.sbprintfln(
		&builder, "app: %s at %s | %s %s %s", header.app_name, body.captureTime,
		body.exception.type, body.exception.signal, body.exception.subtype,
	)

	symbols := project_symbols(options.root)
	resolved := make(map[int]string, allocator = context.temp_allocator)
	dwarf_used := ""
	for image, image_index in body.usedImages {
		dwarf := symbols[strings.to_lower(image.uuid, context.temp_allocator)] or_continue
		addresses := make([dynamic]i64, context.temp_allocator)
		positions := make([dynamic]int, context.temp_allocator)
		for frame, position in thread.frames {
			if position < FRAMES_SHOWN && frame.imageIndex == image_index {
				adjustment := i64(position > 0 ? 1 : 0)
				append(&addresses, image.base + frame.imageOffset - adjustment)
				append(&positions, position)
			}
		}
		if len(addresses) == 0 {
			continue
		}
		lines := symbolize(dwarf, image.base, addresses[:])
		if lines == nil {
			continue
		}
		dwarf_used = dwarf
		for line, index in lines {
			resolved[positions[index]] = line
		}
	}
	if dwarf_used != "" {
		fmt.sbprintfln(&builder, "symbols: exact build match %s", dwarf_used)
	} else {
		fmt.sbprintfln(
			&builder,
			"symbols: no debug symbols match build %s; names below come from the report and lines may be missing",
			header.slice_uuid,
		)
	}
	fmt.sbprintfln(
		&builder, "faulting thread %d %s %s", body.faultingThread, thread.name, thread.queue,
	)
	unlocated := false
	for frame, position in thread.frames {
		if position >= FRAMES_SHOWN {
			fmt.sbprintfln(&builder, "  %d more frames", len(thread.frames) - position)
			break
		}
		if strings.contains(frame.symbol, "default_assertion_contextless_failure_proc") ||
		   strings.contains(frame.symbol, "bounds_trap") {
			unlocated = true
		}
		image := ""
		if frame.imageIndex >= 0 && frame.imageIndex < len(body.usedImages) {
			image = body.usedImages[frame.imageIndex].name
		}
		if line, symbolized := resolved[position]; symbolized {
			fmt.sbprintfln(&builder, "  %2d %s", position, line)
		} else if frame.sourceFile != "" {
			fmt.sbprintfln(
				&builder, "  %2d %s %s (%s:%d)", position, image, frame.symbol,
				frame.sourceFile, frame.sourceLine,
			)
		} else {
			fmt.sbprintfln(&builder, "  %2d %s %s+%d", position, image, frame.symbol, frame.symbolLocation)
		}
	}
	assertion := ""
	journal := strings.builder_make(context.temp_allocator)
	crash_ms, timed := capture_time_ms(body.captureTime)
	if timed {
		directories := make([dynamic]string, context.temp_allocator)
		if options.devlog != "" {
			append(&directories, options.devlog)
		} else {
			entries, read_error := os.read_all_directory_by_path(
				join(options.root, ".dev-logs"), context.temp_allocator,
			)
			if read_error == nil {
				for entry in entries {
					if entry.type == .Directory {
						append(&directories, entry.fullpath)
					}
				}
			}
		}
		for directory in directories {
			found_assertion := write_journal(&journal, directory, crash_ms)
			if assertion == "" {
				assertion = found_assertion
			}
		}
	}
	if assertion != "" {
		fmt.sbprintfln(&builder, "recorded %s", assertion)
	} else if unlocated {
		fmt.sbprintln(
			&builder,
			"note: an Odin runtime check failed and no assertion record is near the crash time. " +
			"The failing line may be only in stderr. Assertions and bounds checks reach the journal " +
			"only through the devlog hook on this thread; contextless procedures print to stderr only.",
		)
	}
	strings.write_string(&builder, strings.to_string(journal))
	write_archived_log(&builder, dwarf_used)
	return strings.to_string(builder), true
}
