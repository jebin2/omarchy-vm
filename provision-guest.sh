#!/usr/bin/env bash
# ==============================================================================
# Compatibility wrapper: delegates to omarchy provision
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/omarchy" provision "$@"
