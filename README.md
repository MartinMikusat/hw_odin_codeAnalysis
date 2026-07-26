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

## Test

```sh
ODIN=/Users/martin/.local/share/odin/dev-2026-07a/odin ./test.sh
```

## Commands

Run `build/hw-odin-analyze help` for the complete command list.

Analysis commands emit JSON and do not change source files. Source positions use one-based lines and UTF-8 byte columns.

## Reference implementation

The design study uses OLS at commit `ca8eb6da44c2b1c9e63736af05a5c3a5a298ea82`. OLS is reference material and is not a dependency.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for attribution.
