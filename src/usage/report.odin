package usage

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Status_Report :: struct {
	database_path: string,
	schema_version: int,
	application_id: int,
	database_bytes: i64,
	wal_bytes: i64,
	shm_bytes: i64,
	session_count: i64,
	event_count: i64,
	payload_count: i64,
	oldest_event_at_ns: i64,
	newest_event_at_ns: i64,
	last_payload_prune_ns: i64,
	payload_retention_days: int,
}

Summary_Group :: struct {
	workspace_root: string,
	method: string,
	tool_name: string,
	event_count: i64,
	success_count: i64,
	error_count: i64,
	batch_size: i64,
	result_count: i64,
	empty_result_count: i64,
	not_found_count: i64,
	ambiguous_count: i64,
	unresolved_count: i64,
	truncated_count: i64,
	request_bytes: i64,
	response_bytes: i64,
	average_duration_ns: i64,
	p50_duration_ns: i64,
	p95_duration_ns: i64,
	max_duration_ns: i64,
}

Summary_Report :: struct {
	database_path: string,
	days: int,
	root_filter: string `json:"root_filter,omitempty"`,
	since_ns: i64,
	generated_at_ns: i64,
	total_events: i64,
	tool_calls: i64,
	success_count: i64,
	tool_error_count: i64,
	protocol_error_count: i64,
	notification_count: i64,
	ignored_count: i64,
	logger_gap_count: i64,
	payloads_retained: i64,
	groups: []Summary_Group,
}

Recent_Event :: struct {
	event_id: i64,
	session_id: i64,
	sequence: i64,
	workspace_root: string,
	event_kind: string,
	method: string `json:"method,omitempty"`,
	tool_name: string `json:"tool_name,omitempty"`,
	outcome: string,
	received_at_ns: i64,
	duration_ns: i64,
	generation: u64,
	batch_size: int,
	result_count: int,
	empty_result_count: int,
	not_found_count: int,
	ambiguous_count: int,
	unresolved_count: int,
	truncated: bool,
	error_code: int,
	error_message: string `json:"error_message,omitempty"`,
	request_bytes: i64,
	response_bytes: i64,
	request_sha256: string,
	response_sha256: string `json:"response_sha256,omitempty"`,
	request_payload_encoding: string `json:"request_payload_encoding,omitempty"`,
	request_payload: string `json:"request_payload,omitempty"`,
	response_payload_encoding: string `json:"response_payload_encoding,omitempty"`,
	response_payload: string `json:"response_payload,omitempty"`,
}

Recent_Report :: struct {
	database_path: string,
	days: int,
	root_filter: string `json:"root_filter,omitempty"`,
	tool_filter: string `json:"tool_filter,omitempty"`,
	limit: int,
	include_payloads: bool,
	events: []Recent_Event,
}

Summary_Accumulator :: struct {
	group: Summary_Group,
	duration_sum: i64,
	durations: [dynamic]i64,
}

open_report_database :: proc(allocator := context.allocator) -> (
	database: ^SQLite_DB,
	path: string,
	ok: bool,
) {
	path, ok = database_path(allocator)
	if !ok || !os.exists(path) {
		return nil, path, false
	}
	database, ok = sqlite_open(path, readonly = true)
	if !ok {
		return nil, path, false
	}
	application_id, application_ok := database_pragma_int(database, "PRAGMA application_id")
	version, version_ok := database_pragma_int(database, "PRAGMA user_version")
	if !application_ok || !version_ok || application_id != APPLICATION_ID || version != SCHEMA_VERSION {
		_ = sqlite3_close_v2(database)
		return nil, path, false
	}
	return
}

database_scalar_i64 :: proc(database: ^SQLite_DB, sql: string) -> (i64, bool) {
	statement, prepared := sqlite_prepare(database, sql)
	if !prepared {
		return 0, false
	}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {
		return 0, false
	}
	return sqlite3_column_int64(statement, 0), true
}

file_size :: proc(path: string) -> i64 {
	information, error := os.stat(path, context.temp_allocator)
	if error != nil {
		return 0
	}
	defer os.file_info_delete(information, context.temp_allocator)
	return information.size
}

status :: proc(allocator := context.allocator) -> (report: Status_Report, ok: bool) {
	database, path, opened := open_report_database(allocator)
	if !opened {
		return report, false
	}
	defer sqlite3_close_v2(database)
	report.database_path = path
	report.schema_version = SCHEMA_VERSION
	report.application_id = APPLICATION_ID
	report.database_bytes = file_size(path)
	report.wal_bytes = file_size(fmt.aprintf("%s-wal", path, allocator = context.temp_allocator))
	report.shm_bytes = file_size(fmt.aprintf("%s-shm", path, allocator = context.temp_allocator))
	report.session_count, ok = database_scalar_i64(database, "SELECT COUNT(*) FROM mcp_sessions")
	if !ok { return report, false }
	report.event_count, ok = database_scalar_i64(database, "SELECT COUNT(*) FROM mcp_events")
	if !ok { return report, false }
	report.payload_count, ok = database_scalar_i64(database, "SELECT COUNT(*) FROM mcp_event_payloads")
	if !ok { return report, false }
	report.oldest_event_at_ns, _ = database_scalar_i64(database, "SELECT COALESCE(MIN(received_at_ns), 0) FROM mcp_events")
	report.newest_event_at_ns, _ = database_scalar_i64(database, "SELECT COALESCE(MAX(received_at_ns), 0) FROM mcp_events")
	report.last_payload_prune_ns, _ = database_scalar_i64(database, "SELECT COALESCE(value_int, 0) FROM usage_metadata WHERE key='last_payload_prune_ns'")
	report.payload_retention_days = PAYLOAD_RETENTION_DAYS
	return report, true
}

percentile :: proc(sorted_values: []i64, percent: int) -> i64 {
	if len(sorted_values) == 0 {
		return 0
	}
	index := (percent * len(sorted_values) + 99) / 100 - 1
	return sorted_values[clamp(index, 0, len(sorted_values) - 1)]
}

summary_group_more :: proc(a, b: Summary_Group) -> bool {
	if a.event_count != b.event_count {
		return a.event_count > b.event_count
	}
	if a.workspace_root != b.workspace_root {
		return strings.compare(a.workspace_root, b.workspace_root) < 0
	}
	if a.method != b.method {
		return strings.compare(a.method, b.method) < 0
	}
	return strings.compare(a.tool_name, b.tool_name) < 0
}

summary :: proc(
	days: int,
	root_filter := "",
	allocator := context.allocator,
) -> (report: Summary_Report, ok: bool) {
	database, path, opened := open_report_database(allocator)
	if !opened {
		return report, false
	}
	defer sqlite3_close_v2(database)
	report.database_path = path
	report.days = days
	report.root_filter = strings.clone(root_filter, allocator)
	report.generated_at_ns = now_unix_ns()
	report.since_ns = report.generated_at_ns - i64(days) * i64(24 * time.Hour)
	payload_cutoff_ns := payload_retention_cutoff(report.generated_at_ns)
	statement, prepared := sqlite_prepare(
		database,
		`SELECT s.workspace_root, COALESCE(e.method, ''), COALESCE(e.tool_name, ''),
		        e.outcome, e.duration_ns, e.batch_size, e.result_count,
		        e.empty_result_count, e.not_found_count, e.ambiguous_count,
		        e.unresolved_count, e.truncated, e.request_bytes, e.response_bytes,
		        p.event_id IS NOT NULL
		 FROM mcp_events e
		 JOIN mcp_sessions s ON s.id=e.session_id
		 LEFT JOIN mcp_event_payloads p
		        ON p.event_id=e.id AND e.received_at_ns >= ?
		 WHERE e.received_at_ns >= ?
		   AND (? IS NULL OR s.workspace_root=?)
		 ORDER BY e.received_at_ns`,
	)
	if !prepared {
		return report, false
	}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, payload_cutoff_ns) ||
	   !sqlite_bind_i64_value(statement, 2, report.since_ns) ||
	   !sqlite_bind_optional_text(statement, 3, root_filter) ||
	   !sqlite_bind_optional_text(statement, 4, root_filter) {
		return report, false
	}
	accumulators := make([dynamic]Summary_Accumulator, allocator)
	indices := make(map[string]int, context.temp_allocator)
	for sqlite3_step(statement) == SQLITE_ROW {
		workspace_root := sqlite_column_string(statement, 0, allocator)
		method := sqlite_column_string(statement, 1, allocator)
		tool_name := sqlite_column_string(statement, 2, allocator)
		outcome := sqlite_column_string(statement, 3, context.temp_allocator)
		key := fmt.aprintf("%s\x1f%s\x1f%s", workspace_root, method, tool_name, allocator = context.temp_allocator)
		index, found := indices[key]
		if !found {
			index = len(accumulators)
			indices[key] = index
			append(&accumulators, Summary_Accumulator{
				group = {
					workspace_root = workspace_root,
					method = method,
					tool_name = tool_name,
				},
				durations = make([dynamic]i64, allocator),
			})
		}
		accumulator := &accumulators[index]
		duration := sqlite3_column_int64(statement, 4)
		accumulator.group.event_count += 1
		if outcome == "ok" || outcome == "notification" || outcome == "ignored" {
			accumulator.group.success_count += 1
		} else {
			accumulator.group.error_count += 1
		}
		accumulator.group.batch_size += sqlite3_column_int64(statement, 5)
		accumulator.group.result_count += sqlite3_column_int64(statement, 6)
		accumulator.group.empty_result_count += sqlite3_column_int64(statement, 7)
		accumulator.group.not_found_count += sqlite3_column_int64(statement, 8)
		accumulator.group.ambiguous_count += sqlite3_column_int64(statement, 9)
		accumulator.group.unresolved_count += sqlite3_column_int64(statement, 10)
		accumulator.group.truncated_count += i64(sqlite3_column_int(statement, 11) != 0)
		accumulator.group.request_bytes += sqlite3_column_int64(statement, 12)
		accumulator.group.response_bytes += sqlite3_column_int64(statement, 13)
		accumulator.duration_sum += duration
		append(&accumulator.durations, duration)
		report.total_events += 1
		if method == "tools/call" { report.tool_calls += 1 }
		switch outcome {
		case "ok": report.success_count += 1
		case "tool_error": report.tool_error_count += 1
		case "protocol_error": report.protocol_error_count += 1
		case "notification": report.notification_count += 1
		case "ignored": report.ignored_count += 1
		case "logger_gap": report.logger_gap_count += 1
		}
		if sqlite3_column_int(statement, 14) != 0 {
			report.payloads_retained += 1
		}
	}
	report.groups = make([]Summary_Group, len(accumulators), allocator)
	for &accumulator, index in accumulators {
		slice.sort(accumulator.durations[:])
		accumulator.group.average_duration_ns = accumulator.duration_sum / i64(len(accumulator.durations))
		accumulator.group.p50_duration_ns = percentile(accumulator.durations[:], 50)
		accumulator.group.p95_duration_ns = percentile(accumulator.durations[:], 95)
		accumulator.group.max_duration_ns = accumulator.durations[len(accumulator.durations) - 1]
		report.groups[index] = accumulator.group
	}
	slice.sort_by(report.groups, summary_group_more)
	return report, true
}

payload_text :: proc(data: []byte, allocator := context.allocator) -> (
	encoding, value: string,
) {
	if utf8.valid_string(transmute(string)data) {
		return "utf8", strings.clone(transmute(string)data, allocator)
	}
	encoded, error := base64.encode(data, allocator = allocator)
	if error != nil {
		return "", ""
	}
	return "base64", transmute(string)encoded
}

recent :: proc(
	days: int,
	root_filter, tool_filter: string,
	limit: int,
	include_payloads: bool,
	allocator := context.allocator,
) -> (report: Recent_Report, ok: bool) {
	database, path, opened := open_report_database(allocator)
	if !opened {
		return report, false
	}
	defer sqlite3_close_v2(database)
	report.database_path = path
	report.days = days
	report.root_filter = strings.clone(root_filter, allocator)
	report.tool_filter = strings.clone(tool_filter, allocator)
	report.limit = limit
	report.include_payloads = include_payloads
	now_ns := now_unix_ns()
	since_ns := now_ns - i64(days) * i64(24 * time.Hour)
	payload_cutoff_ns := payload_retention_cutoff(now_ns)
	statement, prepared := sqlite_prepare(
		database,
		`SELECT e.id, e.session_id, e.sequence, s.workspace_root, e.event_kind,
		        COALESCE(e.method, ''), COALESCE(e.tool_name, ''), e.outcome,
		        e.received_at_ns, e.duration_ns, COALESCE(e.generation, 0),
		        COALESCE(e.batch_size, 0), COALESCE(e.result_count, 0),
		        COALESCE(e.empty_result_count, 0), COALESCE(e.not_found_count, 0),
		        COALESCE(e.ambiguous_count, 0), COALESCE(e.unresolved_count, 0),
		        e.truncated, COALESCE(e.error_code, 0), COALESCE(e.error_message, ''),
		        e.request_bytes, e.response_bytes, e.request_sha256,
		        COALESCE(e.response_sha256, ''), p.request_line, p.response_line
		 FROM mcp_events e
		 JOIN mcp_sessions s ON s.id=e.session_id
		 LEFT JOIN mcp_event_payloads p
		        ON p.event_id=e.id AND e.received_at_ns >= ?
		 WHERE e.received_at_ns >= ?
		   AND (? IS NULL OR s.workspace_root=?)
		   AND (? IS NULL OR e.tool_name=?)
		 ORDER BY e.received_at_ns DESC, e.id DESC
		 LIMIT ?`,
	)
	if !prepared {
		return report, false
	}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, payload_cutoff_ns) ||
	   !sqlite_bind_i64_value(statement, 2, since_ns) ||
	   !sqlite_bind_optional_text(statement, 3, root_filter) ||
	   !sqlite_bind_optional_text(statement, 4, root_filter) ||
	   !sqlite_bind_optional_text(statement, 5, tool_filter) ||
	   !sqlite_bind_optional_text(statement, 6, tool_filter) ||
	   !sqlite_bind_int_value(statement, 7, limit) {
		return report, false
	}
	events := make([dynamic]Recent_Event, allocator)
	for sqlite3_step(statement) == SQLITE_ROW {
		event := Recent_Event {
			event_id = sqlite3_column_int64(statement, 0),
			session_id = sqlite3_column_int64(statement, 1),
			sequence = sqlite3_column_int64(statement, 2),
			workspace_root = sqlite_column_string(statement, 3, allocator),
			event_kind = sqlite_column_string(statement, 4, allocator),
			method = sqlite_column_string(statement, 5, allocator),
			tool_name = sqlite_column_string(statement, 6, allocator),
			outcome = sqlite_column_string(statement, 7, allocator),
			received_at_ns = sqlite3_column_int64(statement, 8),
			duration_ns = sqlite3_column_int64(statement, 9),
			generation = u64(sqlite3_column_int64(statement, 10)),
			batch_size = int(sqlite3_column_int(statement, 11)),
			result_count = int(sqlite3_column_int(statement, 12)),
			empty_result_count = int(sqlite3_column_int(statement, 13)),
			not_found_count = int(sqlite3_column_int(statement, 14)),
			ambiguous_count = int(sqlite3_column_int(statement, 15)),
			unresolved_count = int(sqlite3_column_int(statement, 16)),
			truncated = sqlite3_column_int(statement, 17) != 0,
			error_code = int(sqlite3_column_int(statement, 18)),
			error_message = sqlite_column_string(statement, 19, allocator),
			request_bytes = sqlite3_column_int64(statement, 20),
			response_bytes = sqlite3_column_int64(statement, 21),
			request_sha256 = sqlite_column_string(statement, 22, allocator),
			response_sha256 = sqlite_column_string(statement, 23, allocator),
		}
		if include_payloads && sqlite3_column_type(statement, 24) != SQLITE_NULL {
			request_data := sqlite_column_blob_value(statement, 24, context.temp_allocator)
			event.request_payload_encoding, event.request_payload = payload_text(request_data, allocator)
		}
		if include_payloads && sqlite3_column_type(statement, 25) != SQLITE_NULL {
			response_data := sqlite_column_blob_value(statement, 25, context.temp_allocator)
			event.response_payload_encoding, event.response_payload = payload_text(response_data, allocator)
		}
		append(&events, event)
	}
	report.events = events[:]
	return report, true
}
