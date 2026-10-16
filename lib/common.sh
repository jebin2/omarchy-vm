#!/usr/bin/env bash
# ==============================================================================
# lib/common.sh — Shared Constants & Output Helpers
# ==============================================================================
set -euo pipefail

# Directory paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
GUEST_DIR="$ROOT_DIR/guest"
IMAGE_DIR="$ROOT_DIR/images"

# Global VM configuration
URI="${OMARCHY_URI:-qemu:///session}"
DOMAIN="${OMARCHY_DOMAIN:-omarchy-vm}"
DISK="$IMAGE_DIR/omarchy.qcow2"
DISK_SIZE="${OMARCHY_DISK_SIZE:-40G}"
NVRAM_PATH="$IMAGE_DIR/omarchy-vm_VARS.fd"
DOMAIN_XML="$IMAGE_DIR/omarchy-vm.xml"
GUEST_USER_FILE="$IMAGE_DIR/.guest_user"

SSH_PORT="${OMARCHY_SSH_PORT:-2222}"
PROVISION_PORT="${OMARCHY_PROVISION_PORT:-8765}"
PROVISION_TIMEOUT="${OMARCHY_PROVISION_TIMEOUT:-10800}"
SHUTDOWN_WAIT="${SHUTDOWN_WAIT:-20}"
FIT_WAIT="${FIT_WAIT:-240}"

# ANSI Colors
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

say()  { echo -e "${BLUE}[omarchy]${NC} $*"; }
ok()   { echo -e "${GREEN}[   ok  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[  warn ]${NC} $*"; }
die()  { echo -e "${RED}[ error ]${NC} $*" >&2; exit 1; }

resolve_guest_user() {
  if [ -n "${OMARCHY_GUEST_USER:-}" ]; then
    echo "$OMARCHY_GUEST_USER"
  elif [ -f "$GUEST_USER_FILE" ]; then
    cat "$GUEST_USER_FILE" | tr -d '[:space:]'
  else
    echo "$USER"
  fi
}
