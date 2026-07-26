#!/usr/bin/env bash
set -euo pipefail

odin_command="${ODIN:-odin}"
"$odin_command" test tests \
  -collection:code_analysis=src \
  -define:ODIN_TEST_THREADS=1 \
  -strict-style
