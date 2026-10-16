#!/usr/bin/env bash
set -euo pipefail

URI="qemu:///session"
DOMAIN="omarchy-vm"
SHUTDOWN_WAIT="${SHUTDOWN_WAIT:-20}"
GUEST_RESOLUTION="${OMARCHY_GUEST_RESOLUTION:-}"

die() { echo "error: $*" >&2; exit 1; }

state() {
  virsh -c "$URI" domstate "$DOMAIN" || die "cannot query VM state through $URI"
}

wait_shutoff() {
  local n="${1:-$SHUTDOWN_WAIT}" i
  for i in $(seq 1 "$n"); do
    [ "$(state)" = "shut off" ] && return 0
    sleep 1
  done
  return 1
}

start() {
  if [ "$(state)" = "running" ]; then
    echo "omarchy-vm is already running"
  else
    virsh -c "$URI" start "$DOMAIN" >/dev/null
    echo "omarchy-vm started"
  fi
}

agent_up() {
  virsh -c "$URI" qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' >/dev/null 2>&1
}

# Escalating shutdown: guest agent -> ACPI -> force power off.
stop() {
  if [ "$(state)" != "running" ]; then
    echo "omarchy-vm is not running"
    return 0
  fi

  if agent_up; then
    echo "asking omarchy-vm to shut down via guest agent (up to ${SHUTDOWN_WAIT}s)..."
    if virsh -c "$URI" shutdown --mode agent "$DOMAIN" >/dev/null 2>&1 && wait_shutoff; then
      echo "omarchy-vm shut down cleanly (guest agent)"
      return 0
    fi
    echo "guest agent shutdown did not complete; falling back to ACPI"
  else
    echo "guest agent not responding; using ACPI"
  fi

  echo "asking omarchy-vm to shut down via ACPI (up to ${SHUTDOWN_WAIT}s)..."
  if virsh -c "$URI" shutdown --mode acpi "$DOMAIN" >/dev/null 2>&1 && wait_shutoff; then
    echo "omarchy-vm shut down cleanly (ACPI)"
    return 0
  fi

  echo "guest did not respond; forcing power off"
  virsh -c "$URI" destroy "$DOMAIN" >/dev/null
  echo "omarchy-vm forced off"
}

force_stop() {
  if [ "$(state)" = "running" ]; then
    virsh -c "$URI" destroy "$DOMAIN" >/dev/null
    echo "omarchy-vm forced off"
  else
    echo "omarchy-vm is not running"
  fi
}

# Largest enabled host output, e.g. "1920x1200".
host_resolution() {
  # kscreen-doctor colourises its output, so strip ANSI escapes before matching.
  kscreen-doctor -o 2>/dev/null \
    | sed -e 's/\x1b\[[0-9;]*m//g' \
          -n -e 's/.*Geometry:[[:space:]]*[0-9]*,[0-9]*[[:space:]]*\([0-9]*x[0-9]*\).*/\1/p' \
    | sort -t x -k1,1n -k2,2n | tail -1
}

GUEST_USER="${OMARCHY_GUEST_USER:-jebin}"
FIT_WAIT="${FIT_WAIT:-240}"

# Match the guest's screen to a resolution (default: the host's) through the guest
# agent. Applies it live and saves it in the guest's monitors.lua, so the next boot
# starts at that size. With --wait, first waits up to FIT_WAIT seconds for the
# guest to boot (agent up) and for Hyprland to start.
fit_guest_screen() {
  local res="" wait="" a i
  for a in "$@"; do
    case "$a" in --wait) wait=1 ;; "") ;; *) res="$a" ;; esac
  done
  res="${res:-${GUEST_RESOLUTION:-$(host_resolution)}}"
  [ -n "$res" ] || { echo "cannot determine the host resolution" >&2; return 1; }
  if ! agent_up; then
    [ -n "$wait" ] || { echo "guest agent not responding; cannot resize the guest screen" >&2; return 1; }
    for i in $(seq 1 "$FIT_WAIT"); do agent_up && break; sleep 1; done
    agent_up || { echo "guest agent did not come up within ${FIT_WAIT}s" >&2; return 1; }
  fi
  local line="hl.monitor({ output = \"Virtual-1\", mode = \"${res}@60\", position = \"0x0\", scale = 1 }) -- omarchy-vm-host-res"
  # Runs in the guest as the desktop user. The managed line goes last so it
  # follows the wildcard monitor rule; Hyprland reloads the file on change.
  local sh="L=\$HOME/.config/hypr/monitors.lua
if [ -f \"\$L\" ]; then sed -i '/omarchy-vm-host-res/d' \"\$L\"; printf '%s\n' '${line}' >> \"\$L\"; fi
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
for i in \$(seq 1 ${FIT_WAIT}); do
  sig=\$(ls -t \"\$XDG_RUNTIME_DIR/hypr\" 2>/dev/null | head -1)
  [ -n \"\$sig\" ] && [ -S \"\$XDG_RUNTIME_DIR/hypr/\$sig/.socket.sock\" ] && break
  sleep 1
done
HYPRLAND_INSTANCE_SIGNATURE=\$sig hyprctl eval 'hl.monitor({ output = \"Virtual-1\", mode = \"${res}@60\", position = \"0x0\", scale = 1 })'"
  local json
  json=$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":"/usr/bin/runuser","arg":["-u",sys.argv[1],"--","/bin/bash","-lc",sys.argv[2]],"capture-output":True}}))' "$GUEST_USER" "$sh")
  virsh -c "$URI" qemu-agent-command "$DOMAIN" "$json" >/dev/null 2>&1 \
    || { echo "guest agent rejected the resize command" >&2; return 1; }
  echo "guest screen set to $res (saved for next boot)"
}

open_viewer() {
  if [ "$(state)" != "running" ]; then
    die "omarchy-vm is not running; start it first"
  fi
  # Resize in the background: right away if the guest is up, otherwise once it boots.
  nohup "$0" fit --wait >/dev/null 2>&1 &
  command -v virt-viewer >/dev/null 2>&1 || die "SPICE display requires virt-viewer; install it with: sudo pacman -S virt-viewer"
  echo "opening virt-viewer (fullscreen; ctrl+alt+f to leave, ctrl+alt+g to release the pointer)"
  nohup virt-viewer -c "$URI" -f -a "$DOMAIN" >/dev/null 2>&1 &
}

usage() {
  cat <<EOF
usage: omarchy-control <command>

commands:
  start        boot the VM
  stop         graceful shutdown
  force-stop   force power off
  open         open the VM screen in virt-viewer (SPICE)
  fit [RES]    resize the guest screen to the host resolution (or RES, e.g. 1600x900)
               and save it for the next boot; add --wait to wait for the guest to boot
  up           start and open the viewer
  down         graceful shutdown
  toggle       start/open if off, else stop
  status       print VM state
EOF
}

cmd="${1:-}"
case "$cmd" in
  start)      start ;;
  stop)       stop ;;
  down)       stop ;;
  force-stop) force_stop ;;
  open)       open_viewer ;;
  fit)        shift; fit_guest_screen "$@" ;;
  up)         start; sleep 2; open_viewer ;;
  toggle)     if [ "$(state)" = "running" ]; then stop; else start; sleep 3; open_viewer; fi ;;
  status)     echo "$(state)" ;;
  *)          usage; [ -z "$cmd" ] || { [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ]; } || die "unknown command: $cmd" ;;
esac
