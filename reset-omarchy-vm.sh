#!/usr/bin/env bash
# ==============================================================================
# Backward-compatibility wrapper for reset-omarchy-vm.sh
# Preserves old arguments: /path/to/omarchy.iso and --finish
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -eq 1 ] && [ "$1" = "--finish" ]; then
  exec "$SCRIPT_DIR/omarchy" setup --finish
elif [ $# -eq 1 ] && [ "$1" != "-h" ] && [ "$1" != "--help" ] && [ -f "$1" ]; then
  exec "$SCRIPT_DIR/omarchy" reset --iso "$1"
else
  exec "$SCRIPT_DIR/omarchy" reset "$@"
fi
