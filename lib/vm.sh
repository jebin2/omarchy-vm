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
  pkill -f "virt-viewer.*$DOMAIN" 2>/dev/null || true
  if virsh -c "$URI" dominfo "$DOMAIN" >/dev/null 2>&1; then
    virsh -c "$URI" undefine "$DOMAIN" --nvram >/dev/null 2>&1 \
      || virsh -c "$URI" undefine "$DOMAIN" --keep-nvram >/dev/null 2>&1 \
      || die "Could not undefine domain '$DOMAIN'."
  fi
  rm -f "$DISK" "$NVRAM_PATH" "$GUEST_USER_FILE" "$DOMAIN_XML"
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

vm_start() {
  local s rc=0
  s="$(vm_state 2>/dev/null)" || rc=$?
  if [ $rc -eq 1 ]; then
    die "VM '$DOMAIN' is not defined. Run 'omarchy setup' first."
  elif [ $rc -eq 2 ]; then
    die "Cannot connect to hypervisor ($URI). Check your libvirt service."
  elif [ "$s" = "running" ]; then
    say "VM '$DOMAIN' is already running."
  else
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
  vm_is_running || die "VM is not running. Start it with: omarchy start"
  command -v virt-viewer >/dev/null 2>&1 || die "virt-viewer not installed (sudo pacman -S virt-viewer)"

  # Schedule auto-fit in background once guest agent boots
  nohup "$ROOT_DIR/omarchy" fit --wait >/dev/null 2>&1 &

  say "Opening SPICE display in virt-viewer (Fullscreen; Ctrl+Alt+F to toggle)..."
  nohup virt-viewer -c "$URI" -f -a "$DOMAIN" >/dev/null 2>&1 &
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
  vm_is_running || die "VM is not running. Start it with: omarchy up"
  local follow=0
  case "${1:-}" in -f|--follow) follow=1 ;; esac

  local chan
  chan="$(virsh -c "$URI" dumpxml "$DOMAIN" | grep -A1 "channel type='spicevmc'" | grep -o "state='[a-z]*'" | cut -d"'" -f2 || true)"
  echo "Host SPICE channel:  ${chan:-missing}"
  pgrep -f "virt-viewer.*$DOMAIN" >/dev/null && echo "virt-viewer:         open" \
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
    | awk '$2 == "cdrom" && $4 != "-" { print $4; exit }'
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

  local gl_graphics=""
  local video_device="<video><model type='virtio' heads='1' primary='yes'><acceleration accel3d='no'/></model></video>"
  if [ -n "$RENDERNODE" ]; then
    gl_graphics="<graphics type='egl-headless'><gl rendernode='$RENDERNODE'/></graphics>"
    video_device="<video><model type='virtio' heads='1' primary='yes' device='virtio-vga-gl'><acceleration accel3d='yes'/></model></video>"
  fi

  # Empty ISO means an ejected (empty) CD-ROM drive.
  local cdrom_source=""
  [ -n "${ISO:-}" ] && cdrom_source="<source file=\"$ISO\" />"

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
    <controller type="usb" index="0" model="qemu-xhci" />
    <controller type="sata" index="0" />
    <controller type="pci" index="0" model="pcie-root" />
    <controller type="virtio-serial" index="0" />
    <channel type="unix">
      <target type="virtio" name="org.qemu.guest_agent.0" />
      <address type="virtio-serial" controller="0" bus="0" port="1" />
    </channel>
    <channel type="spicevmc">
      <target type="virtio" name="com.redhat.spice.0" />
      <address type="virtio-serial" controller="0" bus="0" port="2" />
    </channel>
    <input type="tablet" bus="virtio" />
    <input type="keyboard" bus="virtio" />
    <input type="keyboard" bus="ps2" />
    <input type="mouse" bus="ps2" />
    <graphics type="spice" autoport="yes" listen="127.0.0.1">
      <listen type="address" address="127.0.0.1" />
    </graphics>
    $gl_graphics
    <audio id="1" type="none" />
    $video_device
    <watchdog model="itco" action="reset" />
    <memballoon model="virtio" />
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
  <qemu:commandline>
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
Exec=$ROOT_DIR/omarchy up
Icon=computer
Terminal=true
Categories=System;Utility;
Actions=Start;Stop;Open;ForceStop;Status;SSH;

[Desktop Action Start]
Name=Start & Open
Exec=$ROOT_DIR/omarchy up

[Desktop Action Stop]
Name=Shut Down
Exec=$ROOT_DIR/omarchy stop

[Desktop Action Open]
Name=Open Screen (virt-viewer)
Exec=$ROOT_DIR/omarchy open

[Desktop Action ForceStop]
Name=Force Off
Exec=$ROOT_DIR/omarchy force-stop

[Desktop Action Status]
Name=Show Status
Exec=$ROOT_DIR/omarchy status

[Desktop Action SSH]
Name=SSH Connect
Exec=$ROOT_DIR/omarchy ssh
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
