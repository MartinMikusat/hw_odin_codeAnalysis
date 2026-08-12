package usage

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

SCHEMA_VERSION         :: 1
APPLICATION_ID         :: 0x48574f44
PAYLOAD_RETENTION_DAYS :: 90
RETENTION_INTERVAL     :: 24 * time.Hour
RETRY_INTERVAL         :: 1 * time.Minute
PRIVATE_DIRECTORY_PERMISSIONS :: os.Permissions{
	.Read_User,
	.Write_User,
	.Execute_User,
}
PRIVATE_FILE_PERMISSIONS :: os.Permissions{
	.Read_User,
	.Write_User,
}

Event :: struct {
	event_kind: string,
	method: string,
	tool_name: string,
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
	error_message: string,
	request_line: []byte,
	response_line: []byte,
}

Store :: struct {
	database: ^SQLite_DB,
	path: string,
	path_overridden: bool,
	root: string,
	server_version: string,
	protocol_version: string,
	client_name: string,
	client_version: string,
	compiler_release: string,
	compiler_root: string,
	config_digest: string,
	session_started_at_ns: i64,
	session_id: i64,
	sequence: i64,
	last_retry: time.Tick,
	last_warning: time.Tick,
	last_retention_check: time.Tick,
	has_warned: bool,
	dropped_count: i64,
	dropped_first_ns: i64,
	dropped_last_ns: i64,
	initialized: bool,
}

now_unix_ns :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now())
}

payload_retention_cutoff :: proc(reference_ns := i64(0)) -> i64 {
	now_ns := reference_ns
	if now_ns == 0 {
		now_ns = now_unix_ns()
	}
	return now_ns - i64(PAYLOAD_RETENTION_DAYS) * i64(24 * time.Hour)
}

resolve_database_path :: proc(allocator := context.allocator) -> (
	path: string,
	overridden: bool,
	ok: bool,
) {
	if override, found := os.lookup_env("HW_ODIN_ANALYZE_USAGE_DB", context.temp_allocator);
	   found && strings.trim_space(override) != "" {
		if filepath.is_abs(override) {
			return strings.clone(override, allocator), true, true
		}
		absolute, error := os.get_absolute_path(override, allocator)
		return absolute, true, error == nil
	}
	data_directory, data_error := os.user_data_dir(context.temp_allocator)
	if data_error != nil {
		return "", false, false
	}
	joined_path, path_error := filepath.join(
		{data_directory, "hw_odin_codeAnalysis", "usage.sqlite3"},
		allocator,
	)
	return joined_path, false, path_error == nil
}

database_path :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	path, _, ok = resolve_database_path(allocator)
	return
}

ensure_database_directory :: proc(path: string, path_overridden: bool) -> bool {
	directory := filepath.dir(path)
	created := !os.exists(directory)
	if created {
		if os.make_directory_all(directory) != nil {
			return false
		}
	}
	if created || !path_overridden {
		_ = os.change_mode(directory, PRIVATE_DIRECTORY_PERMISSIONS)
	}
	return true
}

secure_database_files :: proc(path: string) {
	paths := [3]string{
		path,
		fmt.aprintf("%s-wal", path, allocator = context.temp_allocator),
		fmt.aprintf("%s-shm", path, allocator = context.temp_allocator),
	}
	for candidate in paths {
		if os.exists(candidate) {
			_ = os.change_mode(candidate, PRIVATE_FILE_PERMISSIONS)
		}
	}
}

database_pragma_int :: proc(database: ^SQLite_DB, sql: string) -> (int, bool) {
	statement, prepared := sqlite_prepare(database, sql)
	if !prepared {
		return 0, false
	}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {
		return 0, false
	}
	return int(sqlite3_column_int(statement, 0)), true
}

initialize_schema :: proc(database: ^SQLite_DB) -> bool {
	application_id, application_ok := database_pragma_int(database, "PRAGMA application_id")
	if !application_ok || application_id != 0 && application_id != APPLICATION_ID {
		return false
	}
	version, version_ok := database_pragma_int(database, "PRAGMA user_version")
	if !version_ok || version > SCHEMA_VERSION {
		return false
	}
	if !sqlite_execute(database, "PRAGMA journal_mode=WAL") ||
	   !sqlite_execute(database, "PRAGMA synchronous=NORMAL") ||
	   !sqlite_execute(database, "PRAGMA foreign_keys=ON") ||
	   !sqlite_execute(database, "PRAGMA trusted_schema=OFF") {
		return false
	}
	if version == 0 {
		if !sqlite_execute(database, "PRAGMA auto_vacuum=INCREMENTAL") ||
		   !sqlite_execute(database, "BEGIN IMMEDIATE") {
			return false
		}
		created := sqlite_execute(
			database,
			`CREATE TABLE usage_metadata (
				key TEXT PRIMARY KEY,
				value_int INTEGER,
				value_text TEXT
			);
			CREATE TABLE mcp_sessions (
				id INTEGER PRIMARY KEY,
				started_at_ns INTEGER NOT NULL,
				ended_at_ns INTEGER,
				workspace_root TEXT NOT NULL,
				pid INTEGER NOT NULL,
				server_version TEXT NOT NULL,
				protocol_version TEXT,
				client_name TEXT,
				client_version TEXT,
				compiler_release TEXT NOT NULL,
				compiler_root TEXT NOT NULL,
				config_digest TEXT NOT NULL
			);
			CREATE TABLE mcp_events (
				id INTEGER PRIMARY KEY,
				session_id INTEGER NOT NULL REFERENCES mcp_sessions(id),
				sequence INTEGER NOT NULL,
				event_kind TEXT NOT NULL,
				method TEXT,
				tool_name TEXT,
				outcome TEXT NOT NULL,
				received_at_ns INTEGER NOT NULL,
				duration_ns INTEGER NOT NULL,
				generation INTEGER,
				batch_size INTEGER,
				result_count INTEGER,
				empty_result_count INTEGER,
				not_found_count INTEGER,
				ambiguous_count INTEGER,
				unresolved_count INTEGER,
				truncated INTEGER NOT NULL,
				error_code INTEGER,
				error_message TEXT,
				request_bytes INTEGER NOT NULL,
				response_bytes INTEGER NOT NULL,
				request_sha256 TEXT NOT NULL,
				response_sha256 TEXT,
				UNIQUE(session_id, sequence)
			);
			CREATE TABLE mcp_event_payloads (
				event_id INTEGER PRIMARY KEY REFERENCES mcp_events(id) ON DELETE CASCADE,
				request_line BLOB NOT NULL,
				response_line BLOB
			);
			CREATE INDEX mcp_events_time_idx ON mcp_events(received_at_ns);
			CREATE INDEX mcp_events_tool_time_idx ON mcp_events(tool_name, received_at_ns);
			CREATE INDEX mcp_events_outcome_time_idx ON mcp_events(outcome, received_at_ns);
			CREATE INDEX mcp_sessions_root_time_idx ON mcp_sessions(workspace_root, started_at_ns);`,
		)
		if !created ||
		   !sqlite_execute(database, fmt.aprintf("PRAGMA application_id=%d", APPLICATION_ID, allocator = context.temp_allocator)) ||
		   !sqlite_execute(database, fmt.aprintf("PRAGMA user_version=%d", SCHEMA_VERSION, allocator = context.temp_allocator)) ||
		   !sqlite_execute(database, "COMMIT") {
			_ = sqlite_execute(database, "ROLLBACK")
			return false
		}
	}
	return true
}

insert_session :: proc(store: ^Store) -> bool {
	statement, prepared := sqlite_prepare(
		store.database,
		`INSERT INTO mcp_sessions (
			started_at_ns, workspace_root, pid, server_version,
			protocol_version, client_name, client_version,
			compiler_release, compiler_root, config_digest
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
	if !prepared {
		return false
	}
	defer sqlite3_finalize(statement)
	bound := sqlite_bind_i64_value(statement, 1, store.session_started_at_ns) &&
	         sqlite_bind_text_value(statement, 2, store.root) &&
	         sqlite_bind_int_value(statement, 3, int(posix.getpid())) &&
	         sqlite_bind_text_value(statement, 4, store.server_version) &&
	         sqlite_bind_optional_text(statement, 5, store.protocol_version) &&
	         sqlite_bind_optional_text(statement, 6, store.client_name) &&
	         sqlite_bind_optional_text(statement, 7, store.client_version) &&
	         sqlite_bind_text_value(statement, 8, store.compiler_release) &&
	         sqlite_bind_text_value(statement, 9, store.compiler_root) &&
	         sqlite_bind_text_value(statement, 10, store.config_digest)
	if !bound || sqlite3_step(statement) != SQLITE_DONE {
		return false
	}
	store.session_id = sqlite3_last_insert_rowid(store.database)
	return true
}

open_store_database :: proc(store: ^Store) -> bool {
	if !ensure_database_directory(store.path, store.path_overridden) {
		return false
	}
	database, opened := sqlite_open(store.path)
	if !opened {
		return false
	}
	if !initialize_schema(database) {
		_ = sqlite3_close_v2(database)
		return false
	}
	store.database = database
	store.session_started_at_ns = now_unix_ns()
	store.sequence = 0
	if !insert_session(store) {
		_ = sqlite3_close_v2(database)
		store.database = nil
		return false
	}
	secure_database_files(store.path)
	return true
}

store_init :: proc(
	store: ^Store,
	root, server_version, compiler_release, compiler_root, config_digest: string,
) -> bool {
	if store == nil {
		return false
	}
	path, path_overridden, path_ok := resolve_database_path(context.allocator)
	if !path_ok {
		fmt.eprintln("hw-odin-analyze: usage recording failed: could not resolve the database path")
		return false
	}
	store.path = path
	store.path_overridden = path_overridden
	store.root = strings.clone(root)
	store.server_version = strings.clone(server_version)
	store.compiler_release = strings.clone(compiler_release)
	store.compiler_root = strings.clone(compiler_root)
	store.config_digest = strings.clone(config_digest)
	store.session_started_at_ns = now_unix_ns()
	store.initialized = true
	store.last_retry = time.tick_now()
	opened := open_store_database(store)
	if !opened {
		warn_failure(store)
	}
	return opened
}

store_destroy :: proc(store: ^Store) {
	if store == nil || !store.initialized {
		return
	}
	if store.database != nil {
		statement, prepared := sqlite_prepare(
			store.database,
			"UPDATE mcp_sessions SET ended_at_ns=? WHERE id=?",
		)
		if prepared {
			_ = sqlite_bind_i64_value(statement, 1, now_unix_ns())
			_ = sqlite_bind_i64_value(statement, 2, store.session_id)
			_ = sqlite3_step(statement)
			_ = sqlite3_finalize(statement)
		}
		_ = sqlite3_close_v2(store.database)
	}
	delete(store.path)
	delete(store.root)
	delete(store.server_version)
	delete(store.protocol_version)
	delete(store.client_name)
	delete(store.client_version)
	delete(store.compiler_release)
	delete(store.compiler_root)
	delete(store.config_digest)
	store^ = {}
}

store_update_client :: proc(
	store: ^Store,
	protocol_version, client_name, client_version: string,
) -> bool {
	if store == nil || !store.initialized {
		return false
	}
	delete(store.protocol_version)
	delete(store.client_name)
	delete(store.client_version)
	store.protocol_version = strings.clone(protocol_version)
	store.client_name = strings.clone(client_name)
	store.client_version = strings.clone(client_version)
	if store.database == nil || store.session_id == 0 {
		return false
	}
	statement, prepared := sqlite_prepare(
		store.database,
		`UPDATE mcp_sessions
		 SET protocol_version=?, client_name=?, client_version=?
		 WHERE id=?`,
	)
	if !prepared {
		return false
	}
	defer sqlite3_finalize(statement)
	return sqlite_bind_optional_text(statement, 1, protocol_version) &&
	       sqlite_bind_optional_text(statement, 2, client_name) &&
	       sqlite_bind_optional_text(statement, 3, client_version) &&
	       sqlite_bind_i64_value(statement, 4, store.session_id) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

end_session :: proc(store: ^Store) -> bool {
	if store.database == nil || store.session_id == 0 {
		return false
	}
	statement, prepared := sqlite_prepare(
		store.database,
		"UPDATE mcp_sessions SET ended_at_ns=? WHERE id=?",
	)
	if !prepared {
		return false
	}
	defer sqlite3_finalize(statement)
	return sqlite_bind_i64_value(statement, 1, now_unix_ns()) &&
	       sqlite_bind_i64_value(statement, 2, store.session_id) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

store_update_context :: proc(
	store: ^Store,
	compiler_release, compiler_root, config_digest: string,
) -> bool {
	if store == nil || !store.initialized {
		return false
	}
	if store.compiler_release == compiler_release &&
	   store.compiler_root == compiler_root &&
	   store.config_digest == config_digest {
		return true
	}
	delete(store.compiler_release)
	delete(store.compiler_root)
	delete(store.config_digest)
	store.compiler_release = strings.clone(compiler_release)
	store.compiler_root = strings.clone(compiler_root)
	store.config_digest = strings.clone(config_digest)
	if store.database == nil || store.session_id == 0 {
		return false
	}
	if !sqlite_execute(store.database, "BEGIN IMMEDIATE") {
		close_failed_database(store)
		return false
	}
	if !end_session(store) {
		_ = sqlite_execute(store.database, "ROLLBACK")
		close_failed_database(store)
		return false
	}
	store.session_id = 0
	store.sequence = 0
	store.session_started_at_ns = now_unix_ns()
	if !insert_session(store) || !sqlite_execute(store.database, "COMMIT") {
		_ = sqlite_execute(store.database, "ROLLBACK")
		close_failed_database(store)
		return false
	}
	secure_database_files(store.path)
	return true
}

sha256_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	digest: [32]byte
	_ = hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	encoded, error := hex.encode(digest[:], allocator)
	if error != nil {
		return ""
	}
	return transmute(string)encoded
}

insert_event :: proc(store: ^Store, event: Event) -> bool {
	if store.database == nil || store.session_id == 0 {
		return false
	}
	statement, prepared := sqlite_prepare(
		store.database,
		`INSERT INTO mcp_events (
			session_id, sequence, event_kind, method, tool_name, outcome,
			received_at_ns, duration_ns, generation, batch_size, result_count,
			empty_result_count, not_found_count, ambiguous_count, unresolved_count,
			truncated, error_code, error_message, request_bytes, response_bytes,
			request_sha256, response_sha256
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
	if !prepared {
		return false
	}
	defer sqlite3_finalize(statement)
	request_hash := sha256_hex(event.request_line, context.temp_allocator)
	response_hash := ""
	if event.response_line != nil {
		response_hash = sha256_hex(event.response_line, context.temp_allocator)
	}
	bound := sqlite_bind_i64_value(statement, 1, store.session_id) &&
	         sqlite_bind_i64_value(statement, 2, store.sequence) &&
	         sqlite_bind_text_value(statement, 3, event.event_kind) &&
	         sqlite_bind_optional_text(statement, 4, event.method) &&
	         sqlite_bind_optional_text(statement, 5, event.tool_name) &&
	         sqlite_bind_text_value(statement, 6, event.outcome) &&
	         sqlite_bind_i64_value(statement, 7, event.received_at_ns) &&
	         sqlite_bind_i64_value(statement, 8, event.duration_ns) &&
	         sqlite_bind_i64_value(statement, 9, i64(event.generation)) &&
	         sqlite_bind_int_value(statement, 10, event.batch_size) &&
	         sqlite_bind_int_value(statement, 11, event.result_count) &&
	         sqlite_bind_int_value(statement, 12, event.empty_result_count) &&
	         sqlite_bind_int_value(statement, 13, event.not_found_count) &&
	         sqlite_bind_int_value(statement, 14, event.ambiguous_count) &&
	         sqlite_bind_int_value(statement, 15, event.unresolved_count) &&
	         sqlite_bind_bool_value(statement, 16, event.truncated) &&
	         sqlite_bind_int_value(statement, 17, event.error_code) &&
	         sqlite_bind_optional_text(statement, 18, event.error_message) &&
	         sqlite_bind_i64_value(statement, 19, i64(len(event.request_line))) &&
	         sqlite_bind_i64_value(statement, 20, i64(len(event.response_line))) &&
	         sqlite_bind_text_value(statement, 21, request_hash) &&
	         sqlite_bind_optional_text(statement, 22, response_hash)
	if !bound || sqlite3_step(statement) != SQLITE_DONE {
		return false
	}
	event_id := sqlite3_last_insert_rowid(store.database)
	payload, payload_prepared := sqlite_prepare(
		store.database,
		`INSERT INTO mcp_event_payloads (event_id, request_line, response_line)
		 VALUES (?, ?, ?)`,
	)
	if !payload_prepared {
		return false
	}
	defer sqlite3_finalize(payload)
	payload_bound := sqlite_bind_i64_value(payload, 1, event_id) &&
	                 sqlite_bind_blob_value(payload, 2, event.request_line)
	if event.response_line == nil {
		payload_bound = payload_bound && sqlite3_bind_null(payload, 3) == SQLITE_OK
	} else {
		payload_bound = payload_bound && sqlite_bind_blob_value(payload, 3, event.response_line)
	}
	return payload_bound && sqlite3_step(payload) == SQLITE_DONE
}

record_gap :: proc(store: ^Store) -> bool {
	if store.dropped_count == 0 {
		return true
	}
	message := fmt.aprintf(
		"%d events were not persisted between %d and %d",
		store.dropped_count,
		store.dropped_first_ns,
		store.dropped_last_ns,
		allocator = context.temp_allocator,
	)
	store.sequence += 1
	ok := insert_event(
		store,
		Event{
			event_kind = "logger_gap",
			outcome = "logger_gap",
			received_at_ns = store.dropped_first_ns,
			duration_ns = max(store.dropped_last_ns - store.dropped_first_ns, 0),
			error_message = message,
			request_line = nil,
		},
	)
	return ok
}

close_failed_database :: proc(store: ^Store) {
	if store.database != nil {
		_ = sqlite3_close_v2(store.database)
		store.database = nil
	}
	store.session_id = 0
	store.last_retry = time.tick_now()
}

warn_failure :: proc(store: ^Store) {
	now := time.tick_now()
	if !store.has_warned || time.tick_since(store.last_warning) >= RETRY_INTERVAL {
		message := sqlite_error(store.database)
		fmt.eprintln("hw-odin-analyze: usage recording failed:", message)
		store.last_warning = now
		store.has_warned = true
	}
}

note_drop :: proc(store: ^Store, timestamp_ns: i64) {
	store.dropped_count += 1
	if store.dropped_first_ns == 0 {
		store.dropped_first_ns = timestamp_ns
	}
	store.dropped_last_ns = timestamp_ns
	warn_failure(store)
}

ensure_store_open :: proc(store: ^Store) -> bool {
	if store.database != nil {
		return true
	}
	if time.tick_since(store.last_retry) < RETRY_INTERVAL {
		return false
	}
	store.last_retry = time.tick_now()
	return open_store_database(store)
}

store_record :: proc(store: ^Store, event: Event) -> bool {
	if store == nil || !store.initialized || !ensure_store_open(store) {
		if store != nil && store.initialized {
			note_drop(store, event.received_at_ns)
		}
		return false
	}
	if !sqlite_execute(store.database, "BEGIN IMMEDIATE") {
		close_failed_database(store)
		note_drop(store, event.received_at_ns)
		return false
	}
	had_gap := store.dropped_count > 0
	if !record_gap(store) {
		_ = sqlite_execute(store.database, "ROLLBACK")
		close_failed_database(store)
		note_drop(store, event.received_at_ns)
		return false
	}
	store.sequence += 1
	if !insert_event(store, event) || !sqlite_execute(store.database, "COMMIT") {
		_ = sqlite_execute(store.database, "ROLLBACK")
		close_failed_database(store)
		note_drop(store, event.received_at_ns)
		return false
	}
	if had_gap {
		store.dropped_count = 0
		store.dropped_first_ns = 0
		store.dropped_last_ns = 0
	}
	if store.last_retention_check == {} ||
	   time.tick_since(store.last_retention_check) >= RETENTION_INTERVAL {
		_ = store_prune_payloads(store)
	}
	return true
}

store_prune_payloads :: proc(store: ^Store, now_ns := i64(0)) -> bool {
	if store == nil || store.database == nil {
		return false
	}
	store.last_retention_check = time.tick_now()
	forced := now_ns != 0
	retention_now := now_ns
	if retention_now == 0 {
		retention_now = now_unix_ns()
	}
	last_prune := i64(0)
	statement, prepared := sqlite_prepare(
		store.database,
		"SELECT value_int FROM usage_metadata WHERE key='last_payload_prune_ns'",
	)
	if prepared {
		if sqlite3_step(statement) == SQLITE_ROW {
			last_prune = sqlite3_column_int64(statement, 0)
		}
		_ = sqlite3_finalize(statement)
	}
	if !forced && last_prune > 0 && retention_now - last_prune < i64(RETENTION_INTERVAL) {
		return true
	}
	cutoff := payload_retention_cutoff(retention_now)
	if !sqlite_execute(store.database, "BEGIN IMMEDIATE") {
		return false
	}
	delete_sql := fmt.aprintf(
		`DELETE FROM mcp_event_payloads
		 WHERE event_id IN (
			SELECT id FROM mcp_events WHERE received_at_ns < %d
		 )`,
		cutoff,
		allocator = context.temp_allocator,
	)
	metadata_sql := fmt.aprintf(
		`INSERT INTO usage_metadata (key, value_int)
		 VALUES ('last_payload_prune_ns', %d)
		 ON CONFLICT(key) DO UPDATE SET value_int=excluded.value_int`,
		retention_now,
		allocator = context.temp_allocator,
	)
	if !sqlite_execute(store.database, delete_sql) ||
	   !sqlite_execute(store.database, metadata_sql) ||
	   !sqlite_execute(store.database, "COMMIT") {
		_ = sqlite_execute(store.database, "ROLLBACK")
		return false
	}
	_ = sqlite_execute(store.database, "PRAGMA incremental_vacuum(1024)")
	return true
}
