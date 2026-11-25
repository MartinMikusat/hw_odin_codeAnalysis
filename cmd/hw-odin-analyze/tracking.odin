package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "code_analysis:usage"
import "code_analysis:workflow"

BUILD :: #config(HW_BUILD, "unknown")

Tracked_Command :: struct {
	active:        bool,
	daemon_failed: bool,
	row:           i64,
	started:       time.Tick,
	event:         usage.Command_Event,
}

tracked: Tracked_Command

detect_agent :: proc() -> (agent, session: string) {
	markers := [?]struct{agent, presence, session: string}{
		{"claude", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID"},
		{"codex", "CODEX_THREAD_ID", "CODEX_THREAD_ID"},
		{"opencode", "OPENCODE", "OPENCODE_SESSION_ID"},
		{"pi", "PI_CODING_AGENT", "PI_SESSION_ID"},
	}
	for marker in markers {
		if _, found := os.lookup_env(marker.presence, context.temp_allocator); found {
			session, _ = os.lookup_env(marker.session, context.temp_allocator)
			return marker.agent, session
		}
	}
	return "other", ""
}

new_event :: proc(command, project: string) -> usage.Command_Event {
	agent, session := detect_agent()
	return {
		started_at_ns = usage.now_unix_ns(),
		build = BUILD,
		agent = agent,
		session = session,
		project = project,
		command = command,
	}
}

track_start :: proc(command, project: string, via := "") {
	assert(!tracked.active)
	tracked = {active = true, started = time.tick_now(), event = new_event(command, project)}
	tracked.event.via = via
	tracked.event.outcome = "unfinished"
	row, recorded := usage.record_command_event(tracked.event)
	if !recorded {
		fmt.eprintln("hw-odin-analyze: this run could not be recorded in the usage database")
	}
	tracked.row = row
	tracked.event.outcome = ""
}

track_finish :: proc() {
	if !tracked.active {
		return
	}
	tracked.active = false
	if tracked.daemon_failed && tracked.event.command != "check" {
		tracked.event.outcome, tracked.event.reason = "error", "daemon-unavailable"
	}
	if tracked.event.outcome == "" {
		tracked.event.outcome = "ok"
	}
	tracked.event.duration_ns = i64(time.tick_since(tracked.started))
	if tracked.row != 0 {
		_, _ = usage.record_command_event(tracked.event, tracked.row)
	}
}

track_daemon_failure :: proc() {
	if tracked.active {
		tracked.daemon_failed = true
	}
}

track_failure :: proc(message: string) {
	if !tracked.active {
		return
	}
	if tracked.event.outcome == "" {
		tracked.event.outcome = "error"
	}
	if tracked.event.detail == "" {
		tracked.event.detail = message
	}
	track_finish()
}

track_check_report :: proc(report: workflow.Check_Report, output: string) {
	event := &tracked.event
	event.output_bytes = len(output)
	if report.error != "" {
		event.outcome, event.reason, event.detail = "error", "setup", report.error
		return
	}
	timed_out, crashed, unstarted := false, false, false
	last_output := ""
	for step in report.steps {
		for diagnostic in step.output.diagnostics {
			if diagnostic.warning {
				event.warnings += 1
				continue
			}
			event.errors += 1
			if diagnostic.hint != "" {
				event.hints += 1
			}
		}
		event.raw_bytes += len(step.result.output)
		if step.retried {
			event.retries += 1
		}
		if !workflow.succeeded(step.result) {
			timed_out = timed_out || step.result.timed_out
			unstarted = unstarted || !step.result.started
			crashed = crashed || workflow.compiler_crashed(step.result.output)
			last_output = strings.trim_space(step.result.output)
		}
	}
	if !report.reverted {
		for result in report.pins.results {
			if result.state == .Advanced {
				event.pins += 1
			}
		}
	}
	if report.passed {
		return
	}
	event.outcome = "failed"
	switch {
	case timed_out:
		event.outcome, event.reason = "error", "timeout"
	case unstarted:
		event.outcome, event.reason = "error", "not-started"
	case crashed:
		event.outcome, event.reason = "error", "compiler-crash"
	case event.errors > 0:
		event.reason = "compile-errors"
	case:
		event.reason = "no-diagnostics"
		if newline := strings.last_index_byte(last_output, '\n'); newline >= 0 {
			last_output = last_output[newline + 1:]
		}
		event.detail = last_output
	}
}

run_note :: proc(root: string, explicit: bool, arguments: []string) {
	text := strings.trim_space(strings.join(arguments, " ", context.temp_allocator))
	if text == "" {
		fail("usage: note TEXT, stating what the tool did not handle")
	}
	event := new_event("note", project_root(root, explicit))
	event.outcome, event.detail = "ok", text
	if _, recorded := usage.record_command_event(event); !recorded {
		fail("the note could not be recorded")
	}
	fmt.println("note recorded")
}

record_shell_event :: proc(verdict: workflow.Guard_Verdict, command, outcome, reason, detail, directory: string) {
	event := new_event(command, workflow.find_project_root(directory))
	if verdict.agent != "" {
		event.agent = verdict.agent
	} else if strings.contains(verdict.transcript_path, "/.claude/") {
		event.agent = "claude"
	} else if strings.contains(verdict.transcript_path, "/.codex/") {
		event.agent = "codex"
	}
	if verdict.session_id != "" {
		event.session = verdict.session_id
	}
	event.outcome, event.reason, event.detail = outcome, reason, detail
	_, _ = usage.record_command_event(event)
}
