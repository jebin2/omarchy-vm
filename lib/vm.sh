#!/usr/bin/env bash
# ==============================================================================
# lib/vm.sh — Libvirt Domain Synthesis & Lifecycle Control
# ==============================================================================
set -euo pipefail

vm_state() {
  local out rc=0
  out="$(virsh -c "$URI" domstate "$DOMAIN" 2>&1)" || rc=$?
  if [ $rc -ne 0 ]; then
    if echo "$out" | grep -qiE "domain.*not found|failed to get domain"; then
      echo "not found"
      return 1
    else
      echo "query error: $out" >&2
      return 2
    fi
  fi
  echo "$out"
}

# True if any trace of a previous VM exists (domain, disk, or NVRAM).
vm_exists() {
  virsh -c "$URI" dominfo "$DOMAIN" >/dev/null 2>&1 || [ -e "$DISK" ] || [ -e "$NVRAM_PATH" ]
}

# Permanently remove the VM: power off, undefine (incl. NVRAM), delete disk and state.
# Dated *.pre-reset-* backups from earlier resets are left alone.
vm_purge() {
  say "Purging existing VM (no backup)..."
  if vm_is_running; then
    virsh -c "$URI" destroy "$DOMAIN" >/dev/null 2>&1 || die "Could not power off '$DOMAIN'; refusing to delete its disk."
  fi
  # A VNC-configured VM means this host already needed the SPICE fallback.
  # Preserve that host-level preference when --reset or delete recreates it.
  if [ "$(vm_graphics_backend 2>/dev/null || true)" = vnc ]; then
    mkdir -p "$IMAGE_DIR"
    : > "$IMAGE_DIR/use-vnc"
  fi
  pkill -f "(^|/)virt-viewer -c .* -a $DOMAIN$" 2>/dev/null || true
  if virsh -c "$URI" dominfo "$DOMAIN" >/dev/null 2>&1; then
    virsh -c "$URI" undefine "$DOMAIN" --nvram >/dev/null 2>&1 \
      || virsh -c "$URI" undefine "$DOMAIN" --keep-nvram >/dev/null 2>&1 \
      || die "Could not undefine domain '$DOMAIN'."
  fi
  rm -f "$DISK" "$NVRAM_PATH" "$GUEST_USER_FILE" "$DOMAIN_XML" "$IMAGE_DIR/cidata.iso" "$IMAGE_DIR/unlock.img"
  ok "Old VM removed (domain, disk, NVRAM, provisioning state)."
}

vm_is_running() {
  local s
  s="$(vm_state 2>/dev/null)" || return 1
  [ "$s" = "running" ]
}

vm_agent_up() {
  virsh -c "$URI" qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' >/dev/null 2>&1
}

# Upgrade domains created by older versions, which explicitly disabled audio.
# PipeWire on the host commonly exposes a PulseAudio-compatible server, so the
# QEMU PulseAudio backend works with both PipeWire and PulseAudio hosts.
vm_enable_audio() {
  local current_xml updated_xml runtime_dir
  runtime_dir="/run/user/$(id -u)"
  current_xml="$(virsh -c "$URI" dumpxml --inactive "$DOMAIN")"
  if ! grep -Eq "<audio[^>]*type=['\"]none['\"]" <<<"$current_xml" \
      && grep -Eq "<qemu:env[^>]*name=['\"]XDG_RUNTIME_DIR['\"]" <<<"$current_xml"; then
    return 0
  fi

  updated_xml="$(python3 -c 'import re,sys; s=sys.stdin.read(); runtime_dir=sys.argv[1]; pattern=r"<audio\b(?=[^>]*\bid=[\x27\"]1[\x27\"])(?=[^>]*\btype=[\x27\"]none[\x27\"])[^>]*/>"; new="<audio id=\"1\" type=\"pulseaudio\" />\n    <sound model=\"ich9\"><audio id=\"1\" /></sound>"; s=re.sub(pattern, lambda _: new, s, count=1); env=r"<qemu:env\b(?=[^>]*\bname=[\x27\"]XDG_RUNTIME_DIR[\x27\"])[^>]*/>"; s=re.sub(env, lambda _: "", s, count=1); s,n=re.subn(r"(<qemu:commandline>)", lambda m: m.group(1)+"\n    <qemu:env name=\"XDG_RUNTIME_DIR\" value=\""+runtime_dir+"\" />", s, count=1); assert n == 1, "QEMU commandline not found"; print(s, end="")' "$runtime_dir" <<<"$current_xml")" \
    || die "Could not prepare the VM audio configuration."
  local xml_file
  xml_file="$(mktemp)"
  printf '%s\n' "$updated_xml" > "$xml_file"
  if ! virsh -c "$URI" define "$xml_file" >/dev/null; then
    rm -f "$xml_file"
    die "Could not enable audio in the VM configuration."
  fi
  rm -f "$xml_file"
  ok "Enabled VM audio (PulseAudio-compatible host output)."
}

# Run a shell script as root in the guest through its agent, optionally feeding
# it STDIN. Prints the script's stdout and returns its exit code (125 when the
# agent itself is unreachable).
vm_agent_sh() {
  python3 - "$URI" "$DOMAIN" "$1" "${2:-}" <<'PY'
import base64, json, subprocess, sys, time
uri, dom, script, stdin = sys.argv[1:5]

def agent(cmd):
    r = subprocess.run(["virsh", "-c", uri, "qemu-agent-command", dom, json.dumps(cmd)],
                       capture_output=True, text=True)
    if r.returncode:
        err = r.stderr.strip() if r.stderr else f"virsh qemu-agent-command failed (code {r.returncode})"
        sys.stderr.write(err + "\n")
        sys.exit(125)
    try:
        data = json.loads(r.stdout)
    except Exception as e:
        sys.stderr.write(f"invalid agent response: {r.stdout}\n")
        sys.exit(125)
    if "error" in data:
        desc = data["error"].get("desc", str(data["error"]))
        sys.stderr.write(f"agent error: {desc}\n")
        sys.exit(125)
    return data.get("return", {})

args = {"path": "/bin/sh", "arg": ["-c", script], "capture-output": True}
if stdin:
    args["input-data"] = base64.b64encode(stdin.encode()).decode()
res = agent({"execute": "guest-exec", "arguments": args})
pid = res.get("pid")
if not pid:
    sys.stderr.write("guest-exec failed: no pid returned\n")
    sys.exit(125)
while not (status := agent({"execute": "guest-exec-status", "arguments": {"pid": pid}})).get("exited"):
    time.sleep(0.2)
sys.stdout.write(base64.b64decode(status.get("out-data", "")).decode(errors="replace"))
sys.stderr.write(base64.b64decode(status.get("err-data", "")).decode(errors="replace"))
sys.exit(status.get("exitcode", 1))
PY
}

vm_close_viewer() {
  pkill -f "(^|/)virt-viewer -c .* -a $DOMAIN$" 2>/dev/null || true
}

vm_start() {
  local s rc=0
  s="$(vm_state 2>/dev/null)" || rc=$?
  if [ $rc -eq 1 ]; then
    die "VM '$DOMAIN' is not defined. Run 'omarchy install' first."
  elif [ $rc -eq 2 ]; then
    die "Cannot connect to hypervisor ($URI). Check your libvirt service."
  elif [ "$s" = "running" ]; then
    say "VM '$DOMAIN' is already running."
  else
    vm_enable_audio
    say "Starting VM '$DOMAIN'..."
    virsh -c "$URI" start "$DOMAIN" >/dev/null
    ok "VM started."
  fi
}

vm_stop() {
  local s rc=0
  s="$(vm_state 2>/dev/null)" || rc=$?
  if [ $rc -eq 1 ]; then
    say "VM '$DOMAIN' is not defined."
    return 0
  elif [ $rc -eq 2 ]; then
    die "Cannot query VM state: $(virsh -c "$URI" domstate "$DOMAIN" 2>&1)"
  fi

  if [ "$s" != "running" ]; then
    say "VM '$DOMAIN' is not running ($s)."
    return 0
  fi

  if vm_agent_up; then
    say "Requesting graceful shutdown via QEMU guest agent..."
    if virsh -c "$URI" shutdown --mode agent "$DOMAIN" >/dev/null 2>&1; then
      for _ in $(seq 1 "$SHUTDOWN_WAIT"); do
        [ "$(vm_state 2>/dev/null || true)" = "shut off" ] && { ok "VM shut down cleanly."; return 0; }
        sleep 1
      done
    fi
    warn "Agent shutdown did not complete in time; trying ACPI..."
  else
    say "Guest agent not responding; sending ACPI poweroff..."
  fi

  if virsh -c "$URI" shutdown --mode acpi "$DOMAIN" >/dev/null 2>&1; then
    for _ in $(seq 1 10); do
      [ "$(vm_state 2>/dev/null || true)" = "shut off" ] && { ok "VM shut down cleanly (ACPI)."; return 0; }
      sleep 1
    done
  fi

  warn "Guest did not respond; forcing power off..."
  virsh -c "$URI" destroy "$DOMAIN" >/dev/null 2>&1 || true
  ok "VM forced off."
}

vm_force_stop() {
  if vm_is_running; then
    virsh -c "$URI" destroy "$DOMAIN" >/dev/null 2>&1 || true
    ok "VM forced off."
  else
    say "VM '$DOMAIN' is not running."
  fi
}

vm_open_viewer() {
  vm_is_running || die "VM is not running. Start it with: omarchy open"
  command -v virt-viewer >/dev/null 2>&1 || die "virt-viewer not installed (sudo pacman -S virt-viewer)"

  if pgrep -f "(^|/)virt-viewer -c .* -a $DOMAIN$" >/dev/null 2>&1; then
    say "Viewer is already open."
    return 0
  fi

  # Schedule auto-fit in background once guest agent boots
  nohup "$ROOT_DIR/omarchy" fit --wait >/dev/null 2>&1 &

  say "Opening VM display in virt-viewer (Fullscreen; Ctrl+Alt+F to toggle)..."
  nohup "$ROOT_DIR/omarchy" _viewer-supervisor >/dev/null 2>&1 &
}

vm_viewer_supervisor() {
  local viewer_log="$IMAGE_DIR/virt-viewer.log" status=0 viewer_pid state connected=0 i
  : > "$viewer_log"

  # The render messages below are emitted by the SPICE client. VNC does not
  # emit them, so sending an already-VNC domain through that timeout would
  # close its working viewer after 30 seconds.
  if [ "$(vm_graphics_backend)" = vnc ]; then
    exec env -u LD_PRELOAD -u LD_LIBRARY_PATH virt-viewer -c "$URI" -f -a "$DOMAIN" >>"$viewer_log" 2>&1
  fi

  env -u LD_PRELOAD -u LD_LIBRARY_PATH virt-viewer --debug --verbose -c "$URI" -f -a "$DOMAIN" >"$viewer_log" 2>&1 &
  viewer_pid=$!

  # The viewer can remain alive on its "connecting" page after the SPICE
  # client has stopped making progress. Treat a rendered display as ready.
  for i in $(seq 1 60); do
    if grep -Eq 'notebook show display|desktop resize' "$viewer_log"; then
      connected=1
      break
    fi
    state="$(ps -o stat= -p "$viewer_pid" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$state" ] || [[ "$state" == Z* ]]; then
      wait "$viewer_pid" || status=$?
      break
    fi
    sleep 0.5
  done

  if [ "$connected" -eq 1 ]; then
    wait "$viewer_pid" || true
    return 0
  fi

  if [ -n "$(ps -o stat= -p "$viewer_pid" 2>/dev/null | tr -d '[:space:]')" ]; then
    printf 'virt-viewer did not render a display within 30 seconds; switching to fallback.\n' >>"$viewer_log"
    kill -TERM "$viewer_pid" 2>/dev/null || true
    wait "$viewer_pid" 2>/dev/null || true
    status=124
  fi

  # Some spice-gtk builds crash or stall while initializing GStreamer. On a
  # failed SPICE startup, switch the saved domain to VNC/standard VGA and retry.
  vm_is_running || return "$status"
  [ "$(vm_graphics_backend)" = spice ] || return "$status"
  printf 'SPICE viewer exited with status %s; retrying with VNC and standard VGA.\n' "$status" >>"$viewer_log"
  vm_switch_to_vnc || die "Could not switch the VM display to VNC. See $viewer_log."
  exec env -u LD_PRELOAD -u LD_LIBRARY_PATH virt-viewer -c "$URI" -f -a "$DOMAIN" >>"$viewer_log" 2>&1
}

vm_graphics_backend() {
  virsh -c "$URI" dumpxml --inactive "$DOMAIN" \
    | python3 -c 'import sys,xml.etree.ElementTree as ET; root=ET.fromstring(sys.stdin.read()); nodes=root.findall("./devices/graphics"); print(next((node.get("type", "") for node in nodes if node.get("type") in {"spice", "vnc"}), ""))'
}

vm_switch_to_vnc() {
  vm_stop

  local xml_file
  xml_file="$(mktemp)"
  if ! virsh -c "$URI" dumpxml --inactive "$DOMAIN" \
      | python3 -c 'import re,sys
s=sys.stdin.read()
graphics=r"<graphics\b(?=[^>]*\btype=[\x27\"]spice[\x27\"])[^>]*>.*?</graphics>"
vnc="<graphics type=\x27vnc\x27 port=\x27-1\x27 autoport=\x27yes\x27 listen=\x27127.0.0.1\x27>\n      <listen type=\x27address\x27 address=\x27127.0.0.1\x27/>\n    </graphics>"
s,n=re.subn(graphics,lambda _:vnc,s,count=1,flags=re.S)
assert n==1,"SPICE graphics block not found"
s,n=re.subn(r"\s*<graphics\b(?=[^>]*\btype=[\x27\"]egl-headless[\x27\"])[^>]*>.*?</graphics>","",s,count=1,flags=re.S)
assert n<=1,"Unexpected number of EGL graphics blocks"
s,n=re.subn(r"\s*<channel\b(?=[^>]*\btype=[\x27\"]spicevmc[\x27\"])[^>]*>.*?</channel>","",s,count=1,flags=re.S)
assert n==1,"SPICE channel not found"
video=r"<video>.*?</video>"
def standard_vga(m):
    address=re.search(r"<address\b[^>]*/>",m.group(0))
    return "<video><model type=\x27vga\x27 heads=\x271\x27 primary=\x27yes\x27/>"+(address.group(0) if address else "")+"</video>"
s,n=re.subn(video,standard_vga,s,count=1,flags=re.S)
assert n==1,"Video device not found"
sys.stdout.write(s)' >"$xml_file"; then
    rm -f "$xml_file"
    return 1
  fi
  if ! virsh -c "$URI" define "$xml_file" >/dev/null; then
    rm -f "$xml_file"
    return 1
  fi
  rm -f "$xml_file"
  # Keep this choice across `omarchy delete`/`omarchy install`. The viewer
  # fallback proved SPICE unusable on this host, so don't make it wait again.
  mkdir -p "$IMAGE_DIR"
  : > "$IMAGE_DIR/use-vnc"
  vm_start
}

vm_connect_ssh() {
  vm_is_running || {
    say "VM is not running; starting it now..."
    vm_start
    sleep 3
  }
  local user="$(resolve_guest_user)"
  say "Connecting via SSH to $user@127.0.0.1:$SSH_PORT..."
  exec ssh -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$user@127.0.0.1" "$@"
}

# Run a command in the guest over SSH (non-interactive).
vm_guest_ssh() {
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$(resolve_guest_user)@127.0.0.1" "$@"
}

# Clipboard health: host SPICE channel, guest agents/bridge, and bridge log.
# With -f/--follow, streams the bridge log live.
vm_clipboard_status() {
  vm_is_running || die "VM is not running. Start it with: omarchy open"
  local follow=0
  case "${1:-}" in -f|--follow) follow=1 ;; esac

  local chan
  chan="$(virsh -c "$URI" dumpxml "$DOMAIN" | grep -A1 "channel type='spicevmc'" | grep -o "state='[a-z]*'" | cut -d"'" -f2 || true)"
  echo "Host SPICE channel:  ${chan:-missing}"
  pgrep -f "(^|/)virt-viewer -c .* -a $DOMAIN$" >/dev/null && echo "virt-viewer:         open" \
    || echo "virt-viewer:         not open (clipboard sharing needs it: omarchy open)"

  local env='export XDG_RUNTIME_DIR=/run/user/$(id -u);'
  vm_guest_ssh "$env"'
    printf "Guest vdagentd:      %s\n" "$(systemctl is-active spice-vdagentd.service)"
    printf "Guest vdagent (X11): %s\n" "$(pgrep -x spice-vdagent >/dev/null && echo running || echo "not running")"
    printf "Guest bridge:        %s\n" "$(systemctl --user is-active vm-clipboard-bridge.service)"
    echo; echo "--- vm-clipboard-bridge log ---"
    journalctl --user -u vm-clipboard-bridge -n 20 --no-pager -o short' \
    || die "Could not reach the guest over SSH."

  if [ "$follow" -eq 1 ]; then
    echo; say "Following bridge log (Ctrl+C to stop); copy something on either side..."
    vm_guest_ssh "$env journalctl --user -u vm-clipboard-bridge -f -n 0 -o short"
  fi
}

vm_fit_resolution() {
  local res="" wait="" a
  for a in "$@"; do
    case "$a" in
      --wait) wait=1 ;;
      "") ;;
      *) res="$a" ;;
    esac
  done

  res="${res:-$(detect_host_resolution)}"
  [ -n "$res" ] || die "Could not determine host resolution."

  if ! vm_agent_up; then
    [ -n "$wait" ] || die "Guest agent not responding; cannot resize screen."
    say "Waiting up to ${FIT_WAIT}s for guest agent to come online..."
    for _ in $(seq 1 "$FIT_WAIT"); do
      vm_agent_up && break
      sleep 1
    done
    vm_agent_up || die "Guest agent did not come online within ${FIT_WAIT}s."
  fi

  local user="$(resolve_guest_user)"
  local line="hl.monitor({ output = \"Virtual-1\", mode = \"${res}@60\", position = \"0x0\", scale = 1 }) -- omarchy-vm-host-res"
  local guest_sh="L=\$HOME/.config/hypr/monitors.lua
if [ -f \"\$L\" ]; then
  sed -i '/omarchy-vm-host-res/d' \"\$L\"
  printf '%s\n' '${line}' >> \"\$L\"
fi
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
for i in \$(seq 1 ${FIT_WAIT}); do
  sig=\$(ls -t \"\$XDG_RUNTIME_DIR/hypr\" 2>/dev/null | head -1)
  [ -n \"\$sig\" ] && [ -S \"\$XDG_RUNTIME_DIR/hypr/\$sig/.socket.sock\" ] && break
  sleep 1
done
HYPRLAND_INSTANCE_SIGNATURE=\$sig hyprctl eval 'hl.monitor({ output = \"Virtual-1\", mode = \"${res}@60\", position = \"0x0\", scale = 1 })'"

  local json
  json=$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":"/usr/bin/runuser","arg":["-u",sys.argv[1],"--","/bin/bash","-lc",sys.argv[2]],"capture-output":True}}))' "$user" "$guest_sh")

  virsh -c "$URI" qemu-agent-command "$DOMAIN" "$json" >/dev/null 2>&1 \
    || die "Guest agent rejected screen resize command."
  ok "Guest screen resolution set to $res (persisted in monitors.lua)."
}

# Path of the ISO currently in the CD-ROM drive, or empty if ejected.
vm_current_iso() {
  virsh -c "$URI" domblklist "$DOMAIN" --details 2>/dev/null \
    | awk '$3 == "sda" && $4 != "-" { print $4; exit }'
}

vm_eject_iso() {
  if [ -z "$(vm_current_iso)" ]; then
    ok "Installer ISO already ejected."
    return 0
  fi
  say "Ejecting installer ISO from VM configuration..."
  local flags=(--config)
  vm_is_running && flags=(--live --config)
  virsh -c "$URI" change-media "$DOMAIN" sda --eject "${flags[@]}" >/dev/null \
    || die "Failed to eject the installer ISO."
  ok "ISO ejected. VM will boot directly from virtual disk."
}

vm_create_disk() {
  mkdir -p "$IMAGE_DIR"
  if [ ! -f "$DISK" ]; then
    say "Creating $DISK_SIZE sparse virtual disk ($DISK)..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
    ok "Virtual disk created."
  else
    ok "Virtual disk present: $(du -h "$DISK" | cut -f1)"
  fi
}

vm_synthesize_xml() {
  mkdir -p "$IMAGE_DIR"
  [ -f "$NVRAM_PATH" ] || cp "$OVMF_VARS" "$NVRAM_PATH"
  local runtime_dir="/run/user/$(id -u)"

  local gl_graphics=""
  local graphics_device="<graphics type=\"spice\" autoport=\"yes\" listen=\"127.0.0.1\"><listen type=\"address\" address=\"127.0.0.1\" /></graphics>"
  local spice_channel="<channel type=\"spicevmc\"><target type=\"virtio\" name=\"com.redhat.spice.0\" /><address type=\"virtio-serial\" controller=\"0\" bus=\"0\" port=\"2\" /></channel>"
  local video_device="<video><model type='virtio' heads='1' primary='yes'><acceleration accel3d='no'/></model></video>"
  if [ -f "$IMAGE_DIR/use-vnc" ]; then
    graphics_device="<graphics type=\"vnc\" port=\"-1\" autoport=\"yes\" listen=\"127.0.0.1\"><listen type=\"address\" address=\"127.0.0.1\" /></graphics>"
    spice_channel=""
    video_device="<video><model type='vga' heads='1' primary='yes'/></video>"
    say "Using saved VNC/standard VGA display fallback."
  elif [ -n "$RENDERNODE" ]; then
    gl_graphics="<graphics type='egl-headless'><gl rendernode='$RENDERNODE'/></graphics>"
    video_device="<video><model type='virtio' heads='1' primary='yes' device='virtio-vga-gl'><acceleration accel3d='yes'/></model></video>"
  fi

  # Empty ISO means an ejected (empty) CD-ROM drive.
  local cdrom_source=""
  [ -n "${ISO:-}" ] && cdrom_source="<source file=\"$ISO\" />"

  # Autoinstall answers ride on a second CD-ROM labeled CIDATA.
  local cidata_disk=""
  [ -n "${CIDATA:-}" ] && cidata_disk="<disk type=\"file\" device=\"cdrom\">
      <driver name=\"qemu\" type=\"raw\" />
      <source file=\"$CIDATA\" />
      <target dev=\"sdb\" bus=\"sata\" />
      <readonly />
    </disk>"

  local emulator
  emulator="$(command -v qemu-system-x86_64 || echo /usr/bin/qemu-system-x86_64)"

  # Redefining an existing domain must keep its UUID, or libvirt rejects the name clash.
  local uuid_tag="" uuid
  uuid="$(virsh -c "$URI" domuuid "$DOMAIN" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$uuid" ] && uuid_tag="<uuid>$uuid</uuid>"

  cat > "$DOMAIN_XML" <<EOF
<domain xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0" type="kvm">
  <name>$DOMAIN</name>
  $uuid_tag
  <memory unit="KiB">8388608</memory>
  <currentMemory unit="KiB">8388608</currentMemory>
  <vcpu placement="static">4</vcpu>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
    <firmware>
      <feature enabled="no" name="enrolled-keys" />
      <feature enabled="no" name="secure-boot" />
    </firmware>
    <loader readonly="yes" type="pflash" format="raw">$OVMF_CODE</loader>
    <nvram templateFormat="raw" format="raw">$NVRAM_PATH</nvram>
  </os>
  <features>
    <acpi />
    <apic />
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on">
    <topology sockets="1" dies="1" clusters="1" cores="4" threads="1" />
  </cpu>
  <clock offset="utc" />
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>$emulator</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" cache="writeback" discard="unmap" />
      <source file="$DISK" />
      <target dev="vda" bus="virtio" />
      <boot order="1" />
    </disk>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw" />
      $cdrom_source
      <target dev="sda" bus="sata" />
      <readonly />
      <boot order="2" />
    </disk>
    $cidata_disk
    <controller type="usb" index="0" model="qemu-xhci" />
    <controller type="sata" index="0" />
    <controller type="pci" index="0" model="pcie-root" />
    <controller type="virtio-serial" index="0" />
    <channel type="unix">
      <target type="virtio" name="org.qemu.guest_agent.0" />
      <address type="virtio-serial" controller="0" bus="0" port="1" />
    </channel>
    $spice_channel
    <input type="tablet" bus="virtio" />
    <input type="keyboard" bus="virtio" />
    <input type="keyboard" bus="ps2" />
    <input type="mouse" bus="ps2" />
    $graphics_device
    $gl_graphics
    <audio id="1" type="pulseaudio" />
    <sound model="ich9"><audio id="1" /></sound>
    $video_device
    <watchdog model="itco" action="reset" />
    <memballoon model="virtio" />
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
  <qemu:commandline>
    <qemu:env name="XDG_RUNTIME_DIR" value="$runtime_dir" />
    <qemu:arg value="-netdev" />
    <qemu:arg value="user,id=hostnet0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" />
    <qemu:arg value="-device" />
    <qemu:arg value="virtio-net-pci,netdev=hostnet0,id=net0,mac=52:54:00:aa:bb:cc,bus=pcie.0,addr=0x3" />
  </qemu:commandline>
</domain>
EOF
}

vm_define() {
  virsh -c "$URI" define "$DOMAIN_XML" >/dev/null || die "Failed to register VM domain with libvirt."
  ok "Domain '$DOMAIN' defined in $URI."
}

vm_install_desktop_entry() {
  local desktop_dir="$HOME/.local/share/applications"
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$desktop_dir" "$bin_dir"

  cat > "$desktop_dir/omarchy-vm.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Omarchy VM
GenericName=Omarchy Virtual Machine
Comment=Run Omarchy Arch/Hyprland Linux VM
Exec=$ROOT_DIR/omarchy open
Icon=computer
Terminal=false
Categories=System;Utility;
Actions=Stop;

[Desktop Action Stop]
Name=Shut Down
Exec=$ROOT_DIR/omarchy stop
EOF

  ok "Desktop entry installed."

  # Never clobber an unrelated 'omarchy' (e.g. Omarchy's own CLI on an Omarchy host).
  local link="$bin_dir/omarchy" other
  other="$(command -v omarchy 2>/dev/null || true)"
  if [ -e "$link" ] && [ "$(readlink -f "$link")" != "$ROOT_DIR/omarchy" ]; then
    warn "$link already exists and is not this tool; skipping CLI shortcut. Use: $ROOT_DIR/omarchy"
  elif [ -n "$other" ] && [ "$(readlink -f "$other")" != "$ROOT_DIR/omarchy" ]; then
    warn "Another 'omarchy' command exists ($other); skipping CLI shortcut. Use: $ROOT_DIR/omarchy"
  else
    ln -sfn "$ROOT_DIR/omarchy" "$link"
    ok "CLI shortcut installed: $link"
  fi
}

# The launcher entry only opens a VM, so it goes with the VM. The CLI link stays:
# it is the tool itself, and 'omarchy install' must still work afterwards.
vm_remove_desktop_entry() {
  rm -f "$HOME/.local/share/applications/omarchy-vm.desktop"
}
