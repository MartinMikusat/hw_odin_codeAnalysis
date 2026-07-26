package analysis

import "core:os"
import "core:path/filepath"
import "core:strings"

query_path :: proc(
	state: ^Analysis_Context,
	path: string,
	allocator := context.allocator,
) -> (relative: string, absolute: string, ok: bool) {
	absolute = path
	if !filepath.is_abs(path) {
		absolute, _ = filepath.join({state.root, path}, allocator)
	} else {
		absolute = strings.clone(path, allocator)
	}
	resolved, resolve_error := os.get_absolute_path(absolute, allocator)
	if resolve_error == nil {
		delete(absolute, allocator)
		absolute = resolved
	}
	relative = relative_path(state.root, absolute, allocator)
	ok = true
	return
}
