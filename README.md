# Odin Code Analysis

An agent-first Odin code-analysis engine with a persistent semantic daemon.

## AI-assisted development disclosure

Models used:

- **GPT-5.6-Sol**

The project analyzes saved Odin source files for terminal agents. It does not implement an editor language server or an MCP server.

## Status

The first implementation targets macOS on Apple Silicon and Odin `dev-2026-07a`.

## Build

```sh
ODIN=/Users/martin/.local/share/odin/dev-2026-07a/odin ./build.sh
```

Install the verified binary in `~/.local/bin`:

```sh
ODIN=/Users/martin/.local/share/odin/dev-2026-07a/odin ./install.sh
```

## Test

```sh
ODIN=/Users/martin/.local/share/odin/dev-2026-07a/odin ./test.sh
```

## Commands

Run `build/hw-odin-analyze help` for the complete command list.

Analysis commands emit JSON and do not change source files. Source positions use one-based lines and UTF-8 byte columns.

The executable starts one daemon for each analysis root. The client and daemon
exchange length-prefixed JSON through a Unix-domain socket. The daemon exits
after 15 minutes without a request.

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

`rename` returns a checked edit plan. It does not write source files.

### Configuration

Place `code-analysis.json` in the analysis root. The file can set the Odin
command, checker arguments, collection roots, and excluded paths. See
[`schema/code-analysis.schema.json`](schema/code-analysis.schema.json).

### Current analysis boundary

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

Built-in definitions point to `base/builtin/builtin.odin` in the pinned compiler
distribution. Keep that compiler distribution available after installation.

Type inference currently uses declared source types. It does not execute the
complete Odin checker. General `using` statements, conditional-file evaluation,
polymorphic specialization, implicit selectors, overloads, and inferred
expressions can return `Ambiguous` or `Unresolved`. Run `diagnostics` or
`odin check` for compiler authority.

## Performance

Run `./benchmark.sh` to measure the local fixture. On an Apple Silicon
development machine, version `0.1.0` measured:

- Warm definition query: 2.4 ms mean across 100 runs.
- Cold daemon startup and initial index: 16.0 ms mean across 10 runs.

The values include process startup, socket transport, JSON encoding, and
FSEvents synchronization.

## Reference implementation

The design study uses OLS at commit `ca8eb6da44c2b1c9e63736af05a5c3a5a298ea82`. OLS is reference material and is not a dependency.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for attribution.
