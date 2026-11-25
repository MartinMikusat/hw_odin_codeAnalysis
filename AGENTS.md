# hw_odin_codeAnalysis

Verify with `./build.sh`. `./install.sh` installs the binary that the agent hooks
run. Current integration and ownership contracts are in [README.md](README.md).

- src/: compiler-backed Odin project analysis.
- src/workflow/: the check, edit, show, crash and guard commands.
  A check never builds a project and needs no file inside it.
- src/usage/: the local record of tool runs, shell bypasses and MCP traffic.
- hooks/: the pi and OpenCode adapters for `guard`.
- cmd/: command-line and MCP entry points.
- scripts/: agent-session extraction for process reviews.
- tests/: analysis contracts and integration fixtures.
