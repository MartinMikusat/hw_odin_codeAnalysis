#!/usr/bin/env bash
set -euo pipefail

destination="${1:-${HOME}/.local/bin}"

./build.sh
mkdir -p "$destination"
install -m 755 build/hw-odin-analyze "$destination/hw-odin-analyze"

printf 'Installed %s\n' "$destination/hw-odin-analyze"
