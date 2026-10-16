#!/usr/bin/env bash
set -euo pipefail

URI="${OMARCHY_URI:-qemu:///session}"
DOMAIN="${OMARCHY_DOMAIN:-omarchy-vm}"
HOST_ADDR="${OMARCHY_SSH_BIND:-127.0.0.1}"
HOST_PORT="${OMARCHY_SSH_PORT:-2222}"
GUEST_PORT="${OMARCHY_SSH_GUEST_PORT:-22}"
GUEST_USER="${OMARCHY_SSH_USER:-jebin}"
MAC="${OMARCHY_SSH_MAC:-52:54:00:aa:bb:cc}"
NETDEV_ID="hostnet0"
DEVICE_ID="net0"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "[omarchy-ssh] $*"; }

RESTART=""
CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)        HOST_PORT="$2"; shift 2 ;;
    -b|--bind)        HOST_ADDR="$2"; shift 2 ;;
    -g|--guest-port)  GUEST_PORT="$2"; shift 2 ;;
    -u|--user)        GUEST_USER="$2"; shift 2 ;;
    -m|--mac)         MAC="$2"; shift 2 ;;
    --restart)        RESTART=1; shift ;;
    enable|on|disable|off|status|ssh|connect|restart|help)
                      CMD="$1"; shift ;;
    -h|--help)        CMD="help"; shift ;;
    *) die "unknown option/argument: $1" ;;
  esac
done

export HOST_ADDR HOST_PORT GUEST_PORT MAC NETDEV_ID DEVICE_ID

state() {
  virsh -c "$URI" domstate "$DOMAIN" || die "cannot query VM state through $URI"
}

dump() {
  local xml
  xml="$(virsh -c "$URI" dumpxml --inactive "$DOMAIN")" \
    || die "cannot read persistent XML for $DOMAIN through $URI"
  printf '%s\n' "$xml"
}

# Rewrite the libvirt <interface type='user'> NIC as a qemu:commandline netdev,
# adding/removing the SSH hostfwd. Reads the domain XML on stdin, writes on stdout.
py_transform() {
  python3 -c "$(cat <<'PYEOF'
import sys, os, xml.etree.ElementTree as ET

QEMU = "http://libvirt.org/schemas/domain/qemu/1.0"
ET.register_namespace("qemu", QEMU)

mode = sys.argv[1]
host_addr = os.environ["HOST_ADDR"]
host_port = os.environ["HOST_PORT"]
guest_port = os.environ["GUEST_PORT"]
mac = os.environ["MAC"]
netdev_id = os.environ["NETDEV_ID"]
device_id = os.environ["DEVICE_ID"]

tree = ET.parse(sys.stdin)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    sys.exit("no <devices> element found")

# Take over every libvirt-managed interface (there is one NIC in this VM).
for iface in devices.findall("interface"):
    devices.remove(iface)

# Drop any qemu:commandline args we previously generated (idempotent toggling).
for cl in root.findall("{%s}commandline" % QEMU):
    for arg in list(cl.findall("{%s}arg" % QEMU)):
        v = arg.get("value", "")
        if v in ("-netdev", "-device") \
           or v.startswith("user,id=" + netdev_id) \
           or v.startswith("virtio-net-pci,netdev=" + netdev_id):
            cl.remove(arg)
    if len(cl) == 0:
        root.remove(cl)

netdev = "user,id=%s" % netdev_id
if mode == "on":
    netdev += ",hostfwd=tcp:%s:%s-:%s" % (host_addr, host_port, guest_port)
# Place the NIC on a free slot of the root PCIe bus. QEMU command-line devices
# cannot reliably address the libvirt-generated root-port bus by its XML ID.
device = "virtio-net-pci,netdev=%s,id=%s,mac=%s,bus=pcie.0,addr=0x3" % (netdev_id, device_id, mac)

cl = ET.SubElement(root, "{%s}commandline" % QEMU)
for v in ("-netdev", netdev, "-device", device):
    ET.SubElement(cl, "{%s}arg" % QEMU).set("value", v)

try:
    ET.indent(tree, space="  ")
except AttributeError:
    pass
tree.write(sys.stdout, encoding="unicode", xml_declaration=False)
print()
PYEOF
)" "$1"
}

hostfwd_text() {
  local tmp
  tmp="$(mktemp)"
  if ! virsh -c "$URI" dumpxml --inactive "$DOMAIN" > "$tmp"; then
    rm -f -- "$tmp"
    echo "error: cannot read persistent XML for $DOMAIN through $URI" >&2
    return 1
  fi
  grep -oE 'hostfwd=tcp:[^,]*' "$tmp" | head -1 || true
  rm -f -- "$tmp"
}

apply_ssh() {
  local mode="$1" tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if ! dump | py_transform "$mode" > "$tmp"; then
    die "generating the domain XML failed"
  fi
  virsh -c "$URI" define "$tmp" >/dev/null || die "virsh define failed"
  if [ "$(state)" = "running" ]; then
    say "config updated but $DOMAIN is running - takes effect on next boot (use --restart to apply now)"
  else
    say "config updated (SSH port forward: ${mode})"
  fi
}

ssh_status() {
  local hf
  hf="$(hostfwd_text)" || die "cannot determine SSH forwarding configuration"
  if [ -n "$hf" ]; then
    echo "enabled   $hf -> guest:$GUEST_PORT"
    echo "connect   ssh -p $HOST_PORT $GUEST_USER@$HOST_ADDR"
    echo "vm state  $(state)"
  else
    echo "disabled  (no SSH port forward on $DOMAIN)"
    echo "vm state  $(state)"
  fi
}

agent_up() {
  virsh -c "$URI" qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' >/dev/null 2>&1
}

restart_vm() {
  if [ "$(state)" != "running" ]; then
    say "$DOMAIN is not running; nothing to restart"
    return 0
  fi
  say "restarting $DOMAIN to apply the new NIC config..."
  if agent_up; then
    virsh -c "$URI" shutdown --mode agent "$DOMAIN" >/dev/null 2>&1 || true
  else
    virsh -c "$URI" shutdown --mode acpi "$DOMAIN" >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 20); do
    [ "$(state)" = "shut off" ] && break
    sleep 1
  done
  if [ "$(state)" != "shut off" ]; then
    say "guest not stopping; forcing power off"
    virsh -c "$URI" destroy "$DOMAIN" >/dev/null
  fi
  virsh -c "$URI" start "$DOMAIN" >/dev/null
  say "$DOMAIN restarted"
}

cmd_ssh() {
  local hf
  hf="$(hostfwd_text)" || die "cannot determine SSH forwarding configuration"
  if [ -z "$hf" ]; then
    if [ -n "$RESTART" ]; then
      apply_ssh on
      restart_vm
    else
      say "port forward is not enabled; run: $0 enable --restart"
      return 1
    fi
  fi
  if [ "$(state)" != "running" ]; then
    say "$DOMAIN is not running; start it first (omarchy-control.sh up)"
    return 1
  fi
  say "connecting to $DOMAIN..."
  exec ssh -p "$HOST_PORT" "$GUEST_USER@$HOST_ADDR"
}

usage() {
  cat <<EOF
usage: $0 <command> [options]

turn SSH port forwarding to the $DOMAIN guest on/off.
The VM uses SLIRP user-mode NAT, so the host reaches the guest through a
hostfwd on the NIC: host 127.0.0.1:$HOST_PORT -> guest:$GUEST_PORT.

commands:
  enable [--restart]   add the SSH port forward (apply only on next boot)
  disable [--restart]  remove the SSH port forward
  status               show whether the forward is currently set
  ssh [--restart]      ensure forward is on + VM running, then connect
  restart              reboot the VM so pending NIC config takes effect
  help                 this message

options (defaults in parentheses):
  -p, --port PORT       host-side port to forward        ($HOST_PORT)
  -b, --bind ADDR       host address to bind to          ($HOST_ADDR)
  -g, --guest-port PORT guest SSH port                   ($GUEST_PORT)
  -u, --user USER       SSH user into the guest          ($GUEST_USER)
  -m, --mac MAC         NIC MAC address                  ($MAC)
  --restart             also restart the VM after applying
EOF
}

case "$CMD" in
  enable|on)
    hf="$(hostfwd_text)" || die "cannot determine SSH forwarding configuration"
    if [ -n "$hf" ]; then
      say "port forward is already enabled"
    else
      apply_ssh on
    fi
    [ -n "$RESTART" ] && restart_vm
    say "connect with: ssh -p $HOST_PORT $GUEST_USER@$HOST_ADDR"
    say "if the guest refuses, ensure sshd is running inside it: sudo systemctl enable --now sshd"
    ;;
  disable|off)
    hf="$(hostfwd_text)" || die "cannot determine SSH forwarding configuration"
    if [ -z "$hf" ]; then
      say "port forward is already disabled"
    else
      apply_ssh off
    fi
    [ -n "$RESTART" ] && restart_vm || true
    say "SSH port forward removed"
    ;;
  status) ssh_status ;;
  ssh|connect) cmd_ssh ;;
  restart) restart_vm ;;
  help) usage ;;
  *) usage; [ -z "$CMD" ] || { [ "$CMD" = "-h" ]; } || die "unknown command: $CMD" ;;
esac
