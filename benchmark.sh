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
