package usage

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

Tally :: struct {
	key:   string,
	count: int,
}

tally_add :: proc(tallies: ^[dynamic]Tally, key: string, count := 1) {
	for &tally in tallies {
		if tally.key == key {
			tally.count += count
			return
		}
	}
	append(tallies, Tally{key, count})
}

tally_text :: proc(tallies: []Tally) -> string {
	slice.sort_by(tallies, proc(a, b: Tally) -> bool {
		return a.count != b.count ? a.count > b.count : a.key < b.key
	})
	builder := strings.builder_make(context.temp_allocator)
	for tally, index in tallies {
		fmt.sbprintf(&builder, "%s%s %d", index > 0 ? ", " : "", tally.key, tally.count)
	}
	return len(tallies) == 0 ? "none" : strings.to_string(builder)
}

share_text :: proc(part, whole: int) -> string {
	if whole == 0 {
		return "no data"
	}
	return fmt.tprintf("%d%%", (part * 100 + whole / 2) / whole)
}

seconds_text :: proc(sorted_ns: []i64) -> string {
	if len(sorted_ns) == 0 {
		return "no data"
	}
	return fmt.tprintf(
		"median %.1fs, p90 %.1fs",
		f64(percentile(sorted_ns, 50)) / f64(time.Second),
		f64(percentile(sorted_ns, 90)) / f64(time.Second),
	)
}

event_line :: proc(builder: ^strings.Builder, event: Command_Event) {
	stamp := time.unix(0, event.started_at_ns)
	year, month, day := time.date(stamp)
	detail, _ := strings.replace_all(event.detail, "\n", " ", context.temp_allocator)
	fmt.sbprintfln(
		builder, "  %04d-%02d-%02d %s %s %s%s%s | %s", year, int(month), day,
		event.agent, event.command, event.outcome,
		event.reason == "" ? "" : " ", event.reason, detail,
	)
}

effectiveness_report :: proc(days: int, project: string) -> (text: string, ok: bool) {
	events := load_command_events(days, project) or_return
	slice.reverse(events)
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(
		&builder, "hw-odin-analyze effectiveness, last %d days%s%s: %d events",
		days, project == "" ? "" : " in ", project, len(events),
	)
	if len(events) == 0 {
		return strings.to_string(builder), true
	}

	Agent_Use :: struct {
		agent:    string,
		tool:     int,
		direct:   int,
		sessions: [dynamic]string,
	}
	Loop :: struct {
		key:     string,
		started: i64,
		checks:  int,
	}
	agents := make([dynamic]Agent_Use, context.temp_allocator)
	builds := make([dynamic]Tally, context.temp_allocator)
	bypasses := make([dynamic]Tally, context.temp_allocator)
	blocks := make([dynamic]Tally, context.temp_allocator)
	check_results := make([dynamic]Tally, context.temp_allocator)
	edit_results := make([dynamic]Tally, context.temp_allocator)
	other_results := make([dynamic]Tally, context.temp_allocator)
	check_durations := make([dynamic]i64, context.temp_allocator)
	loop_checks := make([dynamic]i64, context.temp_allocator)
	loop_durations := make([dynamic]i64, context.temp_allocator)
	open_loops := make([dynamic]Loop, context.temp_allocator)
	failures := make([dynamic]Command_Event, context.temp_allocator)
	notes := make([dynamic]Command_Event, context.temp_allocator)
	checks, errors, hints, retries, pins, raw_bytes, output_bytes, hunks, redirected, blocked: int
	project_builds: int

	now := now_unix_ns()
	for event, position in events {
		if event.outcome == "unfinished" && now - event.started_at_ns < i64(RUNNING_WINDOW) {
			continue
		}
		use: ^Agent_Use
		for &candidate in agents {
			if candidate.agent == event.agent {
				use = &candidate
			}
		}
		if use == nil {
			append(&agents, Agent_Use{agent = event.agent, sessions = make([dynamic]string, context.temp_allocator)})
			use = &agents[len(agents) - 1]
		}
		if event.session != "" && !slice.contains(use.sessions[:], event.session) {
			append(&use.sessions, event.session)
		}
		switch event.command {
		case "shell":
			if event.reason == "direct-build" {
				project_builds += 1
				continue
			}
			tally_add(&bypasses, event.reason)
			if event.reason == "direct-check" {
				use.direct += 1
			}
			continue
		case "note":
			append(&notes, event)
			continue
		case "guard":
			blocked += 1
			tally_add(&blocks, event.reason)
			for later in events[position + 1:] {
				if later.started_at_ns - event.started_at_ns > i64(AFTER_BLOCK_WINDOW) {
					break
				}
				if later.session == event.session && (later.command == "check" || later.command == "edit") {
					redirected += 1
					break
				}
			}
			continue
		}
		tally_add(&builds, event.build)
		if event.outcome == "error" || event.outcome == "unfinished" || event.reason == "no-diagnostics" {
			append(&failures, event)
		}
		result := event.reason == "" ? event.outcome : fmt.tprintf("%s (%s)", event.outcome, event.reason)
		switch event.command {
		case "check":
			checks += 1
			use.tool += 1
			tally_add(&check_results, result)
			append(&check_durations, event.duration_ns)
			errors += event.errors
			hints += event.hints
			retries += event.retries
			pins += event.pins
			if event.outcome == "failed" {
				raw_bytes += event.raw_bytes
				output_bytes += event.output_bytes
			}
			key := fmt.tprintf("%s|%s", event.session, event.project)
			open := -1
			for loop, index in open_loops {
				if loop.key == key {
					open = index
				}
			}
			if open >= 0 {
				open_loops[open].checks += 1
				if event.outcome == "ok" {
					append(&loop_checks, i64(open_loops[open].checks))
					append(&loop_durations, event.started_at_ns + event.duration_ns - open_loops[open].started)
					unordered_remove(&open_loops, open)
				}
			} else if event.outcome == "failed" {
				append(&open_loops, Loop{key, event.started_at_ns, 1})
			}
		case "edit":
			tally_add(&edit_results, result)
			hunks += event.hunks
		case:
			tally_add(&other_results, fmt.tprintf("%s %s", event.command, result))
		}
	}

	fmt.sbprintln(&builder, "\nAdoption (share of type checks that went through the tool)")
	for use in agents {
		fmt.sbprintfln(
			&builder, "  %s: %s (tool %d, direct %d), %d sessions", use.agent,
			share_text(use.tool, use.tool + use.direct), use.tool, use.direct, len(use.sessions),
		)
	}
	fmt.sbprintfln(&builder, "  shell work outside the tool: %s", tally_text(bypasses[:]))
	fmt.sbprintfln(&builder, "  project builds (expected, not counted above): %d", project_builds)

	slice.sort(check_durations[:])
	slice.sort(loop_checks[:])
	slice.sort(loop_durations[:])
	fmt.sbprintfln(&builder, "\ncheck: %d runs: %s", checks, tally_text(check_results[:]))
	fmt.sbprintfln(&builder, "  time %s", seconds_text(check_durations[:]))
	fmt.sbprintfln(
		&builder, "  errors %d, with hints %d, compiler retries %d, pins advanced %d",
		errors, hints, retries, pins,
	)
	fmt.sbprintfln(
		&builder, "  failed checks: output %.1f KB from %.1f KB of compiler output",
		f64(output_bytes) / 1024, f64(raw_bytes) / 1024,
	)
	if len(loop_checks) > 0 {
		fmt.sbprintfln(
			&builder, "  failed then passed: %d (median %d checks; time %s); %d still failing",
			len(loop_checks), percentile(loop_checks[:], 50), seconds_text(loop_durations[:]),
			len(open_loops),
		)
	} else {
		fmt.sbprintfln(&builder, "  failed then passed: 0; %d still failing", len(open_loops))
	}
	fmt.sbprintfln(&builder, "edit: %d hunks: %s", hunks, tally_text(edit_results[:]))
	fmt.sbprintfln(&builder, "other: %s", tally_text(other_results[:]))
	fmt.sbprintfln(
		&builder, "guard: %d blocked (%s); %d followed by check or edit", blocked,
		tally_text(blocks[:]), redirected,
	)
	fmt.sbprintfln(&builder, "tool builds: %s", tally_text(builds[:]))

	fmt.sbprintfln(&builder, "\nTool failures: %d", len(failures))
	for event in failures[max(0, len(failures) - EVENT_LIST_SHOWN):] {
		event_line(&builder, event)
	}
	fmt.sbprintfln(&builder, "Agent notes: %d", len(notes))
	for event in notes[max(0, len(notes) - EVENT_LIST_SHOWN):] {
		event_line(&builder, event)
	}
	return strings.to_string(builder), true
}
