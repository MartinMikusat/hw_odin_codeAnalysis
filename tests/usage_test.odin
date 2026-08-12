package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "code_analysis:usage"

TEST_SHARED_DIRECTORY_PERMISSIONS :: os.Permissions{
	.Read_User,
	.Write_User,
	.Execute_User,
	.Read_Group,
	.Execute_Group,
	.Read_Other,
	.Execute_Other,
}
TEST_PRIVATE_FILE_PERMISSIONS :: os.Permissions{
	.Read_User,
	.Write_User,
}

Usage_Test_Session :: struct {
	ended: bool,
	protocol_version: string,
	client_name: string,
	client_version: string,
	compiler_release: string,
	compiler_root: string,
	config_digest: string,
}

usage_test_mode :: proc(path: string) -> (mode: os.Permissions, ok: bool) {
	information, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		return {}, false
	}
	defer os.file_info_delete(information, context.temp_allocator)
	return information.mode, true
}

usage_test_sessions :: proc(
	database_path: string,
	allocator := context.allocator,
) -> (sessions: []Usage_Test_Session, ok: bool) {
	database, opened := usage.sqlite_open(database_path, readonly = true)
	if !opened {
		return nil, false
	}
	defer usage.sqlite3_close_v2(database)
	statement, prepared := usage.sqlite_prepare(
		database,
		`SELECT ended_at_ns IS NOT NULL, COALESCE(protocol_version, ''),
		        COALESCE(client_name, ''), COALESCE(client_version, ''),
		        compiler_release, compiler_root, config_digest
		 FROM mcp_sessions ORDER BY id`,
	)
	if !prepared {
		return nil, false
	}
	defer usage.sqlite3_finalize(statement)
	values := make([dynamic]Usage_Test_Session, allocator)
	for usage.sqlite3_step(statement) == usage.SQLITE_ROW {
		append(&values, Usage_Test_Session{
			ended = usage.sqlite3_column_int(statement, 0) != 0,
			protocol_version = usage.sqlite_column_string(statement, 1, allocator),
			client_name = usage.sqlite_column_string(statement, 2, allocator),
			client_version = usage.sqlite_column_string(statement, 3, allocator),
			compiler_release = usage.sqlite_column_string(statement, 4, allocator),
			compiler_root = usage.sqlite_column_string(statement, 5, allocator),
			config_digest = usage.sqlite_column_string(statement, 6, allocator),
		})
	}
	return values[:], true
}

usage_test_database :: proc(t: ^testing.T) -> (
	directory, database_path: string,
	ok: bool,
) {
	directory_error: os.Error
	directory, directory_error = os.make_directory_temp(
		"",
		"hw-odin-usage-*",
		context.allocator,
	)
	testing.expect_value(t, directory_error, nil)
	if directory_error != nil {
		return
	}
	testing.expect_value(
		t,
		os.change_mode(directory, TEST_SHARED_DIRECTORY_PERMISSIONS),
		nil,
	)
	database_path, _ = filepath.join(
		{directory, "usage.sqlite3"},
		context.allocator,
	)
	set_error := os.set_env("HW_ODIN_ANALYZE_USAGE_DB", database_path)
	testing.expect_value(t, set_error, nil)
	resolved_path, resolved := usage.database_path(context.temp_allocator)
	testing.expect(t, resolved)
	testing.expect_value(t, resolved_path, database_path)
	ok = set_error == nil && resolved && resolved_path == database_path
	return
}

usage_test_cleanup :: proc(directory, database_path: string) {
	_ = os.unset_env("HW_ODIN_ANALYZE_USAGE_DB")
	_ = os.remove_all(directory)
	delete(database_path)
	delete(directory)
}

@(test)
usage_store_records_metrics_and_optional_payloads :: proc(t: ^testing.T) {
	directory, database_path, path_ok := usage_test_database(t)
	if directory == "" {
		return
	}
	defer usage_test_cleanup(directory, database_path)
	if !path_ok { return }
	store: usage.Store
	initialized := usage.store_init(
		&store,
		"/workspace/one",
		"0.4.0",
		"dev-test",
		"/compiler",
		"digest",
	)
	testing.expect(t, initialized)
	if !initialized {
		return
	}
	defer usage.store_destroy(&store)
	directory_mode, directory_mode_ok := usage_test_mode(directory)
	testing.expect(t, directory_mode_ok)
	if directory_mode_ok {
		testing.expect_value(t, directory_mode, TEST_SHARED_DIRECTORY_PERMISSIONS)
	}
	database_mode, database_mode_ok := usage_test_mode(database_path)
	testing.expect(t, database_mode_ok)
	if database_mode_ok {
		testing.expect_value(t, database_mode, TEST_PRIVATE_FILE_PERMISSIONS)
	}
	testing.expect(t, usage.store_update_client(&store, "2025-11-25", "test-client", "1.0"))
	request := `{"jsonrpc":"2.0","id":1,"method":"tools/call"}`
	response := `{"jsonrpc":"2.0","id":1,"result":{}}`
	recorded := usage.store_record(
		&store,
		usage.Event {
			event_kind = "request",
			method = "tools/call",
			tool_name = "lookup_symbols",
			outcome = "ok",
			received_at_ns = usage.now_unix_ns(),
			duration_ns = 1200,
			generation = 3,
			batch_size = 2,
			result_count = 2,
			empty_result_count = 1,
			ambiguous_count = 1,
			request_line = transmute([]byte)request,
			response_line = transmute([]byte)response,
		},
	)
	testing.expect(t, recorded)
	database_sidecar_suffixes := [?]string{"-wal", "-shm"}
	for suffix in database_sidecar_suffixes {
		sidecar_path := fmt.aprintf("%s%s", database_path, suffix, allocator = context.temp_allocator)
		if os.exists(sidecar_path) {
			sidecar_mode, sidecar_mode_ok := usage_test_mode(sidecar_path)
			testing.expect(t, sidecar_mode_ok)
			if sidecar_mode_ok {
				testing.expect_value(t, sidecar_mode, TEST_PRIVATE_FILE_PERMISSIONS)
			}
		}
	}
	status_report, status_ok := usage.status(context.temp_allocator)
	testing.expect(t, status_ok)
	if status_ok {
		testing.expect_value(t, status_report.session_count, i64(1))
		testing.expect_value(t, status_report.event_count, i64(1))
		testing.expect_value(t, status_report.payload_count, i64(1))
	}
	summary_report, summary_ok := usage.summary(
		1,
		"/workspace/one",
		context.temp_allocator,
	)
	testing.expect(t, summary_ok)
	if summary_ok {
		testing.expect_value(t, summary_report.total_events, i64(1))
		testing.expect_value(t, summary_report.tool_calls, i64(1))
		testing.expect_value(t, len(summary_report.groups), 1)
		if len(summary_report.groups) == 1 {
			group := summary_report.groups[0]
			testing.expect_value(t, group.tool_name, "lookup_symbols")
			testing.expect_value(t, group.average_duration_ns, i64(1200))
			testing.expect_value(t, group.empty_result_count, i64(1))
			testing.expect_value(t, group.ambiguous_count, i64(1))
		}
	}
	recent_without, recent_without_ok := usage.recent(
		1,
		"/workspace/one",
		"lookup_symbols",
		50,
		false,
		context.temp_allocator,
	)
	testing.expect(t, recent_without_ok)
	if recent_without_ok && len(recent_without.events) == 1 {
		testing.expect_value(t, recent_without.events[0].request_payload, "")
		testing.expect_value(t, len(recent_without.events[0].request_sha256), 64)
		testing.expect_value(t, len(recent_without.events[0].response_sha256), 64)
	}
	recent_with, recent_with_ok := usage.recent(
		1,
		"/workspace/one",
		"lookup_symbols",
		50,
		true,
		context.temp_allocator,
	)
	testing.expect(t, recent_with_ok)
	if recent_with_ok {
		testing.expect_value(t, len(recent_with.events), 1)
		if len(recent_with.events) == 1 {
			testing.expect_value(t, recent_with.events[0].request_payload_encoding, "utf8")
			testing.expect_value(t, recent_with.events[0].request_payload, request)
			testing.expect_value(t, recent_with.events[0].response_payload, response)
		}
	}
	testing.expect(t, usage.store_update_context(
		&store,
		"dev-next",
		"/compiler-next",
		"digest-next",
	))
	sessions, sessions_ok := usage_test_sessions(database_path, context.temp_allocator)
	testing.expect(t, sessions_ok)
	if sessions_ok {
		testing.expect_value(t, len(sessions), 2)
		if len(sessions) == 2 {
			testing.expect(t, sessions[0].ended)
			testing.expect_value(t, sessions[1].protocol_version, "2025-11-25")
			testing.expect_value(t, sessions[1].client_name, "test-client")
			testing.expect_value(t, sessions[1].client_version, "1.0")
			testing.expect_value(t, sessions[1].compiler_release, "dev-next")
			testing.expect_value(t, sessions[1].compiler_root, "/compiler-next")
			testing.expect_value(t, sessions[1].config_digest, "digest-next")
		}
	}
}

@(test)
usage_retention_removes_payloads_but_preserves_metrics :: proc(t: ^testing.T) {
	directory, database_path, path_ok := usage_test_database(t)
	if directory == "" {
		return
	}
	defer usage_test_cleanup(directory, database_path)
	if !path_ok { return }
	store: usage.Store
	initialized := usage.store_init(&store, "/workspace/two", "0.4.0", "test", "/compiler", "digest")
	testing.expect(t, initialized)
	if !initialized {
		return
	}
	defer usage.store_destroy(&store)
	now_ns := usage.now_unix_ns()
	old_ns := now_ns - i64(91) * i64(24 * time.Hour)
	store.last_retention_check = time.tick_now()
	empty_response := `{}`
	expired_request := `{"expired":true}`
	testing.expect(t, usage.store_record(
		&store,
		usage.Event {
			event_kind = "request",
			method = "tools/call",
			tool_name = "audit_primitives",
			outcome = "ok",
			received_at_ns = now_ns,
			request_line = []byte{0xff},
			response_line = transmute([]byte)empty_response,
		},
	))
	testing.expect(t, usage.store_record(
		&store,
		usage.Event {
			event_kind = "request",
			method = "tools/call",
			tool_name = "audit_primitives",
			outcome = "ok",
			received_at_ns = old_ns,
			request_line = transmute([]byte)expired_request,
			response_line = transmute([]byte)empty_response,
		},
	))
	before, before_ok := usage.recent(
		365,
		"/workspace/two",
		"audit_primitives",
		2,
		true,
		context.temp_allocator,
	)
	testing.expect(t, before_ok)
	if before_ok {
		testing.expect_value(t, len(before.events), 2)
	}
	if before_ok && len(before.events) == 2 {
		testing.expect_value(t, before.events[0].request_payload_encoding, "base64")
		testing.expect_value(t, before.events[0].request_payload, "/w==")
		testing.expect_value(t, before.events[1].request_payload_encoding, "")
		testing.expect_value(t, before.events[1].request_payload, "")
	}
	testing.expect(t, usage.store_prune_payloads(&store, now_ns))
	status_report, status_ok := usage.status(context.temp_allocator)
	testing.expect(t, status_ok)
	if status_ok {
		testing.expect_value(t, status_report.event_count, i64(2))
		testing.expect_value(t, status_report.payload_count, i64(1))
	}
	summary_report, summary_ok := usage.summary(365, "/workspace/two", context.temp_allocator)
	testing.expect(t, summary_ok)
	if summary_ok {
		testing.expect_value(t, summary_report.total_events, i64(2))
		testing.expect_value(t, summary_report.payloads_retained, i64(1))
	}
}

@(test)
usage_store_failure_does_not_require_a_database :: proc(t: ^testing.T) {
	directory, database_path, path_ok := usage_test_database(t)
	if directory == "" {
		return
	}
	defer usage_test_cleanup(directory, database_path)
	if !path_ok { return }
	testing.expect_value(t, os.set_env("HW_ODIN_ANALYZE_USAGE_DB", directory), nil)
	store: usage.Store
	testing.expect(t, !usage.store_init(
		&store,
		"/workspace/failure",
		"0.4.0",
		"test",
		"/compiler",
		"digest",
	))
	defer usage.store_destroy(&store)
	testing.expect(t, !usage.store_update_client(
		&store,
		"2025-11-25",
		"recovery-client",
		"2.0",
	))
	empty_request := `{}`
	testing.expect(t, !usage.store_record(
		&store,
		usage.Event {
			event_kind = "request",
			outcome = "ok",
			received_at_ns = usage.now_unix_ns(),
			request_line = transmute([]byte)empty_request,
		},
	))
	delete(store.path)
	store.path = strings.clone(database_path)
	testing.expect_value(t, os.set_env("HW_ODIN_ANALYZE_USAGE_DB", database_path), nil)
	store.last_retry = {}
	testing.expect(t, usage.store_record(
		&store,
		usage.Event {
			event_kind = "request",
			method = "ping",
			outcome = "ok",
			received_at_ns = usage.now_unix_ns(),
			request_line = transmute([]byte)empty_request,
		},
	))
	status_report, status_ok := usage.status(context.temp_allocator)
	testing.expect(t, status_ok)
	if status_ok {
		testing.expect_value(t, status_report.event_count, i64(2))
	}
	sessions, sessions_ok := usage_test_sessions(database_path, context.temp_allocator)
	testing.expect(t, sessions_ok)
	if sessions_ok {
		testing.expect_value(t, len(sessions), 1)
		if len(sessions) == 1 {
			testing.expect_value(t, sessions[0].protocol_version, "2025-11-25")
			testing.expect_value(t, sessions[0].client_name, "recovery-client")
			testing.expect_value(t, sessions[0].client_version, "2.0")
		}
	}
	recent_report, recent_ok := usage.recent(
		1,
		"/workspace/failure",
		"",
		10,
		false,
		context.temp_allocator,
	)
	testing.expect(t, recent_ok)
	if recent_ok {
		testing.expect_value(t, len(recent_report.events), 2)
		if len(recent_report.events) == 2 {
			testing.expect_value(t, recent_report.events[1].event_kind, "logger_gap")
			testing.expect_value(t, recent_report.events[1].outcome, "logger_gap")
		}
	}
}
