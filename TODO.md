# Odin Code Analysis TODO

Work in the order below. Build the persistent indexes and test boundaries before expanding the MCP surface, then make reuse results directly actionable before adding broader navigation and refactoring queries.

## Completed in 0.5.0

- [x] Replace duplicated MCP JSON with one compact `structuredContent` value and a bounded text summary.
- [x] Return ranked capability and symbol source locators by default, then expand only selected symbols through `inspect_symbol` or direct source reads.
- [x] Project definitions, references, call graphs, outlines, package APIs, imports, diagnostics, impact records, and rename edits into compact agent-facing records without changing CLI output.
- [x] Reduce the persistent tool catalog with operation-specific input schemas and record response-size budgets against the local usage database.

## Completed in 0.4.0

- [x] Record every MCP input line and emitted response line in a global SQLite database, with session, workspace, client, compiler, configuration, outcome, latency, batch, result, resolution, truncation, byte-count, and SHA-256 metadata.
- [x] Keep MCP execution available when SQLite cannot open or write: retry after a bounded interval, throttle stderr diagnostics, and insert a synthetic gap event after recovery.
- [x] Retain event metrics indefinitely, remove request and response payload rows after 90 days, and run bounded incremental vacuum work once per day.
- [x] Add read-only `usage status`, `usage summary`, and `usage recent` reports with workspace, tool, time-window, and row-limit filters; require `--include-payloads` before returning stored input or output.
- [x] Cover exact payload capture, client and compiler-context session attribution, aggregate reports, strict payload redaction, UTF-8 and base64 display, retention, override-directory permission preservation, logging failure and recovery, atomic batch metrics, structural resolution counts, MCP failure isolation, and concurrent MCP writers.

## Completed in 0.3.0

- [x] Retain generation-owned semantic, capability, source, and documentation indexes across MCP requests; rebuild candidates on FSEvents and publish complete generations atomically.
- [x] Return executable reuse recipes with complete signatures, import and qualified names, excerpts, source ownership, platform restrictions, unknown semantic properties, generation, compiler identity, and rank reasons.
- [x] Apply kind, parameter, result, generic, platform, source-class, allocation, and ownership constraints before lexical ranking; unknown allocation or ownership data cannot satisfy a requested constraint.
- [x] Expose batched symbol lookup, inspection, definitions and references, caller and callee graphs, outlines, package APIs, imports, diagnostics, impact summaries, and checked rename plans through MCP.
- [x] Bind stable symbol IDs and checked edit plans to a published generation, and reject stale generation inputs.
- [x] Return structured ambiguity and unresolved explanations with package, imports, scope chain, analyzer boundary, and a concrete next action.
- [x] Report generation, configuration digest, compiler release and root, indexed roots, exclusions, FSEvents flush state, scope, limits, and truncation state.
- [x] Cover transactional rebuild failure, file deletion, nested shadowing, sibling procedures, using-import ambiguity, typed MCP errors, empty and maximum batches, and JSON field-level integration assertions.
- [x] Record cold catalog and warm query performance in `benchmark.sh`; the 2026-08-12 run measured a 14.41 ms warm median versus 21.91 ms for an equivalent fresh `rg` scan of Odin `core` (1.52× faster).

The sections below preserve the completed acceptance contract. No implementation item remains open; deferred product expansions remain excluded at the end of this file.

## P1 — Persistent analysis foundation

### 1. Unify capability auditing on persistent indexes

- Build owned indexes by package directory, file, symbol name, owner type, symbol identifier, declaration kind, signature, documentation, and source ownership.
- Index the active Odin `base`, `core`, and `vendor` collections plus every non-excluded workspace project required by capability auditing.
- Build each index inside the private candidate generation and publish all indexes through the existing atomic generation swap.
- Replace the per-request workspace and standard-library scan in `audit_primitives` with queries against the published generation.
- Preserve the classifications `odin.base`, `odin.core`, `odin.vendor`, `target_project`, `workspace_project`, and `test_or_fixture`.

Completion: capability audits and definition, reference, completion, caller, callee, and symbol-search queries use the published indexes instead of scanning complete source collections. Existing fixtures return unchanged results, file changes invalidate the correct generation, and a benchmark records cold-index construction and warm-query latency.

### 2. Complete semantic, daemon, and transport coverage

- Add fixtures for nested shadowing, sibling procedures, and ambiguous fields.
- Add a daemon test for files deleted during rebuild.
- Verify that a failed candidate build retains the previous complete generation.
- Decode integration-test JSON and assert typed fields instead of matching shell substrings.
- Add typed MCP tests for invalid requests, unknown tools, invalid primitive constraints, empty batches, maximum-size batches, and structured error results.

Completion: semantic fixtures return the expected resolution kind and locations, deletion publishes a complete replacement generation without stale results, failed rebuilds preserve the prior generation, and integration failures identify the mismatched JSON field.

## P2 — Agent query surface

### 3. Return an actionable reuse locator

For each `available` or `candidate` match, return:

- the import string and qualified symbol when available;
- declaration kind, source ownership, source path, line, and rank;
- the index generation, configuration digest, workspace root, and compiler root used for the result.

Completion: an agent can resolve every reported source location against the returned roots, inspect the declaration directly, and avoid loading complete signatures, excerpts, documentation, rank reasons, and repeated metadata for candidates it will not use.

### 4. Accept structural primitive constraints

Extend each primitive with optional fields for declaration kind, parameter types, result types, generic requirements, target platform, allocation behavior, ownership or lifetime requirements, and allowed source classes.

Apply exact constraints before lexical ranking. Keep lexical overlap for discovery, but reject a same-named declaration when its known structure conflicts with the requested primitive. Report unknown properties as unknown instead of treating them as compatible.

Completion: focused cases distinguish procedures with the same name but incompatible signatures, exclude test-only matches when requested, filter platform-specific declarations correctly, and preserve the current unconstrained request format.

### 5. Expose existing navigation operations through MCP

Add a small batch-oriented MCP surface for:

- `lookup_symbols`: exact and fuzzy symbol discovery;
- `inspect_symbol`: declaration, type, signature, documentation, owner type, and members;
- `definition_and_references`: definition resolution and complete indexed references;
- `call_graph`: direct callers and callees;
- `file_outline`: ordered declarations in one file;
- `package_api`: exported declarations and import paths for one package;
- `imports`: resolved imports and collection ownership;
- `diagnostics`: compiler-authoritative diagnostics for a file, package, or valid workspace scope.

Accept batches where several related queries can share one generation. Prefer stable symbol identifiers after the first lookup while retaining file, line, and UTF-8 byte column inputs for source-position queries.

Completion: every existing read-only CLI query has an MCP equivalent with structured output, bounded result sizes, explicit resolution states, and parity tests against the CLI result.

### 6. Explain ambiguous and unresolved results

Return the resolution kind, matching symbol locators, reason, next action, and analyzer boundary. Distinguish missing declarations from unsupported inference, overload resolution, polymorphic specialization, implicit selectors, conditional-file evaluation, and general `using` behavior without embedding the complete internal resolution trace.

Completion: every `Ambiguous` or `Unresolved` result contains a structured reason and at least one concrete next action when further source inspection or an `hw-odin check` can resolve it.

## P3 — Change planning

### 7. Add read-only impact analysis and checked edit plans

- Add `impact_analysis` for references, callers, affected packages, relevant tests, imports, and configuration files tied to a symbol.
- Expose the existing non-mutating rename planner through MCP.
- Return checked text edits with the source generation and reject the plan when the indexed files have changed.
- Keep all source mutation in the calling agent; the MCP server must not apply edits.

Completion: an agent can inspect the complete known impact of a symbol change and obtain a generation-bound rename plan without modifying source files.

### 8. Report compact freshness and source roots on every response

Include the index generation, configuration digest, workspace and compiler source roots, and truncation state in every MCP result. Include a match limit only where capability results are explicitly bounded.

Completion: an agent can reject stale symbol identities, resolve source locators, and detect truncated results without paying for compiler release, indexed-root, exclusion, watcher, scope, and limit metadata on every call.

## Deferred and excluded

- [ ] **Potential extension — evaluate a compact structural edit planner for recurring Odin refactors.**
  - Intent: replace token-heavy `apply_patch` inputs that repeat absolute paths, removed source, unchanged context, and string escaping with generation-bound operations on qualified Odin symbols and syntax nodes. Candidate operations include extracting or moving nodes, wrapping a statement range, replacing a resolved call, and guarding resolved statements with a condition.
  - Output boundary: resolve each operation against the persistent Odin index and AST, reject ambiguous or stale inputs, and return one atomic checked edit plan with the affected symbols and syntax diagnostics. Keep source mutation in the calling agent; the analysis server must not write files.
  - Decision gate: replay representative archived Odin `apply_patch` calls through a prototype and compare complete request-and-response token counts, resulting text edits, ambiguity handling, and stale-source rejection. Adopt the extension only when it reduces total edit traffic without moving open-ended refactor planning into the server or adding primitives tailored to one patch.
- Do not add source-writing MCP tools. Keep rename and future refactors as checked edit plans.
- Do not implement a full editor language-server protocol unless a separate product requirement establishes that scope.
- Defer embedding-based semantic search until persistent structural and lexical indexes have measured recall gaps.
- Keep the MCP surface small and batch-oriented; do not add one wrapper tool for every internal procedure.
