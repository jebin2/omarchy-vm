#!/usr/bin/env bash
set -euo pipefail

URI="qemu:///session"
DOMAIN="omarchy-vm"
VM_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_DIR="$VM_DIR/images"

command -v virsh >/dev/null || { echo "missing required command: virsh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "missing required command: python3" >&2; exit 1; }
virsh -c "$URI" dominfo "$DOMAIN" >/dev/null || {
  echo "cannot access VM '$DOMAIN' through $URI" >&2
  exit 1
}

mkdir -p "$IMAGE_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
XML="$IMAGE_DIR/omarchy-vm-clipboard-$STAMP.xml"
virsh -c "$URI" dumpxml --inactive "$DOMAIN" > "$XML"

python3 - "$XML" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("domain XML has no devices section")

# The VM display is SPICE (virt-viewer). qemu-vdagent only serves QEMU's own
# VNC/GTK/D-Bus displays, so SPICE needs a spicevmc channel for the guest agent.
for ch in devices.findall("channel"):
    if ch.get("type") in ("qemu-vdagent", "spicevmc"):
        devices.remove(ch)
channel = ET.SubElement(devices, "channel", {"type": "spicevmc"})
ET.SubElement(channel, "target", {"type": "virtio", "name": "com.redhat.spice.0"})

tree.write(path, encoding="unicode", xml_declaration=True)
PY

virsh -c "$URI" define "$XML" >/dev/null
echo "Clipboard channel enabled in the saved VM config. It takes effect on the next VM boot."
echo "Inside Omarchy, install the guest clipboard agent:"
echo "  sudo pacman -S --needed spice-vdagent xorg-xwayland"
echo "  sudo systemctl enable --now spice-vdagentd.socket"
echo "spice-vdagent has no native Wayland clipboard; run it on XWayland from Hyprland:"
echo "  echo 'exec-once = spice-vdagent -x' >> ~/.config/hypr/autostart.conf"
echo "Then fully shut down the VM (not just reboot), start it, and connect with virt-viewer."
