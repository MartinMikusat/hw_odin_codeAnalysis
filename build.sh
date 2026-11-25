#!/usr/bin/env bash
set -euo pipefail

odin_command="hw-odin"
mkdir -p build
build_commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  build_commit="$build_commit-dirty"
fi
"$odin_command" build cmd/hw-odin-analyze \
  -collection:code_analysis=src \
  -define:HW_BUILD="$build_commit" \
  -out:build/hw-odin-analyze \
  -o:speed \
  -strict-style
