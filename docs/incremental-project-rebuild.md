# Incremental project rebuild (planned)

Status: approved by the operator on 2026-09-26, not yet implemented. Consumer:
hw_harness, which indexes the opened project in-process on a worker thread.

## Problem

`context_init` rebuilds everything on every call. For a 2-file project it costs
about 136 ms (release, M-series), almost all of it on toolchain packages that
never change between builds:

| Phase | 2-file project | hw_harness (29 files) |
| --- | --- | --- |
| `context_prepare` (`hw-odin toolchain root` subprocess, config) | 18 ms | 18 ms |
| `scan_and_parse` (~466 base/core/vendor files) | 78 ms | 115 ms |
| Declaration and path indexes (~54k symbols) | 37 ms | 48 ms |
| `resolve_occurrences` | 0.1 ms | 34 ms |

A full context holds about 231 MB, mostly toolchain ASTs and sources.

## Goal

Add `context_rebuild_project(state, root) -> bool`. It keeps a toolchain layer
(everything under `odin_root`) and replaces only the project layer (everything
else). `context_init`, the CLI, the daemon, and the query API keep their
behavior. hw_harness keeps one long-lived context on its index worker and calls
`context_rebuild_project` on each open or refresh. The toolchain root is
resolved once. The trade-off is that the toolchain layer stays resident (about
200 MB) for the IDE session.

## Design

Two layers in the existing arrays:

- **Toolchain layer**: the files under `odin_root` (builtin plus transitively
  imported base/core/vendor packages), with their symbols, imports and builtin
  declaration occurrences. It is a contiguous prefix of `files`, `symbols`,
  `imports` and `occurrences`; `toolchain_files`, `toolchain_symbols`,
  `toolchain_imports` and `toolchain_occurrences` record the prefix lengths.
  Its IDs are stable. It is allocated in the existing base arena and only ever
  grows.
- **Project layer**: files under the project root, configured collections, and
  non-toolchain dependencies, with all their symbols, imports, occurrences and
  documents. It lives after the prefix in the arrays, and its strings, sources
  and ASTs go in a new `project_arena`, reset on every rebuild.

`virtual_arena_allocator(state)` picks the arena by the layer of the file being
parsed (`path_is_within(odin_root, path)`), via a per-parse layer field set in
`parse_file_into_context` / `parse_builtin_file_into_context`. Index map tables
stay in the base arena.

### Common rebuild (no new toolchain packages)

1. Remove the old project entries from the maps. Walk the project symbols in
   descending ID order and pop their IDs from `symbols_by_name`, `_by_path`,
   `_by_package`, `_by_owner_type` and `_by_kind`. Project IDs are always the
   tail of each list; assert the popped value. Delete a key when its list becomes
   empty; such lists live in the project arena. Delete the project keys from
   `files_by_path` and `imports_by_path`, and pop project file IDs from
   `files_by_package`.
2. Truncate the arrays to the toolchain prefix, clear `documents` and the
   occurrence maps, then reset `project_arena`.
3. Reload the config for `root`, parse the project roots, and follow imports.
   Packages already in the toolchain layer are skipped (seed `visited_files` and
   `visited_packages` from the prefix).
4. Append the project entries to the maps. Lists for project-only keys are
   allocated in `project_arena`; project IDs appended to toolchain keys reuse the
   capacity from step 1.
5. Rebuild the occurrence maps from scratch (project occurrences plus the prefix),
   resolve only the occurrences at or after `toolchain_occurrences`, and bump
   `generation`.

### Rebuild that loads new toolchain packages

New toolchain files parsed during step 3 land after project entries and break the
contiguous prefix. In that case, before building any map:

- stable-partition the arrays into toolchain first, then project;
- reassign `File_Record.id` and `Symbol.id`, and remap `occurrence.symbol` for the
  builtin occurrences that moved;
- rebuild the toolchain maps from scratch in the base arena;
- continue at step 4.

This costs about the same as today's full index build, and it happens only when a
project first imports a toolchain package the session hasn't loaded yet.

### Invariants to assert and test

- Every file, symbol and import with index `< toolchain_*` is under `odin_root`,
  and every entry after the prefix is not.
- `symbols[i].id == i` and `files[i].id == i` after every build.
- No map key or value references memory in a reset `project_arena`.
- Rebuilding the same project N times leaves the base-arena size unchanged after
  the first rebuild, which also proves no per-rebuild growth.
- Results match `context_init`: identical declarations, resolved occurrences
  (symbol by name and path), and imports for a fixture. Covered for a change that
  adds an import of a new toolchain package, a change that removes one, and a
  switch to a different project root.

## Expected cost

A rebuild with an unchanged toolchain parses and resolves only project files, plus
map updates proportional to project symbols. That should be a few milliseconds for
small projects. Measure with the benchmark in hw_harness's session notes (a
per-phase `tick_now` harness over hw_editor/examples/hello and hw_harness) before
and after, in an optimized build.

## Consumer change (hw_harness)

- Keep one `analysis.Analysis_Context` owned by the index worker for the session;
  the worker handles one job at a time, as today.
- On each job, call `context_rebuild_project` on that context (or `context_init`
  the first time), then copy the compact snapshot as today. Do not destroy the
  context between jobs.
- Destroy the context at shutdown, after the worker finishes.
- Update ARCHITECTURE.md § Index and verification: toolchain layer resident,
  about 200 MB, traded for per-build speed.
