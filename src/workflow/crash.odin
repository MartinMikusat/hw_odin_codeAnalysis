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
SYMBOLS_MATCHED :: "symbols: exact build match"
NO_REPORT :: "crash: no matching report in ~/Library/Logs/DiagnosticReports; pass --app or --report"
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

find_report :: proc(options: Crash_Options, session: Journal_Session) -> (path, outside_session: string) {
	if options.report != "" {
		return options.report, ""
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
		if !strings.contains(normalized_name(header.app_name), wanted) {
			continue
		}
		if session.id == "" {
			return report.path, ""
		}
		capture: struct {captureTime: string}
		if json.unmarshal_string(text[newline + 1:], &capture, allocator = context.temp_allocator) == nil {
			if captured_ms, timed := capture_time_ms(capture.captureTime); timed && journal_session_contains(session, captured_ms) {
				return report.path, ""
			}
		}
		if outside_session == "" {
			outside_session = report.path
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
	stamp := strings.concatenate(
		{fields[0], "T", fields[1], fields[2][:3], ":", fields[2][3:]}, context.temp_allocator,
	)
	parsed, consumed := time.rfc3339_to_time_utc(stamp)
	if consumed != len(stamp) {
		return
	}
	return time.to_unix_nanoseconds(parsed) / 1_000_000, true
}

Journal_Record :: struct {
	timestampMs: i64,
	session:     string,
	kind:        string,
	severity:    string,
	outcome:     string,
	feature:     string,
	operation:   string,
	stage:       string,
	reason:      string,
	detail:      string,
	message:     string,
	source:      string,
	line:        int,
}

Journal_Session :: struct {
	id: string,
	first_ms, stopped_ms: i64,
	failures: []Journal_Record,
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

latest_journal_session :: proc(directory: string) -> (session: Journal_Session) {
	batches := [2][]Journal_Record{
		journal_records(join(directory, "devlog.jsonl.1")),
		journal_records(join(directory, "devlog.jsonl")),
	}
	for records in batches {
		for record in records {
			if record.session != "" && record.timestampMs > 0 {
				session.id = record.session
			}
		}
	}
	if session.id == "" {
		return
	}

	failures := make([dynamic]Journal_Record, context.temp_allocator)
	for records in batches {
		for record in records {
			if record.session != session.id || record.timestampMs <= 0 {
				continue
			}
			if session.first_ms == 0 || record.timestampMs < session.first_ms {
				session.first_ms = record.timestampMs
			}
			if record.feature == "devlog" && record.operation == "shutdown" && record.outcome == "stopped" {
				session.stopped_ms = record.timestampMs
			}
			if record.severity == "error" || record.severity == "critical" {
				append(&failures, record)
			}
		}
	}
	session.failures = failures[max(0, len(failures) - JOURNAL_LINES):]
	return
}

journal_session_contains :: proc(session: Journal_Session, timestamp_ms: i64) -> bool {
	return session.id != "" && timestamp_ms >= session.first_ms &&
		(session.stopped_ms == 0 || timestamp_ms <= session.stopped_ms)
}

write_session_failures :: proc(builder: ^strings.Builder, session: Journal_Session) {
	fmt.sbprintfln(builder, "Latest dev-log session %s", session.id)
	if len(session.failures) == 0 {
		fmt.sbprintln(builder, "No errors in the retained operation journal for this session.")
		return
	}
	for record in session.failures {
		fmt.sbprintf(builder, "  %+.1fs %s %s/%s", f64(record.timestampMs - session.first_ms) / 1000,
			record.severity, record.feature, record.operation)
		if record.stage != "" {
			fmt.sbprintf(builder, " [%s]", record.stage)
		}
		fmt.sbprintf(builder, " %s", record.reason)
		if record.detail != "" {
			fmt.sbprintf(builder, " (%s)", record.detail)
		}
		strings.write_byte(builder, '\n')
	}
}

write_session_fatals :: proc(builder: ^strings.Builder, directory: string, session: Journal_Session) {
	fatals := make([dynamic]Journal_Record, context.temp_allocator)
	for record in journal_records(join(directory, "fatal.jsonl")) {
		if journal_session_contains(session, record.timestampMs) {
			append(&fatals, record)
		}
	}
	for record in fatals[max(0, len(fatals) - JOURNAL_LINES):] {
		cause := record.message != "" ? record.message : record.reason
		fmt.sbprintf(builder, "  %+.1fs fatal %s %s", f64(record.timestampMs - session.first_ms) / 1000,
			record.kind, cause)
		if record.source != "" {
			fmt.sbprintf(builder, " (%s:%d)", record.source, record.line)
		}
		strings.write_byte(builder, '\n')
	}
}

write_journal :: proc(builder: ^strings.Builder, directory: string, crash_ms: i64, session := Journal_Session{}) -> (assertion: string) {
	for record in journal_records(join(directory, "fatal.jsonl")) {
		if abs(record.timestampMs - crash_ms) > FATAL_WINDOW_MS ||
		   (session.id != "" && !journal_session_contains(session, record.timestampMs)) {
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
		if (session.id == "" || session.id == record.session) &&
		   record.timestampMs <= crash_ms + 1000 && record.timestampMs >= crash_ms - FATAL_WINDOW_MS {
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

crash :: proc(options: Crash_Options) -> (text: string, ok, has_report: bool) {
	builder := strings.builder_make(context.temp_allocator)
	session: Journal_Session
	if options.devlog != "" && options.report == "" {
		session = latest_journal_session(options.devlog)
		if session.id != "" {
			write_session_failures(&builder, session)
		}
	}
	path, outside_session := find_report(options, session)
	if path == "" {
		if session.id == "" {
			return NO_REPORT, false, false
		}
		write_session_fatals(&builder, options.devlog, session)
		fmt.sbprintln(&builder, "No matching macOS crash report for this session.")
		if outside_session != "" {
			fmt.sbprintfln(&builder, "Unmatched macOS report: %s", outside_session)
		}
		return strings.to_string(builder), true, false
	}
	source, read := read_text(path)
	if !read {
		return fmt.tprintf("crash: %s could not be read", path), false, false
	}
	newline := strings.index_byte(source, '\n')
	if newline < 0 {
		return "crash: the report has no body", false, false
	}
	header: IPS_Header
	body: IPS_Body
	if json.unmarshal_string(source[:newline], &header, allocator = context.temp_allocator) != nil ||
	   json.unmarshal_string(source[newline + 1:], &body, allocator = context.temp_allocator) != nil {
		return "crash: the report is not in the expected format", false, false
	}
	if body.faultingThread < 0 || body.faultingThread >= len(body.threads) {
		return "crash: the report names no faulting thread", false, false
	}
	thread := body.threads[body.faultingThread]
	if session.id != "" {
		fmt.sbprintln(&builder, "macOS crash report matches this session by app and capture time.")
	} else if options.devlog != "" && options.report == "" {
		fmt.sbprintln(&builder, "No dev-log session was found. Showing the newest matching macOS report.")
	}
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
		fmt.sbprintfln(&builder, "%s %s", SYMBOLS_MATCHED, dwarf_used)
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
			found_assertion := write_journal(&journal, directory, crash_ms, session)
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
	return strings.to_string(builder), true, true
}
