#!/usr/bin/env bash
set -euo pipefail

odin_command="${ODIN:-odin}"
mkdir -p build
"$odin_command" build cmd/hw-odin-analyze \
  -collection:code_analysis=src \
  -out:build/hw-odin-analyze \
  -o:speed \
  -strict-style
