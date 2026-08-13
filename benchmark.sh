#!/usr/bin/env bash
set -euo pipefail

if ! command -v hyperfine >/dev/null; then
  printf 'hyperfine is required\n' >&2
  exit 1
fi

root="tests/fixtures/workspace"
analyzer=(./build/hw-odin-analyze --root "$root" --compact)
benchmark_command="./build/hw-odin-analyze --root $root --compact"
usage_root="$(mktemp -d "${TMPDIR:-/tmp}/hw-odin-benchmark-usage-XXXXXX")"
export HW_ODIN_ANALYZE_USAGE_DB="$usage_root/usage.sqlite3"
trap 'rm -rf -- "$usage_root"' EXIT

"${analyzer[@]}" stop >/dev/null 2>&1 || true
"${analyzer[@]}" status >/dev/null

hyperfine --warmup 5 --runs 100 \
  "$benchmark_command definition main.odin 15 6"

hyperfine --runs 10 \
  --prepare "$benchmark_command stop >/dev/null 2>&1 || true" \
  "$benchmark_command status"

"${analyzer[@]}" stop >/dev/null

python3 - <<'PY'
import json
import os
import sqlite3
import statistics
import subprocess
import time

process = subprocess.Popen(
    ["./build/hw-odin-analyze", "--root", "tests/fixtures/workspace", "mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
    bufsize=1,
)

def call(request):
    started = time.perf_counter_ns()
    process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    process.stdin.flush()
    response_line = process.stdout.readline()
    response = json.loads(response_line)
    return (
        (time.perf_counter_ns() - started) / 1e6,
        len(response_line.rstrip("\n").encode()),
        response,
    )

call({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}})
_, tools_list_bytes, _ = call({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list",
    "params": {},
})
request = {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
        "name": "audit_primitives",
        "arguments": {
            "target_project": ".",
            "primitives": [{
                "id": "weekday",
                "need": "calculate a weekday",
                "search_terms": ["day_of_week"],
            }],
        },
    },
}
warm = []
cold_index_ms = 0
for run in range(30):
    request["id"] = run + 2
    elapsed, _, response = call(request)
    result = response["result"]["structuredContent"]
    assert result["results"][0]["status"] == "available"
    if run == 0:
        cold_index_ms = elapsed
    else:
        warm.append(elapsed)

_, audit_response_bytes, audit_response = call({
    "jsonrpc": "2.0",
    "id": 32,
    "method": "tools/call",
    "params": {
        "name": "audit_primitives",
        "arguments": {
            "target_project": ".",
            "primitives": [
                {"id": "weekday", "need": "calculate a weekday", "search_terms": ["day_of_week"]},
                {"id": "json", "need": "encode JSON values", "search_terms": ["json.Value", "json.marshal"]},
                {"id": "allocate", "need": "allocate temporary arrays", "search_terms": ["make", "append"]},
                {"id": "time", "need": "read time values", "search_terms": ["time.now", "time"]},
                {"id": "string", "need": "join string values", "search_terms": ["strings.join", "join"]},
            ],
        },
    },
})
assert sum(
    len(result["matches"])
    for result in audit_response["result"]["structuredContent"]["results"]
) == 40
_, lookup_response_bytes, _ = call({
    "jsonrpc": "2.0",
    "id": 33,
    "method": "tools/call",
    "params": {
        "name": "lookup_symbols",
        "arguments": {"queries": [{"query": "greet"}, {"query": "run"}]},
    },
})
process.stdin.close()
process.wait()

odin_root = subprocess.check_output(
    ["hw-odin", "toolchain", "root"], text=True
).strip()
regular = []
for _ in range(30):
    started = time.perf_counter_ns()
    result = subprocess.run(
        ["rg", "-n", r"^day_of_week\s*::", odin_root + "/core"],
        stdout=subprocess.DEVNULL,
    )
    assert result.returncode == 0
    regular.append((time.perf_counter_ns() - started) / 1e6)

report = {
    "runs": 30,
    "cold_catalog_build_ms": cold_index_ms,
    "mcp_warm_median_ms": statistics.median(warm),
    "rg_core_median_ms": statistics.median(regular),
    "median_speedup": statistics.median(regular) / statistics.median(warm),
    "tools_list_response_bytes": tools_list_bytes,
    "audit_40_match_response_bytes": audit_response_bytes,
    "lookup_two_query_response_bytes": lookup_response_bytes,
    "usage_database_bytes": os.path.getsize(os.environ["HW_ODIN_ANALYZE_USAGE_DB"]),
    "usage_event_count": sqlite3.connect(
        os.environ["HW_ODIN_ANALYZE_USAGE_DB"]
    ).execute("SELECT COUNT(*) FROM mcp_events").fetchone()[0],
}
print(json.dumps(report, indent=2))
assert report["median_speedup"] > 1
assert report["tools_list_response_bytes"] <= 4500
assert report["audit_40_match_response_bytes"] <= 15000
assert report["lookup_two_query_response_bytes"] <= 1000
PY
