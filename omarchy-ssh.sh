#!/usr/bin/env bash
# Compatibility wrapper: maps the old omarchy-ssh.sh interface onto `omarchy`.
# SSH forwarding (127.0.0.1:$OMARCHY_SSH_PORT -> guest:22) is now always part of
# the generated domain XML, so enable/disable no longer edit the VM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY="$SCRIPT_DIR/omarchy"

cmd="ssh"
restart=0
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user)  export OMARCHY_GUEST_USER="$2"; shift 2 ;;
    -p|--port)  export OMARCHY_SSH_PORT="$2"; shift 2 ;;
    -b|--bind|-g|--guest-port|-m|--mac)
                echo "[omarchy-ssh] $1 is no longer supported; ignoring" >&2; shift 2 ;;
    --restart)  restart=1; shift ;;
    enable|on|disable|off|status|ssh|connect|restart|help|-h|--help)
                cmd="$1"; shift ;;
    --)         shift; break ;;
    *)          break ;;
  esac
done

case "$cmd" in
  enable|on)
    echo "[omarchy-ssh] SSH forwarding is always enabled (host port ${OMARCHY_SSH_PORT:-2222})."
    [ "$restart" -eq 1 ] && { "$OMARCHY" stop; "$OMARCHY" start; }
    exit 0 ;;
  disable|off)
    echo "[omarchy-ssh] Disabling SSH forwarding is no longer supported; it is bound to 127.0.0.1 only." >&2
    exit 1 ;;
  status)   exec "$OMARCHY" status ;;
  restart)  "$OMARCHY" stop; exec "$OMARCHY" start ;;
  help|-h|--help)
    echo "usage: $0 [enable|status|restart|ssh] [-u USER] [-p PORT] [ssh args...]"
    echo "Deprecated: use 'omarchy ssh' / 'omarchy status' instead."
    exit 0 ;;
  *)        exec "$OMARCHY" ssh "$@" ;;
esac
