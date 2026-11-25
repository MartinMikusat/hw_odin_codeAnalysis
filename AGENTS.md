# hw_odin_codeAnalysis

Verify with `./build.sh`. `./install.sh` installs the binary that the agent hooks and
project build scripts run. Current integration and ownership contracts are in
[README.md](README.md).

- src/: compiler-backed Odin project analysis.
- src/workflow/: the check, edit, show, crash, perf and guard commands.
- cmd/: command-line and MCP entry points.
- scripts/: agent-session extraction for process reviews.
- tests/: analysis contracts and integration fixtures.
