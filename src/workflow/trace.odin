package workflow

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

TRACE_BYTES_MAX :: 1024 * 1024 * 1024
TRACE_DEPTH_MAX :: 512
TRACE_MAGIC :: 0x0BADF00D
TRACE_VERSION :: 3
TRACE_STREAM_HEADER_BYTES :: 32
TRACE_BUFFER_HEADER_BYTES :: 20
TRACE_FRAME_NAME :: "frame"
TRACE_ALLOCATION_NAME :: "frame allocations"

Trace_Event :: enum u8 {
	Begin        = 3,
	End          = 4,
	Instant      = 5,
	Pad_Skip     = 7,
	Name_Process = 8,
	Name_Thread  = 9,
}

Trace_Open :: struct {
	name:  string,
	start: f64,
	child: f64,
}

Trace_Scope :: struct {
	name:    string,
	count:   int,
	total:   f64,
	self:    f64,
	longest: f64,
}

Trace_State :: struct {
	stacks:      map[u32][dynamic]Trace_Open,
	scopes:      map[string]Trace_Scope,
	frames:      [dynamic]f64,
	allocations: [dynamic]int,
	bytes:       [dynamic]int,
	current:     map[string]f64,
	worst:       map[string]f64,
	worst_frame: f64,
	frame_depth: int,
	frame_tid:   u32,
	unbalanced:  int,
	truncated:   bool,
}

allocation_value :: proc(arguments, key: string) -> int {
	remaining := arguments
	for field in strings.split_iterator(&remaining, " ") {
		if strings.has_prefix(field, key) {
			value, _ := strconv.parse_int(field[len(key):], 10)
			return value
		}
	}
	return 0
}

trace_begin :: proc(state: ^Trace_State, tid: u32, name, arguments: string, time: f64) {
	if name == TRACE_ALLOCATION_NAME {
		append(&state.allocations, allocation_value(arguments, "count="))
		append(&state.bytes, allocation_value(arguments, "bytes="))
	}
	stack := state.stacks[tid]
	if len(stack) >= TRACE_DEPTH_MAX {
		state.unbalanced += 1
		return
	}
	if name == TRACE_FRAME_NAME && state.frame_depth == 0 {
		state.frame_tid = tid
		state.frame_depth = len(stack) + 1
		clear(&state.current)
	}
	append(&stack, Trace_Open{name = name, start = time})
	state.stacks[tid] = stack
}

trace_end :: proc(state: ^Trace_State, tid: u32, time: f64) {
	stack := state.stacks[tid]
	if len(stack) == 0 {
		state.unbalanced += 1
		return
	}
	open := pop(&stack)
	state.stacks[tid] = stack
	duration := time - open.start
	self := duration - open.child
	if len(stack) > 0 {
		stack[len(stack) - 1].child += duration
	}
	if open.name == TRACE_ALLOCATION_NAME {
		return
	}
	scope := state.scopes[open.name]
	scope.name = open.name
	scope.count += 1
	scope.total += duration
	scope.self += self
	scope.longest = max(scope.longest, duration)
	state.scopes[open.name] = scope
	if state.frame_depth > 0 && tid == state.frame_tid && len(stack) + 1 >= state.frame_depth {
		state.current[open.name] += self
		if len(stack) + 1 == state.frame_depth {
			append(&state.frames, duration)
			if duration > state.worst_frame {
				state.worst_frame = duration
				clear(&state.worst)
				for name, value in state.current {
					state.worst[name] = value
				}
			}
			state.frame_depth = 0
		}
	}
}

parse_trace :: proc(data: []u8) -> (state: Trace_State, ok: bool) {
	if len(data) < TRACE_STREAM_HEADER_BYTES {
		return
	}
	magic := endian.unchecked_get_u64le(data[0:8])
	version := endian.unchecked_get_u64le(data[8:16])
	scale := transmute(f64)endian.unchecked_get_u64le(data[16:24])
	if magic != TRACE_MAGIC || version != TRACE_VERSION || !(scale > 0) {
		return
	}
	offset := TRACE_STREAM_HEADER_BYTES
	for offset < len(data) {
		if offset + TRACE_BUFFER_HEADER_BYTES > len(data) {
			state.truncated = true
			break
		}
		size := int(endian.unchecked_get_u32le(data[offset:]))
		tid := endian.unchecked_get_u32le(data[offset + 4:])
		offset += TRACE_BUFFER_HEADER_BYTES
		if size < 0 || size > len(data) - offset {
			state.truncated = true
			break
		}
		events := data[offset:offset + size]
		offset += size
		position := 0
		for position < len(events) {
			rest := events[position:]
			length := 0
			#partial switch Trace_Event(rest[0]) {
			case .Begin:
				if len(rest) >= 11 {
					name_length := int(rest[9])
					argument_length := int(rest[10])
					length = 11 + name_length + argument_length
					if length <= len(rest) {
						time := f64(endian.unchecked_get_u64le(rest[1:])) * scale
						name := string(rest[11:11 + name_length])
						arguments := string(rest[11 + name_length:length])
						trace_begin(&state, tid, name, arguments, time)
					}
				}
			case .End:
				length = 9
				if length <= len(rest) {
					trace_end(&state, tid, f64(endian.unchecked_get_u64le(rest[1:])) * scale)
				}
			case .Instant:
				if len(rest) >= 12 {
					length = 12 + int(rest[10]) + int(rest[11])
				}
			case .Pad_Skip:
				if len(rest) >= 5 {
					length = 5 + int(endian.unchecked_get_u32le(rest[1:]))
				}
			case .Name_Process, .Name_Thread:
				if len(rest) >= 2 {
					length = 2 + int(rest[1])
				}
			}
			if length <= 0 || length > len(rest) {
				state.truncated = true
				break
			}
			position += length
		}
	}
	return state, true
}

percentile :: proc(sorted: []f64, fraction: f64) -> f64 {
	assert(len(sorted) > 0)
	index := int(fraction * f64(len(sorted) - 1) + 0.5)
	return sorted[clamp(index, 0, len(sorted) - 1)]
}

trace_report :: proc(path: string, top: int) -> (text: string, ok: bool) {
	info, info_error := os.stat(path, context.temp_allocator)
	if info_error != nil || info.size > TRACE_BYTES_MAX {
		return "perf trace: the file is missing or larger than 1 GiB", false
	}
	data, read_error := os.read_entire_file_from_path(path, context.allocator)
	if read_error != nil {
		return "perf trace: the file could not be read", false
	}
	defer delete(data)
	state, parsed := parse_trace(data)
	if !parsed {
		return "perf trace: this is not a spall version 3 trace", false
	}
	limit := top > 0 ? top : PROFILE_TOP_DEFAULT
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(
		&builder, "trace: %s | %d scope names, %d frames", filepath.base(path),
		len(state.scopes), len(state.frames),
	)
	if state.truncated {
		fmt.sbprintln(&builder, "the trace ends inside a record; the recorder probably did not stop cleanly")
	}
	if state.unbalanced > 0 {
		fmt.sbprintfln(&builder, "%d unbalanced scope events were ignored", state.unbalanced)
	}
	if len(state.frames) > 0 {
		sorted := slice.clone(state.frames[:], context.temp_allocator)
		slice.sort(sorted)
		over_60, over_120 := 0, 0
		for duration in sorted {
			if duration > 1e9 / 60 {over_60 += 1}
			if duration > 1e9 / 120 {over_120 += 1}
		}
		fmt.sbprintfln(
			&builder,
			"frame time: p50 %.3f ms | p99 %.3f ms | max %.3f ms | over 8.33 ms: %d | over 16.67 ms: %d",
			percentile(sorted, 0.5) / 1e6, percentile(sorted, 0.99) / 1e6,
			sorted[len(sorted) - 1] / 1e6, over_120, over_60,
		)
	}
	if len(state.allocations) > 0 {
		total, peak, allocating, bytes := 0, 0, 0, 0
		for count, index in state.allocations {
			total += count
			peak = max(peak, count)
			bytes += state.bytes[index]
			if count > 0 {allocating += 1}
		}
		frames := len(state.allocations)
		fmt.sbprintfln(
			&builder,
			"allocations: mean %.1f per frame, max %d, %d of %d frames allocate, mean %.0f bytes per frame",
			f64(total) / f64(frames), peak, allocating, frames, f64(bytes) / f64(frames),
		)
	}
	scopes := make([dynamic]Trace_Scope, context.temp_allocator)
	for _, scope in state.scopes {
		append(&scopes, scope)
	}
	slice.sort_by(scopes[:], proc(a, b: Trace_Scope) -> bool {
		return a.self > b.self || (a.self == b.self && a.name < b.name)
	})
	fmt.sbprintln(&builder, "scopes by self time (self ms, total ms, count, longest ms):")
	for scope, index in scopes {
		if index >= limit {
			break
		}
		fmt.sbprintfln(
			&builder, "  %9.2f %9.2f %8d %9.3f  %s",
			scope.self / 1e6, scope.total / 1e6, scope.count, scope.longest / 1e6, scope.name,
		)
	}
	if len(state.worst) > 0 {
		weights := make(map[string]i64, allocator = context.temp_allocator)
		for name, value in state.worst {
			weights[name] = i64(value)
		}
		write_costs(
			&builder, "slowest frame, self time by scope", costliest(weights),
			max(i64(state.worst_frame), 1), limit,
		)
	}
	return strings.to_string(builder), true
}
