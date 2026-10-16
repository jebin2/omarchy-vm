#!/usr/bin/env bash
set -euo pipefail

# Serve guest-setup.sh to the Omarchy guest and wait until it has run.
# SLIRP maps the guest's 10.0.2.2 to the host's loopback, so the server binds
# 127.0.0.1 only and is not reachable from the network.

URI="qemu:///session"
DOMAIN="omarchy-vm"
PORT="${OMARCHY_PROVISION_PORT:-8765}"
SSH_PORT="${OMARCHY_SSH_PORT:-2222}"
GUEST_USER="${OMARCHY_SSH_USER:-jebin}"
TIMEOUT="${OMARCHY_PROVISION_TIMEOUT:-10800}"   # 3h: covers a full install
VM_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { echo "[provision] $*"; }
die() { echo "error: $*" >&2; exit 1; }

command -v python3 >/dev/null || die "missing required command: python3"
PUBKEY=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -f "$k" ] && { PUBKEY="$k"; break; }
done
[ -n "$PUBKEY" ] || die "no SSH public key in ~/.ssh; create one with: ssh-keygen -t ed25519"

SERVE_DIR="$(mktemp -d)"
cp "$VM_DIR/guest-setup.sh" "$SERVE_DIR/guest-setup.sh"
cp "$PUBKEY" "$SERVE_DIR/authorized_key"
cp "$VM_DIR/vm-clipboard-bridge" "$VM_DIR/vm-clipboard-bridge.service" "$SERVE_DIR/"
ACCESS_LOG="$SERVE_DIR/.access.log"
python3 -m http.server --bind 127.0.0.1 --directory "$SERVE_DIR" "$PORT" >"$ACCESS_LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$SERVE_DIR"' EXIT
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || die "could not serve on 127.0.0.1:$PORT (port in use?)"

cat <<EOF
[provision] After Omarchy is installed and you are logged in, open a terminal in the VM and run:

    bash <(curl -fsSL http://10.0.2.2:$PORT/guest-setup.sh)

[provision] It sets up SSH, the guest agent and clipboard sharing. Waiting for it to finish...
EOF

ssh_up() {
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "$GUEST_USER@127.0.0.1" true 2>/dev/null
}
agent_up() {
  virsh -c "$URI" qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' >/dev/null 2>&1
}

deadline=$(( $(date +%s) + TIMEOUT ))
fetched=""
start=$(date +%s)
until ssh_up && agent_up; do
  now=$(date +%s)
  [ "$now" -lt "$deadline" ] || die "timed out after ${TIMEOUT}s waiting for the guest setup"
  if [ -z "$fetched" ] && grep -q 'GET /guest-setup.sh' "$ACCESS_LOG" 2>/dev/null; then
    fetched=1
    say "guest downloaded the setup script; it is installing packages (watch the VM terminal)..."
  elif [ -z "$fetched" ]; then
    say "still waiting for the VM to run the command above ($(( (now - start) / 60 )) min) - Ctrl+C to stop"
  fi
  sleep 10
done
say "SSH and guest agent are up: ssh -p $SSH_PORT $GUEST_USER@127.0.0.1"
"$VM_DIR/omarchy-control.sh" fit --wait | sed 's/^/[provision] /' || say "could not match the guest screen to the host"

if virsh -c "$URI" dumpxml "$DOMAIN" | grep -A2 "channel type='spicevmc'" | grep -q "state='connected'"; then
  say "clipboard channel connected - copy/paste works in virt-viewer"
elif virsh -c "$URI" dumpxml "$DOMAIN" | grep -q "channel type='spicevmc'"; then
  say "clipboard channel present but not connected yet; log out/in of the VM desktop if paste fails"
else
  say "this boot predates the clipboard channel: run omarchy-control.sh stop, then up"
fi
