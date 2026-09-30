#!/usr/bin/env bash
set -euo pipefail

odin_command="hw-odin"
"$odin_command" test tests -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
  -collection:code_analysis=src \
  -define:ODIN_TEST_THREADS=1 \
  -strict-style

./build.sh
./integration-test.sh
