#!/usr/bin/env bash
set -euo pipefail

if ! command -v hyperfine >/dev/null; then
  printf 'hyperfine is required\n' >&2
  exit 1
fi

root="tests/fixtures/workspace"
analyzer=(./build/hw-odin-analyze --root "$root" --compact)
benchmark_command="./build/hw-odin-analyze --root $root --compact"

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
    response = json.loads(process.stdout.readline())
    return (time.perf_counter_ns() - started) / 1e6, response

call({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}})
request = {
    "jsonrpc": "2.0",
    "id": 1,
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
    request["id"] = run + 1
    elapsed, response = call(request)
    result = response["result"]["structuredContent"]
    assert result["results"][0]["status"] == "available"
    cold_index_ms = result["last_rebuild_nanoseconds"] / 1e6
    warm.append(elapsed)
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
}
print(json.dumps(report, indent=2))
assert report["median_speedup"] > 1
PY
