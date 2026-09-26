# Odin Code Analysis

An agent-first Odin code-analysis engine with a persistent semantic daemon.

## AI-assisted development disclosure

Models used:

- **GPT-5.6-Sol**

The project analyzes saved Odin source files for terminal agents and exposes capability auditing through both its CLI and an MCP stdio server. It does not implement an editor language server.

## Status

The implementation targets macOS on Apple Silicon and the active monthly compiler managed by `hw-odin`.

See [`TODO.md`](TODO.md) for the completed analysis-engine roadmap and explicitly deferred scope.

## Build

```sh
./build.sh
```

Install the verified binary in `~/.local/bin`:

```sh
./install.sh
```

## Test

```sh
./test.sh
```

## Commands

Run `build/hw-odin-analyze help` for the complete command list.

Analysis commands emit JSON and do not change source files. Source positions use one-based lines and UTF-8 byte columns.

The `outline`, `search`, and `package-api` commands accept `--tsv`. The flag
replaces the JSON array with one row per symbol in a tab-separated
`line`, `kind`, `name`, `detail` form. Kind labels are short (`proc`,
`struct`, `enum`, `const`, `var`, ...), details collapse to one line, and
tabs inside values become spaces. The flag targets agents that read
outlines as text; every other command keeps its JSON output.

The executable starts one daemon for each analysis root. The client and daemon
exchange length-prefixed JSON through a Unix-domain socket. The daemon exits
after 15 minutes without a request. It closes incomplete requests after one
second.

FSEvents marks the index dirty after a saved file changes. The daemon flushes
pending events and rebuilds the index before it executes the next request.

### Examples

```sh
hw-odin-analyze --root /path/to/project outline src/main.odin
hw-odin-analyze --root /path/to/project definition src/main.odin 42 9
hw-odin-analyze --root /path/to/project references src/main.odin 42 9
hw-odin-analyze --root /path/to/project rename src/main.odin 42 9 new_name
hw-odin-analyze --root /path/to/project diagnostics --workspace
hw-odin-analyze --root /path/to/project status
hw-odin-analyze --root /path/to/project stop
```

Audit every implementation primitive in one request by sending a JSON object on stdin:

```sh
printf '%s\n' '{
  "target_project": "hw_calendar",
  "primitives": [
    {
      "id": "weekday",
      "need": "calculate a weekday from a civil date",
      "search_terms": ["datetime.day_of_week", "day_of_week"]
    }
  ]
}' | hw-odin-analyze --root /Users/martin/projects/main capability-audit
```

The MCP server retains indexes for the active compiler's complete `base`, `core`, and `vendor` trees plus every non-excluded workspace source and documentation file. An exact case-normalized symbol or qualified-name match returns `available`; token overlap returns `candidate`; no indexed match returns `not_found`. A `not_found` result is bounded search evidence.

Start the newline-delimited JSON-RPC MCP transport with:

```sh
hw-odin-analyze --root /Users/martin/projects/main mcp
```

The server negotiates MCP protocol `2025-11-25`. It publishes batched tools for capability audits, symbol lookup and inspection, definitions and references, call graphs, outlines, package APIs, imports, diagnostics, impact analysis, and checked rename plans.

MCP results are optimized for agents. Discovery tools return compact symbol identities or ranked source locators. Symbol IDs are zero-based, so `0` is valid, and an agent must pass the selected ID with its returned generation to `inspect_symbol`. Alternatively, the agent can read the cited source under the returned workspace or compiler root. Successful calls carry one complete `structuredContent` value plus a short text summary; they do not duplicate the JSON as text. Every result retains its generation, configuration digest, source roots, and truncation state. The CLI continues to return the complete analysis records.

`rename` returns a checked edit plan. It does not write source files.

### Local MCP usage data

The MCP server records every input line, emitted response line, and derived event metric in `~/Library/Application Support/hw_odin_codeAnalysis/usage.sqlite3`. Recording is always active for MCP traffic, but a database failure does not change or delay a tool response beyond the bounded SQLite write attempt. The recorder retries after one minute, emits a throttled stderr diagnostic, and writes a synthetic gap event after recovery.

Request and response payloads remain local. Reports stop exposing a payload when its event is older than 90 days, and MCP startup or daily maintenance then removes the expired row. Session and event metrics remain in SQLite so reports can compare tool frequency, outcomes, latency, batch sizes, result counts, empty results, capability misses, ambiguous or unresolved resolutions, truncation, and byte volume over time. No data is uploaded.

Read aggregate data without returning stored payloads:

```sh
hw-odin-analyze usage status
hw-odin-analyze usage summary --days 30
hw-odin-analyze --root /path/to/project usage recent --days 7 --tool audit_primitives --limit 50
```

`usage recent --include-payloads` returns valid UTF-8 as text and returns other bytes as base64. `HW_ODIN_ANALYZE_USAGE_DB` overrides the database path for tests and development runs. The recorder preserves an existing override directory's permissions and restricts the database, WAL, and shared-memory files to the current user.

### Configuration

Place `code-analysis.json` in the analysis root. The file can set the Odin
command, checker arguments, collection roots, and excluded paths. See
[`schema/code-analysis.schema.json`](schema/code-analysis.schema.json).

The running daemon reloads this file before it rebuilds the index. It publishes
the new configuration and watcher roots only after both are ready. An invalid
configuration rejects the request and keeps the previous index active.
The `status` result includes a digest of the effective configuration.

### Current analysis boundary

Embedded callers may pass `Scan_Limits` and a `Scan_Error` output pointer to
`analysis.context_init`. Entry limits cover recursive and imported-package scans;
project-file limits apply after exclusions and host-target selection. Per-file
limits cover non-toolchain sources, while the total-byte limit includes toolchain
reads. Callers that do not need documentation can set `skip_documents`.
Zero limits preserve the standalone analyzer's scope. Rebuilds retain the limits,
and directory or source-read failures reject the candidate. Configuration files
are limited to 64 KB.

The engine parses saved files with the Odin compiler AST packages. It resolves
package declarations, local declarations, imported package selectors, using
imports, compiler built-ins, typed struct fields, references, and direct calls.

The index follows relative imports, configured collections, and the pinned
`base`, `core`, and `vendor` collections. Import cycles do not duplicate files.
Result paths outside the analysis root are absolute.

Imported packages contribute declarations and further imports. The analyzer
collects reference occurrences only in the analysis root and configured
collection roots.

Automatically followed dependencies are read-only. They support navigation, and
completion exposes only symbols made visible by selectors or `using import`.
Configured collection roots remain writable and contribute complete references.

Built-in definitions point to `base/builtin/builtin.odin` in the active compiler
distribution returned by `hw-odin toolchain root`.

Type inference currently uses declared source types. It does not execute the
complete Odin checker. General `using` statements, conditional-file evaluation,
polymorphic specialization, implicit selectors, overloads, and inferred
expressions can return `Ambiguous` or `Unresolved`. Run `diagnostics` or
`hw-odin check` for compiler authority.

## Performance

Run `./benchmark.sh` to measure the local fixture. On an Apple Silicon
development machine, version `0.5.0` measured on 2026-08-13 with MCP usage recording active:

- Warm definition query: 2.8 ms mean across 100 runs.
- Cold daemon startup and initial index: 21.2 ms mean across 10 runs.
- Cold capability-catalog construction: 690.25 ms.
- Warm indexed and recorded capability audit: 14.46 ms median across 29 warm runs.
- Equivalent fresh `rg` scan of Odin `core`: 22.00 ms median across 30 runs.
- Warm MCP speedup over the regular source scan: 1.52× median.
- MCP tool catalog: 3,794 bytes.
- Compact 40-match capability audit: 8,249 bytes.
- Compact two-query symbol lookup: 982 bytes.
- Usage database after the benchmark session: 196,608 bytes across 34 events.

The values include process startup, socket transport, JSON encoding, and
FSEvents synchronization.

## Reference implementation

The design study uses OLS at commit `ca8eb6da44c2b1c9e63736af05a5c3a5a298ea82`. OLS is reference material and is not a dependency.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for attribution.
