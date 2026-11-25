package workflow

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

OUTPUT_BYTES_MAX :: 32 * 1024 * 1024

Run_Result :: struct {
	output:    string,
	exit_code: int,
	started:   bool,
	timed_out: bool,
	duration:  time.Duration,
}

run :: proc(command: []string, working_dir := "", timeout := 10 * time.Minute) -> Run_Result {
	assert(len(command) > 0)
	assert(timeout > 0)
	result := Run_Result{exit_code = -1}
	file, file_error := os.create_temp_file("", "hw-odin-run-*")
	if file_error != nil {
		result.output = "could not create the output file"
		return result
	}
	path := strings.clone(os.name(file), context.temp_allocator)
	defer {
		os.close(file)
		os.remove(path)
	}
	started_at := time.tick_now()
	arguments := slice.clone(command, context.temp_allocator)
	relative := strings.contains_rune(command[0], '/') && !filepath.is_abs(command[0])
	if working_dir != "" && relative {
		arguments[0] = join(working_dir, command[0])
	}
	process, start_error := os.process_start({
		command = arguments,
		working_dir = working_dir,
		stdout = file,
		stderr = file,
	})
	if start_error != nil {
		result.output = strings.concatenate({"could not start ", command[0]}, context.temp_allocator)
		return result
	}
	result.started = true
	state, wait_error := os.process_wait(process, timeout)
	if wait_error != nil || !state.exited {
		result.timed_out = true
		_ = os.process_kill(process)
		state, _ = os.process_wait(process)
	}
	result.duration = time.tick_since(started_at)
	if !result.timed_out {
		result.exit_code = state.exit_code
		if !state.success && result.exit_code == 0 {
			result.exit_code = -1
		}
	}
	info, info_error := os.stat(path, context.temp_allocator)
	if info_error == nil && info.size > OUTPUT_BYTES_MAX {
		result.output = "output exceeded the capture limit"
		return result
	}
	data, read_error := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_error == nil {
		result.output = string(data)
	}
	return result
}

succeeded :: proc(result: Run_Result) -> bool {
	return result.started && !result.timed_out && result.exit_code == 0
}
