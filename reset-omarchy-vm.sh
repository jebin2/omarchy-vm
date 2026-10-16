#!/usr/bin/env bash
set -euo pipefail

# Replace the Omarchy VM's guest disk and boot an installer ISO.
# The old disk is moved aside as a timestamped backup before the fresh disk is made.

URI="qemu:///session"
DOMAIN="omarchy-vm"
DISK_SIZE="40G"

usage() {
  echo "usage: $0 /path/to/omarchy.iso | --finish"
  echo "  ISO path  Replace the guest disk (with backup), boot installer, open viewer."
  echo "  --finish  Eject the installer ISO persistently and boot the installed system."
}

for tool in virsh qemu-img python3; do
  command -v "$tool" >/dev/null || { echo "missing required command: $tool" >&2; exit 1; }
done

virsh -c "$URI" dominfo "$DOMAIN" >/dev/null || {
  echo "libvirt domain '$DOMAIN' not found on $URI" >&2
  exit 1
}

if [[ $# -eq 1 && "$1" == "--finish" ]]; then
  STATE="$(virsh -c "$URI" domstate "$DOMAIN" 2>/dev/null || true)"
  if [[ "$STATE" == running* ]]; then
    virsh -c "$URI" shutdown "$DOMAIN" >/dev/null || true
    for _ in $(seq 1 30); do
      [[ "$(virsh -c "$URI" domstate "$DOMAIN" 2>/dev/null || true)" == "shut off" ]] && break
      sleep 1
    done
  fi
  [[ "$(virsh -c "$URI" domstate "$DOMAIN" 2>/dev/null || true)" == "shut off" ]] || {
    echo "VM did not shut down; refusing to alter its boot media." >&2
    exit 1
  }
  virsh -c "$URI" change-media "$DOMAIN" sda --eject --config
  virsh -c "$URI" start "$DOMAIN"
  if command -v virt-viewer >/dev/null; then
    nohup virt-viewer -c "$URI" -f -a "$DOMAIN" >/dev/null 2>&1 &
  else
    echo "VM started. Install virt-viewer to open its SPICE display."
  fi
  echo "ISO ejected from the saved VM configuration; booted from the guest disk."
  exit 0
fi

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
ISO="$(realpath "$1")"
[[ -f "$ISO" && -r "$ISO" ]] || { echo "ISO not readable: $ISO" >&2; exit 1; }

VM_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_DIR="$VM_DIR/images"
DISK="$IMAGE_DIR/omarchy.qcow2"
mkdir -p "$IMAGE_DIR"

echo "This resets $DOMAIN to a new $DISK_SIZE disk and boots: $ISO"
echo "The current virtual disk will be moved to a dated backup in $IMAGE_DIR."
read -r -p "Type RESET to continue: " ANSWER
[[ "$ANSWER" == RESET ]] || { echo "Cancelled."; exit 0; }

STATE="$(virsh -c "$URI" domstate "$DOMAIN" 2>/dev/null || true)"
if [[ "$STATE" == running* ]]; then
  virsh -c "$URI" shutdown "$DOMAIN" >/dev/null || true
  for _ in $(seq 1 30); do
    [[ "$(virsh -c "$URI" domstate "$DOMAIN" 2>/dev/null || true)" == "shut off" ]] && break
    sleep 1
  done
  [[ "$(virsh -c "$URI" domstate "$DOMAIN" 2>/dev/null || true)" == "shut off" ]] || {
    echo "VM did not shut down; refusing to replace its disk." >&2
    exit 1
  }
fi

XML="$IMAGE_DIR/omarchy-vm-reset.xml"
virsh -c "$URI" dumpxml --inactive "$DOMAIN" > "$XML"

# Keep the VM's existing CPU, display, network, and graphics configuration.
# The disk is first, so after installation the VM boots the installed system;
# the blank disk falls through to the ISO for the initial installer boot.
python3 - "$XML" "$ISO" "$DISK" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path, iso_path, disk_path = sys.argv[1:]
tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("domain XML has no devices section")

found_disk = found_cdrom = False
for disk in devices.findall("disk"):
    source = disk.find("source")
    if disk.get("device") == "disk":
        found_disk = True
        if source is None:
            source = ET.SubElement(disk, "source")
        source.set("file", disk_path)
        boot = disk.find("boot")
        if boot is not None:
            disk.remove(boot)
        driver = disk.find("driver")
        if driver is None:
            driver = ET.SubElement(disk, "driver")
        driver.set("name", "qemu")
        driver.set("type", "qcow2")
        boot = disk.find("boot")
        if boot is None:
            boot = ET.SubElement(disk, "boot")
        boot.set("order", "1")
    elif disk.get("device") == "cdrom":
        found_cdrom = True
        if source is None:
            source = ET.SubElement(disk, "source")
        source.set("file", iso_path)
        boot = disk.find("boot")
        if boot is None:
            boot = ET.SubElement(disk, "boot")
        boot.set("order", "2")

if not found_disk or not found_cdrom:
    raise SystemExit("domain XML must already have both a disk and CD-ROM device")

# Use SPICE for the interactive display. Keep EGL-headless and virtio-vga-gl
# below so QEMU continues to render with virgl on the host iGPU.
for graphics in devices.findall("graphics"):
    if graphics.get("type") == "vnc":
        graphics.set("type", "spice")
        graphics.set("port", "-1")
        graphics.set("autoport", "yes")
        graphics.set("listen", "127.0.0.1")

# Clipboard sharing with virt-viewer needs a spicevmc channel for the guest's
# spice-vdagent; qemu-vdagent only serves QEMU's own VNC/GTK/D-Bus displays.
for ch in devices.findall("channel"):
    if ch.get("type") in ("qemu-vdagent", "spicevmc"):
        devices.remove(ch)
channel = ET.SubElement(devices, "channel", {"type": "spicevmc"})
ET.SubElement(channel, "target", {"type": "virtio", "name": "com.redhat.spice.0"})

os_node = root.find("os")
if os_node is not None:
    bootdev = os_node.find("boot")
    if bootdev is not None:
        os_node.remove(bootdev)
tree.write(xml_path, encoding="unicode", xml_declaration=True)
PY

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -e "$DISK" ]]; then
  mv -- "$DISK" "$IMAGE_DIR/omarchy.qcow2.pre-reset-$STAMP"
fi

# Clear the saved UEFI variables so the guest starts with fresh firmware state.
NVRAM="$(python3 - "$XML" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
nvram = root.find("./os/nvram")
if nvram is not None and nvram.text:
    print(nvram.text.strip())
PY
)"
if [[ -n "$NVRAM" && -f "$NVRAM" ]]; then
  mv -- "$NVRAM" "$NVRAM.pre-reset-$STAMP"
fi

qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
virsh -c "$URI" undefine "$DOMAIN" --nvram >/dev/null 2>&1 || virsh -c "$URI" undefine "$DOMAIN" >/dev/null
virsh -c "$URI" define "$XML" >/dev/null
# Ensure SSH access is ready for post-install guest setup before first boot.
"$VM_DIR/omarchy-ssh.sh" enable
virsh -c "$URI" start "$DOMAIN"

if command -v virt-viewer >/dev/null; then
  nohup virt-viewer -c "$URI" -f -a "$DOMAIN" >/dev/null 2>&1 &
else
  echo "VM started. Install virt-viewer to open its SPICE display."
fi

# Serve the guest setup script in the background until the installed guest runs it.
PROVISION_LOG="$IMAGE_DIR/provision-guest.log"
pkill -f "$VM_DIR/provision-guest.sh" 2>/dev/null || true
nohup "$VM_DIR/provision-guest.sh" > "$PROVISION_LOG" 2>&1 &

cat <<EOF

The Omarchy installer is booting. Complete installation in the VM window.
On reboot, the installed disk has priority and starts Omarchy automatically.
If the installer keeps returning, run: $0 --finish
The VM uses SPICE with virgl graphics, and SSH forwarding is enabled on host port 2222.
After installing and logging in, run this once in a VM terminal:
    bash <(curl -fsSL http://10.0.2.2:8765/guest-setup.sh)
It sets up SSH (with your host key), the guest agent and clipboard sharing.
The host waits for it in the background; progress: $PROVISION_LOG
Install either theme with its install.sh to apply the software-cursor workaround.
The previous disk backup is:
  $IMAGE_DIR/omarchy.qcow2.pre-reset-$STAMP
EOF
