package workflow

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

EDIT_COUNT_MAX :: 512
EDIT_INPUT_BYTES_MAX :: 8 * 1024 * 1024
MATCH_LINES_SHOWN :: 8

Edit :: struct {
	file:          string,
	old:           string,
	new:           string,
	count:         int,
	line_anchored: bool `json:"-"`,
}

Edit_Input :: struct {
	edits: []Edit,
}

Edited_File :: struct {
	path:      string,
	original:  string,
	content:   string,
	mode:      os.Permissions,
	created:   bool,
	had_final: bool,
	applied:   int,
}

Edit_Report :: struct {
	files:     []Edited_File,
	errors:    []string,
	rejection: string,
}

parse_block_edits :: proc(source: string) -> (edits: []Edit, error: string) {
	Section :: enum {Outside, Old, New}
	list := make([dynamic]Edit, context.temp_allocator)
	old := strings.builder_make(context.temp_allocator)
	new_text := strings.builder_make(context.temp_allocator)
	section := Section.Outside
	file := ""
	count := 1
	remaining := source
	number := 0
	for line in strings.split_lines_iterator(&remaining) {
		number += 1
		switch section {
		case .Outside:
			if strings.has_prefix(line, "@@ ") {
				file = strings.trim_space(line[3:])
				count = 1
				if marker := strings.last_index(file, " count="); marker >= 0 {
					value, parsed := strconv.parse_int(file[marker + len(" count="):], 10)
					if !parsed || value < 1 {
						return nil, fmt.tprintf("line %d: count must be a positive integer", number)
					}
					count = value
					file = strings.trim_space(file[:marker])
				}
			} else if line == "<<<<" {
				if file == "" {
					return nil, fmt.tprintf("line %d: a hunk needs a preceding @@ FILE line", number)
				}
				strings.builder_reset(&old)
				strings.builder_reset(&new_text)
				section = .Old
			} else if strings.trim_space(line) != "" {
				return nil, fmt.tprintf("line %d: expected @@ FILE or <<<<", number)
			}
		case .Old:
			if line == "====" {
				section = .New
			} else {
				strings.write_string(&old, line)
				strings.write_byte(&old, '\n')
			}
		case .New:
			if line == ">>>>" {
				append(&list, Edit{
					file = file,
					old = strings.clone(strings.to_string(old), context.temp_allocator),
					new = strings.clone(strings.to_string(new_text), context.temp_allocator),
					count = count,
					line_anchored = true,
				})
				section = .Outside
			} else {
				strings.write_string(&new_text, line)
				strings.write_byte(&new_text, '\n')
			}
		}
	}
	if section != .Outside {
		return nil, "the last hunk is not closed with >>>>"
	}
	return list[:], ""
}

parse_edits :: proc(source: string) -> (edits: []Edit, error: string) {
	if len(source) > EDIT_INPUT_BYTES_MAX {
		return nil, "the edit input is too large"
	}
	if strings.has_prefix(strings.trim_left_space(source), "{") {
		input: Edit_Input
		if json.unmarshal_string(source, &input, allocator = context.temp_allocator) != nil {
			return nil, "the edit input is not valid JSON"
		}
		edits = input.edits
		for &edit in edits {
			if edit.count == 0 {
				edit.count = 1
			}
		}
	} else {
		edits, error = parse_block_edits(source)
		if error != "" {
			return
		}
	}
	if len(edits) == 0 || len(edits) > EDIT_COUNT_MAX {
		return nil, fmt.tprintf("provide between 1 and %d edits", EDIT_COUNT_MAX)
	}
	for edit, index in edits {
		if edit.file == "" || edit.count < 1 {
			return nil, fmt.tprintf("edit %d needs a file and a positive count", index + 1)
		}
	}
	return edits, ""
}

match_offsets :: proc(content, wanted: string, line_anchored: bool) -> []int {
	assert(len(wanted) > 0)
	offsets := make([dynamic]int, context.temp_allocator)
	start := 0
	for start <= len(content) - len(wanted) {
		found := strings.index(content[start:], wanted)
		if found < 0 {
			break
		}
		offset := start + found
		if line_anchored && offset > 0 && content[offset - 1] != '\n' {
			start = offset + 1
			continue
		}
		append(&offsets, offset)
		start = offset + len(wanted)
	}
	return offsets[:]
}

line_of :: proc(content: string, offset: int) -> int {
	return strings.count(content[:offset], "\n") + 1
}

partial_line_hint :: proc(content, wanted: string) -> string {
	text := strings.trim_suffix(wanted, "\n")
	if text == "" {
		return ""
	}
	offset := strings.index(content, text)
	if offset < 0 {
		return ""
	}
	end := offset + len(text)
	first_start := strings.last_index_byte(content[:offset], '\n') + 1
	last_end := strings.index_byte(content[end:], '\n')
	last_end = last_end < 0 ? len(content) : end + last_end
	cut := -1
	if strings.trim_space(content[first_start:offset]) != "" {
		cut = offset
	} else if strings.trim_space(content[end:last_end]) != "" {
		cut = end
	}
	if cut < 0 {
		return ""
	}
	line_start := strings.last_index_byte(content[:cut], '\n') + 1
	line_end := strings.index_byte(content[cut:], '\n')
	line_end = line_end < 0 ? len(content) : cut + line_end
	return fmt.tprintf(
		"a hunk replaces whole lines, and this one covers only part of line %d; the whole line is:\n%s",
		line_of(content, cut), content[line_start:line_end],
	)
}

miss_hint :: proc(content, wanted: string) -> string {
	content_lines := strings.split_lines(content, context.temp_allocator)
	wanted_lines := strings.split_lines(strings.trim_right(wanted, "\n"), context.temp_allocator)
	if len(wanted_lines) == 0 {
		return "no similar text was found; read the file again"
	}
	found := -1
	matched_lines, matches := 0, 0
	for _, start in content_lines {
		prefix := 0
		for line, index in wanted_lines {
			at := start + index
			if at >= len(content_lines) || strings.trim_space(content_lines[at]) != strings.trim_space(line) {
				break
			}
			prefix += 1
		}
		if prefix > matched_lines {
			found, matched_lines = start, prefix
		}
		if prefix == len(wanted_lines) {
			matches += 1
		}
	}
	if matches == 1 {
		builder := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&builder, "only whitespace differs at line %d; the exact file text is:", found + 1)
		for index in 0 ..< len(wanted_lines) {
			fmt.sbprintf(&builder, "\n%s", content_lines[found + index])
		}
		return strings.to_string(builder)
	}
	if matches > 1 {
		return fmt.tprintf("found %d blocks with matching text after ignoring whitespace", matches)
	}
	if found < 0 || (matched_lines == 1 && strings.trim_space(wanted_lines[0]) == "") {
		return "no similar text was found; read the file again"
	}
	for line, index in wanted_lines {
		at := found + index
		if at >= len(content_lines) {
			return fmt.tprintf("the file ends before line %d\n  expected: %q\n  actual: end of file", at + 1, line)
		}
		if content_lines[at] != line {
			return fmt.tprintf("first difference at line %d\n  expected: %q\n  actual:   %q",
				at + 1, line, content_lines[at])
		}
	}
	return "no similar text was found; read the file again"
}

load_edit_target :: proc(path: string, creating: bool) -> (file: Edited_File, error: string) {
	file.path = path
	info, info_error := os.stat_do_not_follow_links(path, context.temp_allocator)
	if info_error != nil {
		if creating && !os.exists(path) {
			file.created = true
			file.had_final = true
			file.mode = os.Permissions_Read_All + {.Write_User}
			return
		}
		return file, "the file does not exist"
	}
	if info.type != .Regular {
		return file, "the path is not a regular file; edit the link target directly"
	}
	text, read := read_text(path)
	if !read {
		return file, "the file could not be read"
	}
	file.mode = info.mode
	file.original = text
	file.had_final = len(text) == 0 || text[len(text) - 1] == '\n'
	file.content = file.had_final ? text : strings.concatenate({text, "\n"}, context.temp_allocator)
	return
}

plan_edits :: proc(base: string, edits: []Edit) -> Edit_Report {
	files := make([dynamic]Edited_File, context.temp_allocator)
	errors := make([dynamic]string, context.temp_allocator)
	indexes := make(map[string]int, allocator = context.temp_allocator)
	rejection := ""
	reject :: proc(rejection: ^string, reason: string) {
		if rejection^ == "" {
			rejection^ = reason
		}
	}
	for edit, number in edits {
		path := absolute(base, edit.file)
		index, known := indexes[path]
		if !known {
			file, load_error := load_edit_target(path, edit.old == "")
			if load_error != "" {
				reject(&rejection, "bad-target")
				append(&errors, fmt.tprintf("edit %d %s: %s", number + 1, edit.file, load_error))
				continue
			}
			index = len(files)
			indexes[path] = index
			append(&files, file)
		}
		file := &files[index]
		if edit.old == "" {
			if !file.created || file.applied > 0 {
				reject(&rejection, "bad-target")
				append(&errors, fmt.tprintf(
					"edit %d %s: empty old text only creates a new file, and this file exists",
					number + 1, edit.file,
				))
				continue
			}
			file.content = edit.new
			file.applied += 1
			continue
		}
		offsets := match_offsets(file.content, edit.old, edit.line_anchored)
		if len(offsets) != edit.count {
			reason := len(offsets) == 0 ? "no-match" : "count-mismatch"
			detail: string
			if len(offsets) == 0 {
				if edit.line_anchored {
					detail = partial_line_hint(file.content, edit.old)
				}
				if detail != "" {
					reason = "partial-line"
				} else {
					detail = miss_hint(file.content, edit.old)
				}
			} else {
				lines := strings.builder_make(context.temp_allocator)
				for offset, position in offsets {
					if position >= MATCH_LINES_SHOWN {
						break
					}
					fmt.sbprintf(&lines, " %d", line_of(file.content, offset))
				}
				detail = fmt.tprintf("matches start at lines%s", strings.to_string(lines))
			}
			reject(&rejection, reason)
			append(&errors, fmt.tprintf(
				"edit %d %s: expected %d match(es), found %d; %s",
				number + 1, edit.file, edit.count, len(offsets), detail,
			))
			continue
		}
		builder := strings.builder_make(context.temp_allocator)
		copied := 0
		for offset in offsets {
			strings.write_string(&builder, file.content[copied:offset])
			strings.write_string(&builder, edit.new)
			copied = offset + len(edit.old)
		}
		strings.write_string(&builder, file.content[copied:])
		file.content = strings.to_string(builder)
		file.applied += 1
	}
	return {files = files[:], errors = errors[:], rejection = rejection}
}

final_content :: proc(file: Edited_File) -> string {
	if !file.had_final && strings.has_suffix(file.content, "\n") {
		return file.content[:len(file.content) - 1]
	}
	return file.content
}

replace_file :: proc(path, content: string, mode: os.Permissions) -> bool {
	directory := filepath.dir(path)
	temporary, create_error := os.create_temp_file(directory, ".hw-edit-*")
	if create_error != nil {
		return false
	}
	temporary_path := strings.clone(os.name(temporary), context.temp_allocator)
	_, write_error := os.write_string(temporary, content)
	close_error := os.close(temporary)
	if write_error != nil || close_error != nil || os.change_mode(temporary_path, mode) != nil ||
	   os.rename(temporary_path, path) != nil {
		os.remove(temporary_path)
		return false
	}
	return true
}

commit_edits :: proc(report: Edit_Report) -> string {
	assert(len(report.errors) == 0)
	for file in report.files {
		current, found := read_text(file.path)
		if file.created ? os.exists(file.path) : (!found || current != file.original) {
			return fmt.tprintf("%s changed while the edits were planned; nothing was written", file.path)
		}
	}
	for file, index in report.files {
		if file.created {
			os.make_directory_all(filepath.dir(file.path))
		}
		if replace_file(file.path, final_content(file), file.mode) {
			continue
		}
		restored := true
		for previous in report.files[:index] {
			if previous.created {
				restored = os.remove(previous.path) == nil && restored
			} else {
				restored = replace_file(previous.path, previous.original, previous.mode) && restored
			}
		}
		return fmt.tprintf(
			"%s could not be written; %s", file.path,
			restored ? "earlier files were restored" : "restoring earlier files also failed",
		)
	}
	return ""
}
