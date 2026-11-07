#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
exec "${T3PT_NODE:-node}" tools/linux.mjs uninstall "$@"
