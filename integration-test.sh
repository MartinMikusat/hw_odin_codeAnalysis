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
