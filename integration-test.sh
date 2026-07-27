#!/usr/bin/env bash
set -euo pipefail

root="tests/fixtures/workspace"
analyzer=(./build/hw-odin-analyze --root "$root" --compact)
failure_root=""
failure_analyzer=()
dependency_root=""
dependency_analyzer=()

cleanup() {
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
}
trap cleanup EXIT

cleanup

status="$("${analyzer[@]}" status)"
[[ "$status" == *'"persistent":true'* ]]

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
