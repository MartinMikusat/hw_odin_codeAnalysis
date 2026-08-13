#!/usr/bin/env bash
set -euo pipefail

root="tests/fixtures/workspace"
analyzer=(./build/hw-odin-analyze --root "$root" --compact)
failure_root=""
failure_analyzer=()
dependency_root=""
dependency_analyzer=()
config_root=""
config_analyzer=()
timeout_root=""
timeout_analyzer=()
partial_client_pid=""
partial_fifo_open=false
timeout_status_pid=""
usage_root=""
usage_database=""

cleanup() {
  if [[ "$partial_fifo_open" == true ]]; then
    exec 9>&-
    partial_fifo_open=false
  fi
  if [[ -n "$timeout_status_pid" ]]; then
    kill "$timeout_status_pid" >/dev/null 2>&1 || true
    wait "$timeout_status_pid" >/dev/null 2>&1 || true
    timeout_status_pid=""
  fi
  if [[ -n "$partial_client_pid" ]]; then
    kill "$partial_client_pid" >/dev/null 2>&1 || true
    wait "$partial_client_pid" >/dev/null 2>&1 || true
    partial_client_pid=""
  fi
  "${analyzer[@]}" stop >/dev/null 2>&1 || true
  if [[ -n "$failure_root" ]]; then
    "${failure_analyzer[@]}" stop >/dev/null 2>&1 || true
    chmod 600 "$failure_root/unreadable.odin" >/dev/null 2>&1 || true
    rm -rf -- "$failure_root"
  fi
  if [[ -n "$dependency_root" ]]; then
    "${dependency_analyzer[@]}" stop >/dev/null 2>&1 || true
    rm -rf -- "$dependency_root"
  fi
  if [[ -n "$config_root" ]]; then
    "${config_analyzer[@]}" stop >/dev/null 2>&1 || true
    rm -rf -- "$config_root"
  fi
  if [[ -n "$timeout_root" ]]; then
    "${timeout_analyzer[@]}" stop >/dev/null 2>&1 || true
    rm -rf -- "$timeout_root"
  fi
  if [[ -n "$usage_root" ]]; then
    rm -rf -- "$usage_root"
  fi
}
trap cleanup EXIT

cleanup

status="$("${analyzer[@]}" status)"
[[ "$status" == *'"persistent":true'* ]]

capability="$({
  printf '%s\n' \
    '{"target_project":".","primitives":[{"id":"weekday","need":"calculate a weekday","search_terms":["datetime.day_of_week","day_of_week"]}]}'
} | "${analyzer[@]}" capability-audit)"
[[ "$capability" == *'"status":"available"'* ]]
[[ "$capability" == *'"source":"odin.core"'* ]]

max_batch="$(jq -nc '{queries:[range(64)|{query:"greet"}]}')"
usage_root="$(mktemp -d "${TMPDIR:-/tmp}/hw-odin-usage-XXXXXX")"
usage_database="$usage_root/usage.sqlite3"
startup_root="$usage_root/startup-root"
startup_database="$usage_root/startup.sqlite3"
mkdir "$startup_root"
printf 'package broken\nbroken :: proc(' >"$startup_root/broken.odin"
startup_mcp="$({
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"startup-test","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
} | HW_ODIN_ANALYZE_USAGE_DB="$startup_database" \
      ./build/hw-odin-analyze --root "$startup_root" mcp)"
printf '%s\n' "$startup_mcp" | jq -e -s '
  (map(select(.id == 1))[0].result.protocolVersion == "2025-11-25") and
  (map(select(.id == 2))[0].result.tools | map(.name) | index("lookup_symbols") != null)
' >/dev/null

mcp="$({
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"integration-test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"audit_primitives","arguments":{"target_project":".","primitives":[]}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lookup_symbols","arguments":{"queries":[{"query":"greet"}]}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"missing_tool","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"lookup_symbols","arguments":{"queries":[]}}}' \
    '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"audit_primitives","arguments":{"target_project":".","primitives":[{"id":"bad","need":"bad constraint","search_terms":[],"generic_requirement":"sometimes"}]}}}' \
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"inspect_symbol","arguments":{"queries":[{"file":"main.odin","line":1,"column":1}]}}}' \
    '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"lookup_symbols","arguments":{"queries":[{"query":"greet"},{"query":""}]}}}'
  jq -nc --argjson arguments "$max_batch" \
    '{jsonrpc:"2.0",id:8,method:"tools/call",params:{name:"lookup_symbols",arguments:$arguments}}'
} | HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
      ./build/hw-odin-analyze --root "$root" mcp)"
printf '%s\n' "$mcp" | jq -e -s '
  (map(select(.id == 1))[0].result.protocolVersion == "2025-11-25") and
  (map(select(.id == 2))[0].result.tools | map(.name) | index("audit_primitives") != null) and
  (map(select(.id == 2))[0].result.tools | map(.name) | index("lookup_symbols") != null) and
  (map(select(.id == 3))[0].result.structuredContent.generation == 1) and
  (map(select(.id == 4))[0].result.structuredContent.results[0][0].name == "greet") and
  (map(select(.id == 5))[0].error.code == -32602) and
  (map(select(.id == 6))[0].result.isError == true) and
  (map(select(.id == 7))[0].result.isError == true) and
  (map(select(.id == 8))[0].result.structuredContent.results | length == 64) and
  (map(select(.id == 9))[0].result.structuredContent.results[0].resolution == "Unresolved") and
  (map(select(.id == 10))[0].result.isError == true)
' >/dev/null

usage_status="$(
  HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
    ./build/hw-odin-analyze --compact usage status
)"
printf '%s\n' "$usage_status" | jq -e '
  (.schema_version == 1) and
  (.session_count == 1) and
  (.event_count == 11) and
  (.payload_count == 11) and
  (.payload_retention_days == 90)
' >/dev/null
[[ "$(stat -f '%Lp' "$usage_database")" == "600" ]]
[[ "$(
  sqlite3 -separator '|' "$usage_database" \
    'SELECT client_name, client_version, protocol_version FROM mcp_sessions'
)" == 'integration-test|1|2025-11-25' ]]

usage_summary="$(
  HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
    ./build/hw-odin-analyze --root "$root" --compact usage summary --days 1
)"
printf '%s\n' "$usage_summary" | jq -e '
  (.total_events == 11) and
  (.tool_calls == 8) and
  (.protocol_error_count == 1) and
  (.tool_error_count == 3) and
  (.notification_count == 1) and
  (.payloads_retained == 11) and
  ([.groups[] | select(.tool_name == "lookup_symbols")][0].event_count == 4)
' >/dev/null

inspect_usage="$(
  HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
    ./build/hw-odin-analyze --root "$root" --compact usage recent \
      --days 1 --tool inspect_symbol --limit 1
)"
printf '%s\n' "$inspect_usage" | jq -e '
  (.events | length == 1) and
  (.events[0].result_count == 1) and
  (.events[0].unresolved_count == 1)
' >/dev/null

failed_batch_usage="$(
  HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
    ./build/hw-odin-analyze --root "$root" --compact usage recent \
      --days 1 --tool lookup_symbols --limit 4
)"
printf '%s\n' "$failed_batch_usage" | jq -e '
  ([.events[] | select(
    (.outcome == "tool_error") and (.error_message == "query is required")
  )] | length == 1) and
  ([.events[] | select(.error_message == "query is required")][0] |
    (.result_count == 0) and
    (.empty_result_count == 0) and
    (.ambiguous_count == 0) and
    (.unresolved_count == 0)
  )
' >/dev/null

usage_recent="$(
  HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
    ./build/hw-odin-analyze --root "$root" --compact usage recent \
      --days 1 --tool missing_tool --limit 1 --include-payloads
)"
printf '%s\n' "$usage_recent" | jq -e '
  (.events | length == 1) and
  (.events[0].outcome == "protocol_error") and
  (.events[0].request_payload_encoding == "utf8") and
  (.events[0].request_payload == "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"missing_tool\",\"arguments\":{}}}") and
  (.events[0].response_payload == "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32602,\"message\":\"unknown tool name\"}}")
' >/dev/null

compact_database="$usage_root/compact.sqlite3"
python3 - "$root" "$compact_database" <<'PY'
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

root = sys.argv[1]
database = sys.argv[2]
environment = os.environ.copy()
environment["HW_ODIN_ANALYZE_USAGE_DB"] = database
process = subprocess.Popen(
    ["./build/hw-odin-analyze", "--root", root, "mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=environment,
)

def call(request):
    process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    process.stdin.flush()
    response_line = process.stdout.readline()
    if not response_line:
        raise RuntimeError(process.stderr.read())
    return len(response_line.rstrip("\n").encode()), json.loads(response_line)

def tool_call(request_id, name, arguments):
    response_bytes, response = call({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })
    result = response["result"]
    assert result["content"][0]["text"].startswith(f"ok: {name};")
    assert len(result["content"][0]["text"].encode()) <= 160
    assert not result["content"][0]["text"].startswith("{")
    structured = result["structuredContent"]
    assert not {
        "compiler_release",
        "compiler_root",
        "indexed_roots",
        "excluded_paths",
        "fsevents_flushed",
        "query_scope",
        "result_limit",
    }.intersection(structured)
    return response_bytes, structured

_, initialized = call({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-06-18",
        "clientInfo": {"name": "codex-mcp-client", "version": "integration"},
    },
})
assert initialized["result"]["serverInfo"]["version"] == "0.5.0"

tool_list_bytes, listed = call({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
    "params": {},
})
assert tool_list_bytes <= 4500
tools = {tool["name"]: tool for tool in listed["result"]["tools"]}
lookup_properties = tools["lookup_symbols"]["inputSchema"]["properties"]["queries"]["items"]["properties"]
symbol_properties = tools["inspect_symbol"]["inputSchema"]["properties"]["queries"]["items"]["properties"]
file_properties = tools["file_outline"]["inputSchema"]["properties"]["queries"]["items"]["properties"]
rename_properties = tools["rename"]["inputSchema"]["properties"]["queries"]["items"]["properties"]
assert set(lookup_properties) == {"query"}
assert set(symbol_properties) == {"symbol_id", "generation", "file", "line", "column"}
assert symbol_properties["symbol_id"]["minimum"] == 0
assert set(file_properties) == {"file", "scope"}
assert set(rename_properties) == {
    "symbol_id", "generation", "file", "line", "column", "new_name",
}
assert rename_properties["symbol_id"]["minimum"] == 0

audit_bytes, audit = tool_call(3, "audit_primitives", {
    "target_project": ".",
    "primitives": [
        {"id": "weekday", "need": "calculate a weekday", "search_terms": ["day_of_week"]},
        {"id": "json", "need": "encode JSON values", "search_terms": ["json.Value", "json.marshal"]},
        {"id": "allocate", "need": "allocate temporary arrays", "search_terms": ["make", "append"]},
        {"id": "time", "need": "read time values", "search_terms": ["time.now", "time"]},
        {"id": "string", "need": "join string values", "search_terms": ["strings.join", "join"]},
    ],
})
assert audit_bytes <= 15000
assert sum(len(result["matches"]) for result in audit["results"]) == 40
assert all(result["status"] == "available" for result in audit["results"])
removed_match_fields = {
    "signature", "docs", "excerpt", "reasons", "unknown_properties",
    "allocation_behavior", "ownership", "platform", "package",
}
for primitive in audit["results"]:
    assert "need" not in primitive
    for match in primitive["matches"]:
        assert not removed_match_fields.intersection(match)
        source_root = audit["roots"][
            "compiler" if match["source"].startswith("odin.") else "workspace"
        ]
        assert Path(source_root, match["file"]).is_file()

lookup_bytes, lookup = tool_call(4, "lookup_symbols", {
    "queries": [{"query": "Person"}, {"query": "greet"}],
})
assert lookup_bytes <= 1000
person = next(symbol for symbol in lookup["results"][0] if symbol["name"] == "Person")
greet = next(symbol for symbol in lookup["results"][1] if symbol["name"] == "greet")
assert person["symbol_id"] == 0
assert not {"detail", "documentation", "range", "extent", "path"}.intersection(greet)
source_line = Path(lookup["roots"]["workspace"], greet["file"]).read_text().splitlines()[greet["line"] - 1]
assert "greet :: proc" in source_line

_, inspected = tool_call(5, "inspect_symbol", {
    "queries": [
        {"symbol_id": person["symbol_id"], "generation": lookup["generation"]},
        {"symbol_id": greet["symbol_id"], "generation": lookup["generation"]},
    ],
})
assert inspected["results"][0]["symbols"][0]["symbol_id"] == 0
assert inspected["results"][0]["symbols"][0]["name"] == "Person"
inspected_symbol = inspected["results"][1]["symbols"][0]
assert inspected_symbol["symbol_id"] == greet["symbol_id"]
assert inspected_symbol["signature"] == "proc(person: ^Person) -> string"
assert not {"detail", "range", "extent", "explanation"}.intersection(inspected_symbol)

_, definitions = tool_call(6, "definition_and_references", {
    "queries": [{"file": "main.odin", "line": 15, "column": 6}],
})
assert definitions["results"][0]["definition"]["resolution"] == "Exact"
assert len(definitions["results"][0]["references"]) == 2
assert "offset" not in definitions["results"][0]["references"][0]

_, graph = tool_call(7, "call_graph", {
    "queries": [{"symbol_id": greet["symbol_id"], "generation": lookup["generation"]}],
})
assert graph["results"][0]["callers"][0]["name"] == "run"

_, outline = tool_call(8, "file_outline", {"queries": [{"file": "main.odin"}]})
assert [symbol["name"] for symbol in outline["results"][0]] == ["Person", "greet", "run"]

_, package_api = tool_call(9, "package_api", {"queries": [{"query": "fixture"}]})
assert any(symbol["name"] == "greet" for symbol in package_api["results"][0])

_, imports = tool_call(10, "imports", {"queries": [{"file": "main.odin"}]})
assert imports["results"][0][0]["import_path"] == "./helper"
assert "range" not in imports["results"][0][0]

_, diagnostics = tool_call(11, "diagnostics", {"queries": [{"file": "main.odin"}]})
assert diagnostics["results"] == [[]]

_, impact = tool_call(12, "impact_analysis", {
    "queries": [{"symbol_id": greet["symbol_id"], "generation": lookup["generation"]}],
})
assert impact["results"][0]["affected_packages"] == ["fixture"]
assert impact["results"][0]["callers"][0]["name"] == "run"

_, rename = tool_call(13, "rename", {
    "queries": [{
        "symbol_id": greet["symbol_id"],
        "generation": lookup["generation"],
        "new_name": "welcome",
    }],
})
assert len(rename["results"][0]) == 2
assert all(edit["new_text"] == "welcome" for edit in rename["results"][0])
assert all(not {"path", "range", "offset"}.intersection(edit) for edit in rename["results"][0])

process.stdin.close()
assert process.wait(timeout=10) == 0, process.stderr.read()

with sqlite3.connect(database) as connection:
    recorded_tool_list = connection.execute(
        "SELECT response_bytes FROM mcp_events WHERE method='tools/list'"
    ).fetchone()[0]
    recorded_audit = connection.execute(
        "SELECT response_bytes FROM mcp_events WHERE tool_name='audit_primitives'"
    ).fetchone()[0]
    recorded_lookup = connection.execute(
        "SELECT response_bytes FROM mcp_events WHERE tool_name='lookup_symbols'"
    ).fetchone()[0]
assert recorded_tool_list == tool_list_bytes
assert recorded_audit == audit_bytes
assert recorded_lookup == lookup_bytes
PY

usage_writer_pids=()
for writer in 1 2; do
  {
    printf '%s\n' \
      "{\"jsonrpc\":\"2.0\",\"id\":$writer,\"method\":\"ping\"}" |
      HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
        ./build/hw-odin-analyze --root "$root" mcp \
          >"$usage_root/writer-$writer.json"
  } &
  usage_writer_pids+=("$!")
done
for writer_pid in "${usage_writer_pids[@]}"; do
  wait "$writer_pid"
done
for writer in 1 2; do
  jq -e --argjson id "$writer" \
    '(.id == $id) and (.result == {})' \
    "$usage_root/writer-$writer.json" >/dev/null
done
usage_status="$(
  HW_ODIN_ANALYZE_USAGE_DB="$usage_database" \
    ./build/hw-odin-analyze --compact usage status
)"
printf '%s\n' "$usage_status" | jq -e '
  (.session_count == 3) and (.event_count == 13) and (.payload_count == 13)
' >/dev/null

reload_root="$usage_root/reload-root"
reload_database="$usage_root/reload.sqlite3"
mkdir "$reload_root"
printf 'package reload_fixture\n\nrun :: proc() {}\n' >"$reload_root/main.odin"
printf '{"exclude_paths":[]}\n' >"$reload_root/code-analysis.json"
python3 - "$reload_root" "$reload_database" <<'PY'
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

root = sys.argv[1]
database = sys.argv[2]
environment = os.environ.copy()
environment["HW_ODIN_ANALYZE_USAGE_DB"] = database
process = subprocess.Popen(
    ["./build/hw-odin-analyze", "--root", root, "mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=environment,
)

def call(request):
    process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    process.stdin.flush()
    response = process.stdout.readline()
    if not response:
        raise RuntimeError(process.stderr.read())
    return json.loads(response)

initialized = call({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-11-25",
        "clientInfo": {"name": "reload-test", "version": "1"},
    },
})
assert initialized["id"] == 1
ready = call({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
        "name": "lookup_symbols",
        "arguments": {"queries": [{"query": "run"}]},
    },
})
assert any(
    match["name"] == "run"
    for match in ready["result"]["structuredContent"]["results"][0]
)
Path(root, "code-analysis.json").write_text(
    '{"exclude_paths":["ignored"]}\n',
    encoding="utf-8",
)

for request_id in range(3, 103):
    time.sleep(0.05)
    response = call({"jsonrpc": "2.0", "id": request_id, "method": "ping"})
    assert response == {"jsonrpc": "2.0", "id": request_id, "result": {}}
    with sqlite3.connect(database) as connection:
        session_count = connection.execute(
            "SELECT COUNT(*) FROM mcp_sessions"
        ).fetchone()[0]
    if session_count == 2:
        break
else:
    raise AssertionError("configuration reload did not rotate the usage session")

process.stdin.close()
assert process.wait(timeout=10) == 0, process.stderr.read()
PY

[[ "$(
  sqlite3 -separator '|' "$reload_database" \
    "SELECT COUNT(*), COUNT(DISTINCT config_digest),
            SUM(ended_at_ns IS NOT NULL),
            COUNT(*) FILTER (
              WHERE protocol_version='2025-11-25'
                AND client_name='reload-test'
                AND client_version='1'
            )
     FROM mcp_sessions"
)" == '2|2|2|2' ]]

mkdir "$usage_root/unwritable-database"
logging_failure_response="$(
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' |
    HW_ODIN_ANALYZE_USAGE_DB="$usage_root/unwritable-database" \
      ./build/hw-odin-analyze --root "$root" mcp 2>"$usage_root/logging-error.txt"
)"
printf '%s\n' "$logging_failure_response" | jq -e '
  (.id == 1) and (.result == {})
' >/dev/null
grep -Fq 'usage recording failed' "$usage_root/logging-error.txt"

definition="$("${analyzer[@]}" definition main.odin 15 6)"
[[ "$definition" == *'"resolution":"Exact"'* ]]
[[ "$definition" == *'"name":"greet"'* ]]

completion="$("${analyzer[@]}" completion main.odin 10 20)"
[[ "$completion" == *'"name":"name"'* ]]

generation_before="$(
  printf '%s' "$status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"
touch tests/fixtures/workspace/main.odin
status="$("${analyzer[@]}" status)"
generation_after="$(
  printf '%s' "$status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"
((generation_after > generation_before))

diagnostics="$("${analyzer[@]}" diagnostics --workspace)"
[[ "$diagnostics" == '[]' ]]

rename="$("${analyzer[@]}" rename main.odin 9 1 welcome)"
[[ "$rename" == *'"new_text":"welcome"'* ]]

if "${analyzer[@]}" rename main.odin 9 1 run >/dev/null 2>&1; then
  printf 'expected the colliding rename to fail\n' >&2
  exit 1
fi

failure_root="$(mktemp -d "${TMPDIR:-/tmp}/hw-odin-analysis-XXXXXX")"
failure_analyzer=(./build/hw-odin-analyze --root "$failure_root" --compact)
printf 'package fixture\n\noriginal :: proc() {}\n' \
  >"$failure_root/main.odin"
printf 'package fixture\n\nstable :: proc() {}\n' \
  >"$failure_root/unreadable.odin"

failure_status="$("${failure_analyzer[@]}" status)"
failure_generation="$(
  printf '%s' "$failure_status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"

printf 'package fixture\n\noriginal :: proc() {}\nadded :: proc() {}\n' \
  >"$failure_root/main.odin"
chmod 000 "$failure_root/unreadable.odin"

failure_seen=false
for _ in {1..100}; do
  if ! failure_output="$("${failure_analyzer[@]}" status 2>&1)"; then
    failure_seen=true
    break
  fi
  sleep 0.02
done
if [[ "$failure_seen" != true ]]; then
  printf 'expected the failed rebuild to reject a request\n' >&2
  exit 1
fi
[[ "$failure_output" == *'failed to rebuild the analysis index'* ]]

if failure_output="$("${failure_analyzer[@]}" status 2>&1)"; then
  printf 'expected the rearmed rebuild to reject the next request\n' >&2
  exit 1
fi
[[ "$failure_output" == *'failed to rebuild the analysis index'* ]]

chmod 600 "$failure_root/unreadable.odin"
failure_status="$("${failure_analyzer[@]}" status)"
failure_generation_after="$(
  printf '%s' "$failure_status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"
((failure_generation_after == failure_generation + 1))

failure_search="$("${failure_analyzer[@]}" search added)"
[[ "$failure_search" == *'"name":"added"'* ]]

printf 'package fixture\n\ndoomed :: proc() {}\n' >"$failure_root/doomed.odin"
failure_status="$("${failure_analyzer[@]}" status)"
failure_generation_before_delete="$(
  printf '%s' "$failure_status" | jq -r '.generation'
)"
rm -- "$failure_root/doomed.odin"
failure_status="$("${failure_analyzer[@]}" status)"
failure_generation_after_delete="$(
  printf '%s' "$failure_status" | jq -r '.generation'
)"
((failure_generation_after_delete > failure_generation_before_delete))
[[ "$("${failure_analyzer[@]}" search doomed)" == '[]' ]]

dependency_root="$(mktemp -d "${TMPDIR:-/tmp}/hw-odin-dependencies-XXXXXX")"
mkdir -p "$dependency_root/app" "$dependency_root/dep_a" "$dependency_root/dep_b"
dependency_analyzer=(
  ./build/hw-odin-analyze
  --root "$dependency_root/app"
  --compact
)
printf 'package app\n\nusing import "../dep_a"\n\nrun :: proc() {\ndep_a_name()\n}\n' \
  >"$dependency_root/app/main.odin"
printf 'package dep_a\n\ndep_a_name :: proc() {}\n' \
  >"$dependency_root/dep_a/dep.odin"
printf 'package dep_b\n\ndep_b_name :: proc() {}\n' \
  >"$dependency_root/dep_b/dep.odin"

dependency_status="$("${dependency_analyzer[@]}" status)"
dependency_generation="$(
  printf '%s' "$dependency_status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"
dependency_definition="$(
  "${dependency_analyzer[@]}" definition main.odin 6 1
)"
[[ "$dependency_definition" == *'"name":"dep_a_name"'* ]]

printf 'package app\n\nusing import "../dep_b"\n\nrun :: proc() {\ndep_b_name()\n}\n' \
  >"$dependency_root/app/main.odin"
dependency_replaced=false
for _ in {1..100}; do
  dependency_definition="$(
    "${dependency_analyzer[@]}" definition main.odin 6 1
  )"
  if [[ "$dependency_definition" == *'"name":"dep_b_name"'* ]]; then
    dependency_replaced=true
    break
  fi
  sleep 0.02
done
if [[ "$dependency_replaced" != true ]]; then
  printf 'expected the rebuilt index to use the new dependency\n' >&2
  exit 1
fi

dependency_validation_status="$("${dependency_analyzer[@]}" status)"
dependency_validation_generation="$(
  printf '%s' "$dependency_validation_status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"
((dependency_validation_generation == dependency_generation + 2))

printf 'package dep_b\n\ndep_b_name :: proc() {}\nwatched_name :: proc() {}\n' \
  >"$dependency_root/dep_b/dep.odin"
dependency_watched=false
for _ in {1..100}; do
  dependency_search="$("${dependency_analyzer[@]}" search watched_name)"
  if [[ "$dependency_search" == *'"name":"watched_name"'* ]]; then
    dependency_watched=true
    break
  fi
  sleep 0.02
done
if [[ "$dependency_watched" != true ]]; then
  printf 'expected the replacement watcher to observe the dependency\n' >&2
  exit 1
fi

dependency_status="$("${dependency_analyzer[@]}" status)"
dependency_generation_after="$(
  printf '%s' "$dependency_status" |
    sed -E 's/.*"generation":([0-9]+).*/\1/'
)"
((dependency_generation_after > dependency_generation))

config_root="$(mktemp -d "${TMPDIR:-/tmp}/hw-odin-config-XXXXXX")"
mkdir -p \
  "$config_root/app/excluded" \
  "$config_root/collection"
config_analyzer=(
  ./build/hw-odin-analyze
  --root "$config_root/app"
  --compact
)
printf 'package app\n\nmain_name :: proc() {}\n' \
  >"$config_root/app/main.odin"
printf 'package excluded\n\nexcluded_name :: proc() {}\n' \
  >"$config_root/app/excluded/excluded.odin"
printf 'package collection\n\ncollection_name :: proc() {}\n' \
  >"$config_root/collection/collection.odin"
printf '{"exclude_paths":["excluded"]}\n' \
  >"$config_root/app/code-analysis.json"

config_status="$("${config_analyzer[@]}" status)"
config_file_count="$(
  printf '%s' "$config_status" |
    sed -E 's/.*"file_count":([0-9]+).*/\1/'
)"
config_digest="$(
  printf '%s' "$config_status" |
    sed -E 's/.*"config_digest":"([^"]+)".*/\1/'
)"
[[ -n "$config_digest" ]]
config_excluded="$("${config_analyzer[@]}" search excluded_name)"
[[ "$config_excluded" == '[]' ]]

printf '%s\n' \
  '{"collections":[{"name":"test_collection","path":"../collection"}],"exclude_paths":["ignored"]}' \
  >"$config_root/app/code-analysis.json"
config_reloaded=false
for _ in {1..100}; do
  if config_status="$("${config_analyzer[@]}" status 2>/dev/null)"; then
    config_file_count_after="$(
      printf '%s' "$config_status" |
        sed -E 's/.*"file_count":([0-9]+).*/\1/'
    )"
    config_digest_after="$(
      printf '%s' "$config_status" |
        sed -E 's/.*"config_digest":"([^"]+)".*/\1/'
    )"
    if ((config_file_count_after == config_file_count + 2)) &&
       [[ "$config_digest_after" != "$config_digest" ]]; then
      config_reloaded=true
      break
    fi
  fi
  sleep 0.02
done
if [[ "$config_reloaded" != true ]]; then
  printf 'expected the daemon to reload the configuration\n' >&2
  exit 1
fi

config_excluded="$("${config_analyzer[@]}" search excluded_name)"
[[ "$config_excluded" == *'"name":"excluded_name"'* ]]
config_collection="$("${config_analyzer[@]}" search collection_name)"
[[ "$config_collection" == *'"name":"collection_name"'* ]]

printf '%s\n' \
  'package collection' \
  '' \
  'collection_name :: proc() {}' \
  'watched_collection_name :: proc() {}' \
  >"$config_root/collection/collection.odin"
config_collection_watched=false
for _ in {1..100}; do
  config_collection="$(
    "${config_analyzer[@]}" search watched_collection_name
  )"
  if [[ "$config_collection" == *'"name":"watched_collection_name"'* ]]; then
    config_collection_watched=true
    break
  fi
  sleep 0.02
done
if [[ "$config_collection_watched" != true ]]; then
  printf 'expected the replacement watcher to observe the collection\n' >&2
  exit 1
fi

timeout_root="$(mktemp -d "${TMPDIR:-/tmp}/hw-odin-timeout-XXXXXX")"
timeout_analyzer=(
  ./build/hw-odin-analyze
  --root "$timeout_root"
  --compact
)
printf 'package timeout\n\ntimeout_name :: proc() {}\n' \
  >"$timeout_root/main.odin"

cache_root="$HOME/Library/Caches/hw_odin_codeAnalysis"
sockets_before="$(
  find "$cache_root" -type s -name daemon.sock 2>/dev/null |
    sort
)"
timeout_status="$("${timeout_analyzer[@]}" status)"
[[ "$timeout_status" == *'"persistent":true'* ]]
sockets_after="$(
  find "$cache_root" -type s -name daemon.sock 2>/dev/null |
    sort
)"
timeout_socket=""
timeout_socket_count=0
while IFS= read -r candidate; do
  if [[ -z "$candidate" ]]; then
    continue
  fi
  if ! printf '%s\n' "$sockets_before" | grep -Fqx "$candidate"; then
    timeout_socket="$candidate"
    timeout_socket_count=$((timeout_socket_count + 1))
  fi
done <<<"$sockets_after"
if ((timeout_socket_count != 1)); then
  printf 'expected one new daemon socket, found %d\n' \
    "$timeout_socket_count" >&2
  exit 1
fi

partial_fifo="$timeout_root/partial-client.fifo"
mkfifo "$partial_fifo"
nc -U "$timeout_socket" <"$partial_fifo" >/dev/null 2>&1 &
partial_client_pid=$!
exec 9>"$partial_fifo"
partial_fifo_open=true
printf '\0' >&9
sleep 0.05

timeout_status_output="$timeout_root/status-output.json"
timeout_status_error="$timeout_root/status-error.txt"
"${timeout_analyzer[@]}" status \
  >"$timeout_status_output" \
  2>"$timeout_status_error" &
timeout_status_pid=$!
timeout_status_completed=false
for _ in {1..150}; do
  if ! kill -0 "$timeout_status_pid" >/dev/null 2>&1; then
    timeout_status_completed=true
    break
  fi
  sleep 0.02
done
if [[ "$timeout_status_completed" != true ]]; then
  printf 'expected status after the incomplete request deadline\n' >&2
  exit 1
fi
if ! wait "$timeout_status_pid"; then
  timeout_status_pid=""
  printf 'status failed after the incomplete request:\n' >&2
  sed -n '1,20p' "$timeout_status_error" >&2
  exit 1
fi
timeout_status_pid=""
if ! grep -Fq '"persistent":true' "$timeout_status_output"; then
  printf 'expected a persistent status response after the timeout\n' >&2
  exit 1
fi

exec 9>&-
partial_fifo_open=false
wait "$partial_client_pid" || true
partial_client_pid=""
