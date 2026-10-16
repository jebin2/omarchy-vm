#!/usr/bin/env bash
# Compatibility wrapper: delegates to guest/setup.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/guest/setup.sh" "$@"
