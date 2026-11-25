package workflow

import "core:encoding/json"
import "core:path/filepath"
import "core:strings"

GUARD_COMMAND_BYTES_MAX :: 1024 * 1024

Guard_Tool_Input :: struct {
	command: string,
}

Guard_Input :: struct {
	tool_name:  string,
	tool_input:      Guard_Tool_Input,
	cwd:             string,
	session_id:      string,
	transcript_path: string,
	agent:           string,
	conversation_id: string `json:"conversationId"`,
	tool_call:       struct {
		args: struct {
			CommandLine: string,
			Cwd:         string,
		},
	} `json:"toolCall"`,
}

Guard_Verdict :: struct {
	block_reason:    string,
	block_kind:      string,
	decision_json:   bool,
	agent:           string,
	session_id:      string,
	transcript_path: string,
	directory:       string,
	observations:    []Observation,
}

Shell_Stage :: struct {
	words:    []string,
	heredocs: []string,
}

Shell_Pipeline :: []Shell_Stage

PIPED_COMPILE_REASON ::
	"Blocked: piping a compiler or build command hides its exit status and cuts errors off. " +
	"Run `hw-odin-analyze check [--root PROJECT] [NAME...]`, which returns the real status and every " +
	"error compactly. For a mode it does not cover, run the command without a pipe, or add `set -o pipefail`."

SCRIPTED_EDIT_REASON ::
	"Blocked: this scripted rewrite of Odin source can silently match nothing. Use " +
	"`hw-odin-analyze edit <<'EOF'` with `@@ FILE`, `<<<<`, old lines, `====`, new lines, `>>>>`; " +
	"each hunk must match exactly once (or `count=N`) and the check runs afterwards. " +
	"A script is allowed when it asserts every match count."

shell_pipelines :: proc(command: string) -> []Shell_Pipeline {
	pipelines := make([dynamic]Shell_Pipeline, context.temp_allocator)
	stages := make([dynamic]Shell_Stage, context.temp_allocator)
	words := make([dynamic]string, context.temp_allocator)
	heredocs := make([dynamic]string, context.temp_allocator)
	pending := make([dynamic]string, context.temp_allocator)
	word := strings.builder_make(context.temp_allocator)
	in_word := false
	index := 0

	end_word :: proc(words: ^[dynamic]string, word: ^strings.Builder, in_word: ^bool) {
		if in_word^ {
			append(words, strings.clone(strings.to_string(word^), context.temp_allocator))
			strings.builder_reset(word)
			in_word^ = false
		}
	}
	end_stage :: proc(stages: ^[dynamic]Shell_Stage, words, heredocs: ^[dynamic]string) {
		if len(words^) > 0 || len(heredocs^) > 0 {
			append(stages, Shell_Stage{words = words[:], heredocs = heredocs[:]})
			words^ = make([dynamic]string, context.temp_allocator)
			heredocs^ = make([dynamic]string, context.temp_allocator)
		}
	}
	end_pipeline :: proc(pipelines: ^[dynamic]Shell_Pipeline, stages: ^[dynamic]Shell_Stage) {
		if len(stages^) > 0 {
			append(pipelines, Shell_Pipeline(stages[:]))
			stages^ = make([dynamic]Shell_Stage, context.temp_allocator)
		}
	}

	for index < len(command) {
		character := command[index]
		next := index + 1 < len(command) ? command[index + 1] : 0
		switch character {
		case '\'', '"':
			in_word = true
			index += 1
			for index < len(command) && command[index] != character {
				if character == '"' && command[index] == '\\' && index + 1 < len(command) {
					index += 1
				}
				strings.write_byte(&word, command[index])
				index += 1
			}
			index += 1
		case '\\':
			if next != '\n' && next != 0 {
				strings.write_byte(&word, next)
				in_word = true
			}
			index += 2
		case '#':
			if in_word {
				strings.write_byte(&word, character)
				index += 1
			} else {
				for index < len(command) && command[index] != '\n' {
					index += 1
				}
			}
		case ' ', '\t':
			end_word(&words, &word, &in_word)
			index += 1
		case '<':
			if next == '<' && !(index + 2 < len(command) && command[index + 2] == '<') {
				end_word(&words, &word, &in_word)
				index += 2
				for index < len(command) && (command[index] == '-' || command[index] == ' ') {
					index += 1
				}
				delimiter := strings.builder_make(context.temp_allocator)
				for index < len(command) && !strings.contains_rune(" \t\n;&|<>)", rune(command[index])) {
					if command[index] != '\'' && command[index] != '"' && command[index] != '\\' {
						strings.write_byte(&delimiter, command[index])
					}
					index += 1
				}
				append(&pending, strings.to_string(delimiter))
			} else {
				end_word(&words, &word, &in_word)
				index += next == '<' ? 3 : 1
			}
		case '\n':
			end_word(&words, &word, &in_word)
			index += 1
			for delimiter in pending {
				start := index
				body_end := len(command)
				for index < len(command) {
					line_end := strings.index_byte(command[index:], '\n')
					line_end = line_end < 0 ? len(command) : index + line_end
					line := strings.trim_space(command[index:line_end])
					line_start := index
					index = min(line_end + 1, len(command))
					if line == delimiter {
						body_end = line_start
						break
					}
				}
				body := command[start:max(start, body_end)]
				if len(words) == 0 && len(heredocs) == 0 && len(stages) > 0 {
					last := &stages[len(stages) - 1]
					bodies := make([dynamic]string, context.temp_allocator)
					append(&bodies, ..last.heredocs)
					append(&bodies, body)
					last.heredocs = bodies[:]
				} else {
					append(&heredocs, body)
				}
			}
			clear(&pending)
			end_stage(&stages, &words, &heredocs)
			end_pipeline(&pipelines, &stages)
		case ';', '(', ')':
			end_word(&words, &word, &in_word)
			end_stage(&stages, &words, &heredocs)
			end_pipeline(&pipelines, &stages)
			index += 1
		case '&':
			redirect := next == '>' || (index > 0 && (command[index - 1] == '>' || command[index - 1] == '<'))
			if redirect {
				strings.write_byte(&word, character)
				in_word = true
				index += 1
			} else {
				end_word(&words, &word, &in_word)
				end_stage(&stages, &words, &heredocs)
				end_pipeline(&pipelines, &stages)
				index += next == '&' ? 2 : 1
			}
		case '|':
			end_word(&words, &word, &in_word)
			end_stage(&stages, &words, &heredocs)
			if next == '|' {
				end_pipeline(&pipelines, &stages)
				index += 2
			} else {
				index += next == '&' ? 2 : 1
			}
		case:
			strings.write_byte(&word, character)
			in_word = true
			index += 1
		}
	}
	end_word(&words, &word, &in_word)
	end_stage(&stages, &words, &heredocs)
	end_pipeline(&pipelines, &stages)
	return pipelines[:]
}

command_words :: proc(words: []string) -> []string {
	start := 0
	for start < len(words) {
		word := words[start]
		equals := strings.index_byte(word, '=')
		if equals > 0 && !strings.contains_rune(word[:equals], '/') {
			start += 1
			continue
		}
		switch word {
		case "time", "nice", "env", "exec", "command", "then", "do", "else", "!", "{":
			start += 1
		case "timeout", "gtimeout":
			start += 2
		case:
			return words[start:]
		}
	}
	return nil
}

compiles :: proc(words: []string, directory: string) -> bool {
	values := command_words(words)
	if len(values) == 0 {
		return false
	}
	program := filepath.base(values[0])
	arguments := values[1:]
	for argument in arguments {
		if argument == "-help" || argument == "--help" {
			return false
		}
	}
	switch program {
	case "hw-odin", "odin":
		if len(arguments) == 0 {
			return false
		}
		switch arguments[0] {
		case "check", "build", "test", "run":
			return true
		}
		return false
	case "hw-odin-analyze":
		for argument in arguments {
			if argument == "check" || argument == "edit" {
				return true
			}
		}
		return false
	case "sh", "bash", "zsh":
		for argument, index in arguments {
			if argument == "-n" {
				return false
			}
			if !strings.has_prefix(argument, "-") {
				return compiles(arguments[index:], directory)
			}
		}
		return false
	case "build.sh", "test.sh":
		return is_odin_project(filepath.dir(absolute(directory, values[0])))
	}
	return false
}

mentions_odin_file :: proc(words: []string) -> bool {
	for word in words {
		if strings.has_suffix(word, ".odin") {
			return true
		}
	}
	return false
}

unguarded_rewrite :: proc(stage: Shell_Stage) -> bool {
	values := command_words(stage.words)
	if len(values) == 0 {
		return false
	}
	program := filepath.base(values[0])
	if program == "sed" || program == "gsed" || program == "perl" {
		in_place := false
		for argument in values[1:] {
			if strings.has_prefix(argument, "-i") || argument == "--in-place" ||
			   (program == "perl" && strings.has_prefix(argument, "-") && strings.contains_rune(argument, 'i')) {
				in_place = true
			}
		}
		return in_place && mentions_odin_file(values[1:])
	}
	if !strings.has_prefix(program, "python") {
		return false
	}
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, ..stage.heredocs)
	append(&parts, ..values[1:])
	script := strings.join(parts[:], "\n", context.temp_allocator)
	if !strings.contains(script, ".odin") {
		return false
	}
	writes := strings.contains(script, "write_text(") || strings.contains(script, ".write(")
	replaces := strings.contains(script, ".replace(") || strings.contains(script, "re.sub(")
	if !writes || !replaces {
		return false
	}
	guards := [?]string{".count(", ".index(", "assert ", "assert(", "raise ", "sys.exit(", " not in "}
	for guard in guards {
		if strings.contains(script, guard) {
			return false
		}
	}
	return true
}

guard_command :: proc(command, working_directory: string) -> string {
	if len(command) > GUARD_COMMAND_BYTES_MAX {
		return ""
	}
	status_preserved := strings.contains(command, "pipefail") ||
		strings.contains(command, "PIPESTATUS") || strings.contains(command, "pipestatus")
	directory := working_directory
	for pipeline in shell_pipelines(command) {
		for stage, index in pipeline {
			values := command_words(stage.words)
			if len(values) == 2 && values[0] == "cd" && !strings.contains_rune(values[1], '$') {
				directory = absolute(directory, values[1])
			}
			if !status_preserved && index + 1 < len(pipeline) && compiles(stage.words, directory) {
				return PIPED_COMPILE_REASON
			}
			if unguarded_rewrite(stage) {
				return SCRIPTED_EDIT_REASON
			}
		}
	}
	return ""
}

guard_hook :: proc(source: string) -> (verdict: Guard_Verdict) {
	input: Guard_Input
	if json.unmarshal_string(source, &input, allocator = context.temp_allocator) != nil {
		return
	}
	command := input.tool_input.command
	verdict.agent = input.agent
	verdict.session_id = input.session_id
	verdict.transcript_path = input.transcript_path
	verdict.directory = input.cwd
	if input.conversation_id != "" {
		verdict.decision_json = true
		verdict.agent = "antigravity"
		verdict.session_id = input.conversation_id
		command = input.tool_call.args.CommandLine
		if input.tool_call.args.Cwd != "" {
			verdict.directory = input.tool_call.args.Cwd
		}
	}
	if command == "" {
		return
	}
	verdict.block_reason = guard_command(command, verdict.directory)
	switch verdict.block_reason {
	case "":
		verdict.observations = observe_command(command, verdict.directory)
	case PIPED_COMPILE_REASON:
		verdict.block_kind = "piped-compiler"
	case SCRIPTED_EDIT_REASON:
		verdict.block_kind = "scripted-rewrite"
	}
	return
}
