#!/usr/bin/env bash
# ==============================================================================
# One-command setup entry point: delegates to omarchy setup
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/omarchy" setup "$@"
