package usage

import "core:time"

EVENT_BUSY_TIMEOUT_MS :: 500
EVENT_DETAIL_BYTES_MAX :: 400
EVENT_REPORT_ROWS_MAX :: 100_000
EVENT_LIST_SHOWN :: 8
AFTER_BLOCK_WINDOW :: 10 * time.Minute
RUNNING_WINDOW :: 15 * time.Minute

Command_Event :: struct {
	started_at_ns: i64,
	duration_ns:   i64,
	build:         string,
	agent:         string,
	session:       string,
	project:       string,
	command:       string,
	via:           string,
	outcome:       string,
	reason:        string,
	detail:        string,
	errors:        int,
	warnings:      int,
	hints:         int,
	retries:       int,
	pins:          int,
	hunks:         int,
	results:       int,
	raw_bytes:     int,
	output_bytes:  int,
}

COMMAND_EVENT_TABLE :: `CREATE TABLE command_events (
	id INTEGER PRIMARY KEY,
	started_at_ns INTEGER NOT NULL,
	duration_ns INTEGER NOT NULL,
	build TEXT NOT NULL,
	agent TEXT NOT NULL,
	session TEXT NOT NULL,
	project TEXT NOT NULL,
	command TEXT NOT NULL,
	via TEXT NOT NULL,
	outcome TEXT NOT NULL,
	reason TEXT NOT NULL,
	detail TEXT NOT NULL,
	errors INTEGER NOT NULL,
	warnings INTEGER NOT NULL,
	hints INTEGER NOT NULL,
	retries INTEGER NOT NULL,
	pins INTEGER NOT NULL,
	hunks INTEGER NOT NULL,
	results INTEGER NOT NULL,
	raw_bytes INTEGER NOT NULL,
	output_bytes INTEGER NOT NULL
);
CREATE INDEX command_events_time_idx ON command_events(started_at_ns);`

open_event_database :: proc() -> (^SQLite_DB, bool) {
	path, overridden, resolved := resolve_database_path(context.temp_allocator)
	if !resolved || !ensure_database_directory(path, overridden) {
		return nil, false
	}
	database, opened := sqlite_open(path)
	if !opened {
		return nil, false
	}
	_ = sqlite3_busy_timeout(database, EVENT_BUSY_TIMEOUT_MS)
	if !initialize_schema(database) {
		_ = sqlite3_close_v2(database)
		return nil, false
	}
	secure_database_files(path)
	return database, true
}

bounded_detail :: proc(detail: string) -> string {
	if len(detail) <= EVENT_DETAIL_BYTES_MAX {
		return detail
	}
	end := EVENT_DETAIL_BYTES_MAX
	for end > 0 && detail[end] & 0xc0 == 0x80 {
		end -= 1
	}
	return detail[:end]
}

write_command_event :: proc(database: ^SQLite_DB, id: i64, event: Command_Event) -> bool {
	statement, prepared := sqlite_prepare(
		database,
		`INSERT OR REPLACE INTO command_events (
			id, started_at_ns, duration_ns, build, agent, session, project, command, via,
			outcome, reason, detail, errors, warnings, hints, retries, pins, hunks,
			results, raw_bytes, output_bytes
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
	if !prepared {
		return false
	}
	defer sqlite3_finalize(statement)
	bound := id == 0 ? sqlite3_bind_null(statement, 1) == SQLITE_OK : sqlite_bind_i64_value(statement, 1, id)
	bound = bound && sqlite_bind_i64_value(statement, 2, event.started_at_ns) &&
		sqlite_bind_i64_value(statement, 3, event.duration_ns)
	texts := [?]string{
		event.build, event.agent, event.session, event.project, event.command, event.via,
		event.outcome, event.reason, bounded_detail(event.detail),
	}
	for text, index in texts {
		bound = bound && sqlite_bind_text_value(statement, 4 + index, text)
	}
	numbers := [?]int{
		event.errors, event.warnings, event.hints, event.retries, event.pins, event.hunks,
		event.results, event.raw_bytes, event.output_bytes,
	}
	for number, index in numbers {
		bound = bound && sqlite_bind_int_value(statement, 4 + len(texts) + index, number)
	}
	return bound && sqlite3_step(statement) == SQLITE_DONE
}

record_command_event :: proc(event: Command_Event, id: i64 = 0) -> (row: i64, ok: bool) {
	database := open_event_database() or_return
	defer sqlite3_close_v2(database)
	if !write_command_event(database, id, event) {
		return 0, false
	}
	return sqlite3_last_insert_rowid(database), true
}

load_command_events :: proc(days: int, project: string) -> (events: []Command_Event, ok: bool) {
	database := open_event_database() or_return
	defer sqlite3_close_v2(database)
	statement := sqlite_prepare(
		database,
		`SELECT started_at_ns, duration_ns, build, agent, session, project, command, via,
		        outcome, reason, detail, errors, warnings, hints, retries, pins, hunks,
		        results, raw_bytes, output_bytes
		 FROM command_events
		 WHERE started_at_ns >= ? AND (? = '' OR project = ?)
		 ORDER BY started_at_ns DESC, id DESC LIMIT ?`,
	) or_return
	defer sqlite3_finalize(statement)
	since := now_unix_ns() - i64(days) * i64(24 * time.Hour)
	if !sqlite_bind_i64_value(statement, 1, since) ||
	   !sqlite_bind_text_value(statement, 2, project) ||
	   !sqlite_bind_text_value(statement, 3, project) ||
	   !sqlite_bind_int_value(statement, 4, EVENT_REPORT_ROWS_MAX) {
		return nil, false
	}
	list := make([dynamic]Command_Event, context.temp_allocator)
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {
			break
		}
		if step != SQLITE_ROW {
			return nil, false
		}
		event: Command_Event
		event.started_at_ns = sqlite3_column_int64(statement, 0)
		event.duration_ns = sqlite3_column_int64(statement, 1)
		texts := [?]^string{
			&event.build, &event.agent, &event.session, &event.project, &event.command,
			&event.via, &event.outcome, &event.reason, &event.detail,
		}
		for text, index in texts {
			text^ = sqlite_column_string(statement, 2 + index, context.temp_allocator)
		}
		numbers := [?]^int{
			&event.errors, &event.warnings, &event.hints, &event.retries, &event.pins,
			&event.hunks, &event.results, &event.raw_bytes, &event.output_bytes,
		}
		for number, index in numbers {
			number^ = int(sqlite3_column_int(statement, i32(2 + len(texts) + index)))
		}
		append(&list, event)
	}
	return list[:], true
}
