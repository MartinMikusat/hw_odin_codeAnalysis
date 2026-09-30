# Outstanding work

## Deferred scope

- [ ] **Potential extension — evaluate a compact structural edit planner for recurring Odin refactors.**
  - Intent: replace token-heavy `apply_patch` inputs that repeat absolute paths, removed source, unchanged context, and string escaping with generation-bound operations on qualified Odin symbols and syntax nodes. Candidate operations include extracting or moving nodes, wrapping a statement range, replacing a resolved call, and guarding resolved statements with a condition.
  - Output boundary: resolve each operation against the persistent Odin index and AST, reject ambiguous or stale inputs, and return one atomic checked edit plan with the affected symbols and syntax diagnostics. Keep source mutation in the calling agent; the analysis server must not write files.
  - Decision gate: replay representative archived Odin `apply_patch` calls through a prototype and compare complete request-and-response token counts, resulting text edits, ambiguity handling, and stale-source rejection. Adopt the extension only when it reduces total edit traffic without moving open-ended refactor planning into the server or adding primitives tailored to one patch.
- Do not add source-writing MCP tools. Keep rename and future refactors as checked edit plans.
- Do not implement a full editor language-server protocol unless a separate product requirement establishes that scope.
- Defer embedding-based semantic search until persistent structural and lexical indexes have measured recall gaps.
- Keep the MCP surface small and batch-oriented; do not add one wrapper tool for every internal procedure.
