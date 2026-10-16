#!/usr/bin/env bash
# ==============================================================================
# lib/detect.sh — System, Hardware, and Environment Auto-Detection
# ==============================================================================
set -euo pipefail

detect_dependencies() {
  local required=(virsh qemu-system-x86_64 qemu-img virt-viewer python3 curl ssh ssh-keygen)
  local missing=()
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ ${#missing[@]} -ne 0 ]; then
    warn "Missing required packages: ${missing[*]}"
    if command -v pacman >/dev/null 2>&1; then
      say "Installing missing packages via pacman..."
      sudo pacman -S --needed --noconfirm qemu-desktop qemu-system-x86 qemu-img libvirt virt-viewer edk2-ovmf python openssh curl
    elif command -v dnf >/dev/null 2>&1; then
      say "Installing missing packages via dnf..."
      sudo dnf install -y qemu-kvm libvirt virt-viewer edk2-ovmf python3 openssh-clients curl
    elif command -v apt-get >/dev/null 2>&1; then
      say "Installing missing packages via apt..."
      sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils libvirt-daemon-system virt-viewer ovmf python3 openssh-client curl
    else
      die "Please install missing packages: ${missing[*]}"
    fi

    # Re-verify dependencies after package installation
    missing=()
    for cmd in "${required[@]}"; do
      command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
      die "The following required tools are still missing after package installation: ${missing[*]}"
    fi
  fi
  ok "All host dependencies verified."
}

# Tools only the hands-free install needs: xorriso builds the CIDATA drive,
# openssl hashes the account password the way the Omarchy configurator does.
detect_autoinstall_deps() {
  command -v xorriso >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && return 0
  say "Installing autoinstall tools (xorriso, openssl)..."
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm libisoburn openssl
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y xorriso openssl
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y xorriso openssl
  fi
  command -v xorriso >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 \
    || die "Hands-free install needs xorriso and openssl (or run: ./setup.sh --manual)."
}

detect_kvm() {
  [ -e /dev/kvm ] || die "/dev/kvm not found. Enable hardware virtualization (VT-x/AMD-V) in BIOS."
  if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    warn "User $USER lacks permissions on /dev/kvm. Adding to kvm group..."
    sudo usermod -aG kvm,libvirt "$USER" 2>/dev/null || true
  fi

  # Start user session libvirt socket if not active
  if ! virsh -c "$URI" list >/dev/null 2>&1; then
    say "Activating libvirt user session socket..."
    systemctl --user enable --now virtqemud.socket 2>/dev/null || \
    systemctl --user enable --now libvirtd.socket 2>/dev/null || true
    sleep 1
  fi
  ok "KVM & user libvirt session active."
}

detect_ovmf() {
  OVMF_CODE=""
  OVMF_VARS=""
  local code_paths=(
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd"
    "/usr/share/ovmf/x64/OVMF_CODE.4m.fd"
    "/usr/share/edk2/x64/OVMF_CODE.fd"
    "/usr/share/ovmf/OVMF_CODE.fd"
    "/usr/share/OVMF/OVMF_CODE.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd"
  )
  local vars_paths=(
    "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
    "/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd"
    "/usr/share/ovmf/x64/OVMF_VARS.4m.fd"
    "/usr/share/edk2/x64/OVMF_VARS.fd"
    "/usr/share/ovmf/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_VARS.fd"
  )

  for c in "${code_paths[@]}"; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
  done
  for v in "${vars_paths[@]}"; do
    [ -f "$v" ] && { OVMF_VARS="$v"; break; }
  done

  [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || die "OVMF UEFI firmware not found! Install edk2-ovmf."
  ok "OVMF Firmware: $OVMF_CODE"
}

detect_gpu() {
  RENDERNODE=""
  for node in /dev/dri/renderD*; do
    [ -e "$node" ] || continue
    local drv=""
    local syspath="/sys/class/drm/$(basename "$node")/device/driver"
    [ -e "$syspath" ] && drv="$(basename "$(readlink -f "$syspath")")"

    # Avoid NVIDIA proprietary driver: causes QEMU EGL hangs
    if [[ "$drv" =~ nvidia ]]; then
      warn "Skipping NVIDIA render node $node ($drv) — known QEMU EGL driver freeze issue."
      continue
    fi

    # Prioritize Intel or AMD
    if [[ "$drv" =~ (i915|xe|amdgpu|radeonsi) ]]; then
      RENDERNODE="$node"
      say "Detected compatible GPU ($drv) on $node"
      break
    fi

    [ -z "$RENDERNODE" ] && RENDERNODE="$node"
  done

  if [ -n "$RENDERNODE" ]; then
    ok "3D OpenGL virgl acceleration enabled on $RENDERNODE"
  else
    warn "No non-NVIDIA GPU found. Falling back to 2D SPICE rendering."
  fi
}

detect_host_resolution() {
  local res=""
  # 1. KDE Wayland via kscreen-doctor
  if command -v kscreen-doctor >/dev/null 2>&1; then
    res="$(kscreen-doctor -o 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' -n -e 's/.*Geometry:[[:space:]]*[0-9]*,[0-9]*[[:space:]]*\([0-9]*x[0-9]*\).*/\1/p' | sort -t x -k1,1n -k2,2n | tail -1)"
  fi
  # 2. Hyprland on host via hyprctl
  if [ -z "$res" ] && command -v hyprctl >/dev/null 2>&1; then
    res="$(hyprctl monitors 2>/dev/null | grep -E '^[[:space:]]*[0-9]+x[0-9]+@' | head -1 | sed -E 's/.*([0-9]+x[0-9]+)@.*/\1/' || true)"
  fi
  # 3. wlroots via wlr-randr
  if [ -z "$res" ] && command -v wlr-randr >/dev/null 2>&1; then
    res="$(wlr-randr 2>/dev/null | grep -E '^[[:space:]]*[0-9]+x[0-9]+' | head -1 | awk '{print $1}' || true)"
  fi
  # 4. Sway via swaymsg
  if [ -z "$res" ] && command -v swaymsg >/dev/null 2>&1; then
    res="$(swaymsg -t get_outputs 2>/dev/null | grep -oE '"width": [0-9]+, "height": [0-9]+' | head -1 | awk '{print $2 "x" $4}' | tr -d ',' || true)"
  fi
  # 5. X11 via xrandr
  if [ -z "$res" ] && command -v xrandr >/dev/null 2>&1; then
    res="$(xrandr 2>/dev/null | grep '\*' | awk '{print $1}' | head -1 || true)"
  fi
  echo "${res:-1920x1080}"
}

detect_ssh_key() {
  PUBKEY=""
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && { PUBKEY="$k"; break; }
  done
  if [ -z "$PUBKEY" ]; then
    say "Generating host SSH key (~/.ssh/id_ed25519)..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "omarchy-vm-$USER" -q
    PUBKEY="$HOME/.ssh/id_ed25519.pub"
  fi
  ok "SSH Key: $PUBKEY"
}

# Newest ISO URL linked from omarchy.org (empty when offline or unparseable).
latest_iso_url() {
  curl -fsSL --max-time 15 https://omarchy.org/ 2>/dev/null \
    | grep -oE 'https://iso\.omarchy\.org/omarchy-[0-9][0-9.]*\.iso' | sort -uV | tail -1 || true
}

# Check an ISO against its published .sha256 (skipped when it can't be fetched).
verify_iso() {
  local iso="$1" url="$2" want have
  want="$(curl -fsSL --max-time 15 "$url.sha256" 2>/dev/null | awk '{ print $1; exit }')" || true
  [ -n "$want" ] || { warn "Could not fetch checksum for $(basename "$iso"); skipping verification."; return 0; }
  say "Verifying $(basename "$iso") checksum..."
  have="$(sha256sum "$iso" | awk '{ print $1 }')"
  [ "$have" = "$want" ]
}

# Sets ISO: the given path, else the latest release (downloaded once into the
# repo), else the newest ISO already on disk when omarchy.org is unreachable.
detect_iso() {
  local custom="${1:-}" url name target
  ISO=""
  if [ -n "$custom" ]; then
    [ -f "$custom" ] || die "ISO not found: $custom"
    ISO="$(realpath "$custom")"
    ok "Using ISO: $(basename "$ISO") ($(du -h "$ISO" | cut -f1))"
    return 0
  fi

  say "Looking up the latest Omarchy ISO..."
  url="$(latest_iso_url)"
  if [ -z "$url" ]; then
    ISO="$(ls -v "$ROOT_DIR"/omarchy-*.iso 2>/dev/null | tail -1 || true)"
    [ -n "$ISO" ] || die "Could not reach omarchy.org to find the latest ISO. Pass one: omarchy install /path/to/omarchy.iso"
    warn "omarchy.org unreachable; using local $(basename "$ISO")."
    return 0
  fi

  name="$(basename "$url")"
  target="$ROOT_DIR/$name"
  if [ -f "$target" ]; then
    ok "Latest ISO already downloaded: $name"
  else
    say "Downloading $name (~6 GB)..."
    curl -fL -C - --retry 3 -o "$target.part" "$url" || die "Download failed (re-run to resume)."
    verify_iso "$target.part" "$url" || { rm -f "$target.part"; die "Checksum mismatch for $name; deleted the download. Re-run to retry."; }
    mv "$target.part" "$target"
    ok "Downloaded and verified $name."
  fi
  ISO="$target"
}
