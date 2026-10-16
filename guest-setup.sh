#!/usr/bin/env bash
# Run INSIDE the Omarchy guest (as your user, not root). Served by the host's
# provision-guest.sh; normally started with:
#   bash <(curl -fsSL http://10.0.2.2:8765/guest-setup.sh)
# Sets up everything the host scripts rely on: SSH with the host's key, the QEMU
# guest agent (clean shutdown, screen fit), and SPICE clipboard sharing.
# Safe to re-run.
set -euo pipefail

HOST_URL="${HOST_URL:-http://10.0.2.2:8765}"
say() { echo "[guest-setup] $*"; }

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }

# Omarchy's pacman hook rejects a direct `pacman -Syu`; full upgrades must go
# through `omarchy update` (snapshot, keyrings, migrations). Once the system is
# current, a plain `pacman -S` installs the guest packages without a partial upgrade.
if command -v omarchy >/dev/null; then
  say "updating the system through omarchy update (answer its prompts; decline any reboot until this finishes)..."
  omarchy update
else
  sudo pacman -Syu --noconfirm
fi
say "installing guest services..."
sudo pacman -S --needed --noconfirm openssh qemu-guest-agent spice-vdagent xorg-xwayland \
  wl-clipboard xclip clipnotify

say "enabling sshd, qemu-guest-agent and spice-vdagentd..."
sudo systemctl enable --now sshd.service qemu-guest-agent.service spice-vdagentd.socket

# Omarchy's ufw drops inbound SSH. QEMU's SLIRP forward arrives from 10.0.2.2,
# so allow only that source.
if command -v ufw >/dev/null; then
  say "allowing SSH from the host through ufw..."
  sudo ufw allow from 10.0.2.2 to any port 22 proto tcp comment "host ssh via qemu slirp"
fi

say "authorizing the host's SSH key..."
install -d -m 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
key="$(curl -fsSL "$HOST_URL/authorized_key")"
grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"

# The spice-vdagent package's own user service starts with the session on
# XWayland (DISPLAY=:0), so host<->guest clipboard data lands in the X11
# clipboard. Hyprland does not reliably mirror that to Wayland apps, so a small
# bridge service keeps the two clipboards in sync.
say "installing the X11<->Wayland clipboard bridge..."
curl -fsSL "$HOST_URL/vm-clipboard-bridge" -o /tmp/vm-clipboard-bridge
curl -fsSL "$HOST_URL/vm-clipboard-bridge.service" -o /tmp/vm-clipboard-bridge.service
install -Dm755 /tmp/vm-clipboard-bridge "$HOME/.local/bin/vm-clipboard-bridge"
install -Dm644 /tmp/vm-clipboard-bridge.service "$HOME/.config/systemd/user/vm-clipboard-bridge.service"
systemctl --user daemon-reload
systemctl --user enable vm-clipboard-bridge.service
systemctl --user restart vm-clipboard-bridge.service || \
  say "clipboard bridge starts with the next graphical login"

# QEMU's virtio-gpu hardware cursor plane is invisible through SPICE; have
# Hyprland draw the cursor in software (same fix the theme installers apply).
LOOKNFEEL="$HOME/.config/hypr/looknfeel.lua"
if [ -f "$LOOKNFEEL" ] && ! grep -Eq 'no_hardware_cursors[[:space:]]*=[[:space:]]*true' "$LOOKNFEEL"; then
  say "enabling the software cursor for the SPICE display..."
  printf '\n-- QEMU virtio-gpu cursor plane workaround for SPICE.\nhl.config({ cursor = { no_hardware_cursors = true } })\n' >> "$LOOKNFEEL"
  hyprctl reload >/dev/null 2>&1 || true
fi

say "done. SSH: ssh -p 2222 $USER@127.0.0.1 (from the host)"
