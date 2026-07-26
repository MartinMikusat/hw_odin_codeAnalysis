package watcher

import "core:c"
import "core:strings"
import "core:sync"

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import CoreServices "system:CoreServices.framework"
foreign import System "system:System"

FSEvent_Stream :: distinct rawptr
CF_Type         :: distinct rawptr
CF_String       :: distinct rawptr
CF_Array        :: distinct rawptr
Dispatch_Queue  :: distinct rawptr

FSEvent_Stream_Context :: struct {
	version:          c.long,
	info:             rawptr,
	retain:           rawptr,
	release:          rawptr,
	copy_description: rawptr,
}

FSEvent_Callback :: proc "c" (
	stream: FSEvent_Stream,
	info: rawptr,
	event_count: c.size_t,
	event_paths: rawptr,
	event_flags: [^]u32,
	event_ids: [^]u64,
)

foreign CoreFoundation {
	CFStringCreateWithCString :: proc(
		allocator: rawptr,
		value: cstring,
		encoding: u32,
	) -> CF_String ---
	CFArrayCreate :: proc(
		allocator: rawptr,
		values: [^]CF_Type,
		value_count: c.long,
		callbacks: rawptr,
	) -> CF_Array ---
	CFRelease :: proc(value: CF_Type) ---
}

foreign CoreServices {
	FSEventStreamCreate :: proc(
		allocator: rawptr,
		callback: FSEvent_Callback,
		callback_context: ^FSEvent_Stream_Context,
		paths: CF_Array,
		since_when: u64,
		latency: f64,
		flags: u32,
	) -> FSEvent_Stream ---
	FSEventStreamSetDispatchQueue :: proc(
		stream: FSEvent_Stream,
		queue: Dispatch_Queue,
	) ---
	FSEventStreamStart :: proc(stream: FSEvent_Stream) -> bool ---
	FSEventStreamStop :: proc(stream: FSEvent_Stream) ---
	FSEventStreamInvalidate :: proc(stream: FSEvent_Stream) ---
	FSEventStreamRelease :: proc(stream: FSEvent_Stream) ---
}

foreign System {
	dispatch_get_global_queue :: proc(
		identifier: c.long,
		flags: c.ulong,
	) -> Dispatch_Queue ---
}

UTF8_ENCODING                    :: u32(0x08000100)
EVENT_ID_SINCE_NOW               :: u64(0xffffffffffffffff)
CREATE_FLAG_NO_DEFER             :: u32(0x00000002)
CREATE_FLAG_WATCH_ROOT           :: u32(0x00000004)
CREATE_FLAG_FILE_EVENTS          :: u32(0x00000010)
DISPATCH_QUEUE_PRIORITY_DEFAULT  :: c.long(0)

Watcher :: struct {
	stream: FSEvent_Stream,
	dirty:  u32,
}

event_callback :: proc "c" (
	stream: FSEvent_Stream,
	info: rawptr,
	event_count: c.size_t,
	event_paths: rawptr,
	event_flags: [^]u32,
	event_ids: [^]u64,
) {
	watcher := (^Watcher)(info)
	if watcher != nil && event_count > 0 {
		sync.atomic_store(&watcher.dirty, 1)
	}
}

start :: proc(watcher: ^Watcher, paths: []string) -> bool {
	if watcher == nil || len(paths) == 0 {
		return false
	}

	cf_strings := make([]CF_String, len(paths), context.temp_allocator)
	cf_values := make([]CF_Type, len(paths), context.temp_allocator)
	for path, index in paths {
		path_c := strings.clone_to_cstring(path, context.temp_allocator)
		cf_strings[index] = CFStringCreateWithCString(nil, path_c, UTF8_ENCODING)
		if cf_strings[index] == nil {
			for previous in cf_strings[:index] {
				CFRelease(CF_Type(previous))
			}
			return false
		}
		cf_values[index] = CF_Type(cf_strings[index])
	}
	defer for value in cf_strings {
		CFRelease(CF_Type(value))
	}

	cf_paths := CFArrayCreate(nil, raw_data(cf_values), c.long(len(cf_values)), nil)
	if cf_paths == nil {
		return false
	}
	defer CFRelease(CF_Type(cf_paths))

	stream_context := FSEvent_Stream_Context{info = watcher}
	watcher.stream = FSEventStreamCreate(
		nil,
		event_callback,
		&stream_context,
		cf_paths,
		EVENT_ID_SINCE_NOW,
		0.05,
		CREATE_FLAG_NO_DEFER | CREATE_FLAG_WATCH_ROOT | CREATE_FLAG_FILE_EVENTS,
	)
	if watcher.stream == nil {
		return false
	}

	queue := dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
	FSEventStreamSetDispatchQueue(watcher.stream, queue)
	if !FSEventStreamStart(watcher.stream) {
		FSEventStreamInvalidate(watcher.stream)
		FSEventStreamRelease(watcher.stream)
		watcher.stream = nil
		return false
	}
	return true
}

stop :: proc(watcher: ^Watcher) {
	if watcher == nil || watcher.stream == nil {
		return
	}
	FSEventStreamStop(watcher.stream)
	FSEventStreamInvalidate(watcher.stream)
	FSEventStreamRelease(watcher.stream)
	watcher.stream = nil
}

consume_dirty :: proc(watcher: ^Watcher) -> bool {
	if watcher == nil {
		return false
	}
	return sync.atomic_exchange(&watcher.dirty, 0) != 0
}
