#!/usr/bin/env bash
# ==============================================================================
# guest/setup.sh — In-Guest Automatic Provisioner
# ==============================================================================
# Executed inside the Omarchy guest desktop:
#   bash <(curl -fsSL http://10.0.2.2:8765)
# Configures SSH, guest agent, clipboard bridge, and cursor fix.
# ==============================================================================
set -euo pipefail

HOST_URL="${HOST_URL:-http://10.0.2.2:8765}"
say() { echo "[guest-setup] $*"; }

[ "$(id -u)" -ne 0 ] || { echo "error: run as your normal user, not root" >&2; exit 1; }

# System updates. Omarchy's pacman hook rejects a direct full upgrade, so go
# through `omarchy update`; prompts read from the terminal so a piped
# `curl | bash` cannot have the rest of this script swallowed as input.
# Never `pacman -Sy` alone: syncing without upgrading is an unsupported partial upgrade.
# OMARCHY_VM_UNATTENDED=1 is set when the host drives this over SSH (no terminal).
if command -v omarchy >/dev/null 2>&1 && [ "${OMARCHY_VM_UNATTENDED:-}" = "1" ]; then
  say "Updating system via omarchy update -y..."
  omarchy update -y </dev/null || say "omarchy update failed; continuing with package install"
elif command -v omarchy >/dev/null 2>&1; then
  say "Updating system via omarchy update (decline any reboot until this finishes)..."
  omarchy update </dev/tty || say "omarchy update failed; continuing with package install"
else
  say "Updating system..."
  sudo pacman -Syu --noconfirm
fi

say "Installing guest tools and virtualization packages..."
sudo pacman -S --needed --noconfirm openssh qemu-guest-agent spice-vdagent xorg-xwayland \
  wl-clipboard xclip clipnotify

say "Enabling sshd, qemu-guest-agent, and spice-vdagentd..."
sudo systemctl enable --now sshd.service qemu-guest-agent.service spice-vdagentd.socket

# UFW rule for host SSH over QEMU SLIRP
if command -v ufw >/dev/null 2>&1; then
  say "Configuring firewall for host access..."
  sudo ufw allow from 10.0.2.2 to any port 22 proto tcp comment "host ssh via qemu slirp" 2>/dev/null || true
fi

# Authorize host SSH public key
say "Authorizing host SSH key..."
install -d -m 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
key="$(curl -fsSL "$HOST_URL/authorized_key")" || {
  echo "error: failed to fetch host SSH key from $HOST_URL/authorized_key" >&2
  exit 1
}
[ -n "$key" ] || { echo "error: fetched host SSH key is empty" >&2; exit 1; }
grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"

# Install clipboard bridge
say "Installing X11 <-> Wayland clipboard bridge..."
curl -fsSL "$HOST_URL/clipboard-bridge" -o /tmp/clipboard-bridge
curl -fsSL "$HOST_URL/clipboard-bridge.service" -o /tmp/clipboard-bridge.service

install -Dm755 /tmp/clipboard-bridge "$HOME/.local/bin/vm-clipboard-bridge"
install -Dm644 /tmp/clipboard-bridge.service "$HOME/.config/systemd/user/vm-clipboard-bridge.service"
systemctl --user daemon-reload
systemctl --user enable vm-clipboard-bridge.service
systemctl --user restart vm-clipboard-bridge.service || true
# Start the SPICE session agent now (installed mid-session, so nothing launched it yet).
systemctl --user start spice-vdagent.service || say "spice-vdagent starts with the next graphical login"

# Apply software cursor workaround for SPICE display
LOOKNFEEL="$HOME/.config/hypr/looknfeel.lua"
if [ -f "$LOOKNFEEL" ]; then
  if ! grep -Eq 'no_hardware_cursors[[:space:]]*=[[:space:]]*true' "$LOOKNFEEL" 2>/dev/null; then
    say "Enabling software cursor plane workaround..."
    printf '\n-- QEMU virtio-gpu cursor plane workaround for SPICE.\nhl.config({ cursor = { no_hardware_cursors = true } })\n' >> "$LOOKNFEEL"
  fi
  hyprctl reload >/dev/null 2>&1 || true
fi

# Unencrypted installs stop at the SDDM login screen; inside a VM window that is
# one password too many, so log straight in like an encrypted install does.
if [ "${OMARCHY_VM_UNATTENDED:-}" = "1" ] && [ ! -f /etc/sddm.conf.d/autologin.conf ]; then
  say "Enabling desktop autologin..."
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$USER" \
    | sudo install -Dm644 /dev/stdin /etc/sddm.conf.d/autologin.conf
fi

# Notify host provisioner
say "Registering user ($USER) with host..."
curl -fsSL "$HOST_URL/done?user=$USER" || {
  echo "error: failed to notify host provisioner at $HOST_URL/done" >&2
  exit 1
}

say "Omarchy VM guest onboarding complete!"
