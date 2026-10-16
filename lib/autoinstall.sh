#!/usr/bin/env bash
# ==============================================================================
# lib/autoinstall.sh — Unattended Omarchy install via the ISO's cidata drive
# ==============================================================================
# The Omarchy ISO skips its configurator when a drive labeled CIDATA carries the
# configurator's output files (see /usr/local/bin/omarchy-cidata-load on the
# ISO). We build that drive on the host, so the whole install runs hands-free,
# and the installer itself authorizes our SSH key and enables sshd. Once the
# installed system answers over SSH, the host runs the guest setup there.
# ==============================================================================
set -euo pipefail

CIDATA_ISO="$IMAGE_DIR/cidata.iso"
AUTO_USER=""
AUTO_PASSWORD=""
AUTO_ENCRYPT="${OMARCHY_ENCRYPT:-0}"

# Ask for the guest account up front, so nothing waits on the user later.
# OMARCHY_GUEST_USER / OMARCHY_GUEST_PASSWORD skip the prompts.
auto_prompt_credentials() {
  local user="${OMARCHY_GUEST_USER:-}" pw="${OMARCHY_GUEST_PASSWORD:-}" pw2
  if [ -z "$user" ]; then
    read -r -p "Omarchy username [$USER]: " user
    user="${user:-$USER}"
  fi
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username '$user' (lowercase letters, digits, - and _)."

  if [ -z "$pw" ]; then
    while true; do
      read -r -s -p "Password for $user (also used for sudo): " pw; echo
      [ -n "$pw" ] || { warn "Password cannot be empty."; continue; }
      read -r -s -p "Confirm password: " pw2; echo
      [ "$pw" = "$pw2" ] && break
      warn "Passwords do not match; try again."
    done
  fi
  AUTO_USER="$user"
  AUTO_PASSWORD="$pw"
  # Every later ssh/fit call resolves the guest user from this.
  export OMARCHY_GUEST_USER="$user"
}

# Write the configurator's output files (same names and JSON shape as the ISO's
# ./configurator) and pack them onto a CIDATA-labeled ISO.
auto_build_cidata() {
  local dir disk_bytes mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
  dir="$(mktemp -d)"
  chmod 700 "$dir"

  disk_bytes="$(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')"
  local boot_start=$mib boot_size=$((2 * gib))
  local main_start=$((boot_start + boot_size))
  local main_size=$((disk_bytes / mib * mib - main_start - mib))

  local tz keymap encrypt=false
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  tz="${tz:-UTC}"
  keymap="$(localectl status 2>/dev/null | awk -F': ' '/VC Keymap/ { print $2 }' | tr -d '[:space:]')"
  [ -n "$keymap" ] && [ "$keymap" != "n/a" ] || keymap="us"
  [ "$AUTO_ENCRYPT" = "1" ] && encrypt=true

  OMARCHY_PW="$AUTO_PASSWORD" OMARCHY_PW_HASH="$(printf '%s' "$AUTO_PASSWORD" | openssl passwd -6 -stdin)" \
  python3 - "$dir" "$AUTO_USER" "$encrypt" "$tz" "$keymap" "$boot_start" "$boot_size" "$main_start" "$main_size" <<'PY'
import json, os, sys
out, user, encrypt, tz, keymap = sys.argv[1:6]
boot_start, boot_size, main_start, main_size = map(int, sys.argv[6:10])
encrypt = encrypt == "true"
pw, pw_hash = os.environ["OMARCHY_PW"], os.environ["OMARCHY_PW_HASH"]

def size(value):
    return {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": value}

root_id = "8c2c2b92-1070-455d-b76a-56263bab24aa"
disk_config = {
    "config_type": "default_layout",
    "device_modifications": [{
        "device": "/dev/vda",
        "partitions": [
            {"btrfs": [], "dev_path": None, "flags": ["boot", "esp"], "fs_type": "fat32",
             "mount_options": [], "mountpoint": "/boot",
             "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
             "size": size(boot_size), "start": size(boot_start), "status": "create", "type": "primary"},
            {"btrfs": [{"mountpoint": "/", "name": "@"}, {"mountpoint": "/home", "name": "@home"},
                       {"mountpoint": "/var/log", "name": "@log"},
                       {"mountpoint": "/var/cache/pacman/pkg", "name": "@pkg"}],
             "dev_path": None, "flags": [], "fs_type": "btrfs", "mount_options": ["compress=zstd"],
             "mountpoint": None, "obj_id": root_id,
             "size": size(main_size), "start": size(main_start), "status": "create", "type": "primary"},
        ],
        "wipe": True,
    }],
}
if encrypt:
    disk_config["disk_encryption"] = {"encryption_type": "luks", "lvm_volumes": [], "iter_time": 2000,
                                      "partitions": [root_id], "encryption_password": pw}

config = {
    "app_config": None,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": {"audio": "pipewire"},
    "bootloader_config": {"bootloader": "Limine", "uki": False, "removable": False},
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk", "defer_provisioning": False, "target_mount": "/mnt",
        "boot": {"esp_mount": "/boot", "esp_path": "/EFI/limine",
                 "efi_binary": "limine_x64.efi", "enable_fallback": True},
        "storage": {"kernel": "linux-omarchy"},
    },
    "disk_config": disk_config,
    "hostname": "omarchy-vm",
    "kernels": ["linux-omarchy"],
    "network_config": {"type": "iso"},
    "ntp": True,
    "parallel_downloads": 8,
    "script": None,
    "services": [],
    "swap": True,
    "timezone": tz,
    "locale_config": {"kb_layout": keymap, "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"},
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [{"url": "https://mirror.omarchy.org/$repo/os/$arch"},
                           {"url": "https://mirror.rackspace.com/archlinux/$repo/os/$arch"},
                           {"url": "https://geo.mirror.pkgbuild.com/$repo/os/$arch"}],
        "mirror_regions": {},
        "optional_repositories": [],
    },
    "packages": ["base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy"],
    "profile_config": {"gfx_driver": None, "greeter": None, "profile": {}},
    "version": "3.0.9",
}
creds = {"root_enc_password": pw_hash,
         "users": [{"enc_password": pw_hash, "groups": [], "sudo": True, "username": user}]}
if encrypt:
    creds["encryption_password"] = pw

with open(os.path.join(out, "user_configuration.json"), "w") as f:
    json.dump(config, f, indent=4)
with open(os.path.join(out, "user_credentials.json"), "w") as f:
    json.dump(creds, f, indent=4)
with open(os.path.join(out, "user_encrypt_installation.txt"), "w") as f:
    f.write(("true" if encrypt else "false") + "\n")
PY

  local name email
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"
  [ -n "$name" ] && printf '%s\n' "$name" > "$dir/user_full_name.txt"
  [ -n "$email" ] && printf '%s\n' "$email" > "$dir/user_email_address.txt"
  cp "$PUBKEY" "$dir/authorized_keys"

  rm -f "$CIDATA_ISO"
  ( umask 077; xorriso -as mkisofs -quiet -V CIDATA -J -R -o "$CIDATA_ISO" "$dir" >/dev/null 2>&1 ) \
    || { rm -rf "$dir"; die "Could not build the autoinstall drive (xorriso failed)."; }
  rm -rf "$dir"
  ok "Autoinstall drive ready (user: $AUTO_USER, encrypted disk: $encrypt)."
}

# True once the installed system accepts our key (the live ISO never does).
auto_ssh_ready() {
  vm_guest_ssh true >/dev/null 2>&1
}

# Wait for the hands-free install, then provision the guest over SSH.
# Returns non-zero if any stage could not complete.
auto_install_and_provision() {
  local deadline=$(( $(date +%s) + PROVISION_TIMEOUT ))

  local start ticks=0
  start=$(date +%s)
  if [ "$AUTO_ENCRYPT" = "1" ]; then
    echo -e "\n${BOLD}${GREEN}Installing Omarchy automatically.${NC}"
    echo -e "${YELLOW}Encrypted disk: type your password in the VM window when it asks to unlock.${NC}"
  else
    echo -e "\n${BOLD}${GREEN}Installing Omarchy in the background — its window opens when everything is ready.${NC}"
  fi
  # Check every 10s. On a terminal the elapsed time updates in place; in a log
  # it gets a line per minute instead.
  local elapsed tty=0
  [ -t 1 ] && tty=1
  say "Installing (usually a few minutes)..."
  until auto_ssh_ready; do
    [ "$(date +%s)" -lt "$deadline" ] || { [ "$tty" -eq 0 ] || echo; warn "Timed out waiting for the installed system."; return 1; }
    vm_is_running || { [ "$tty" -eq 0 ] || echo; warn "VM stopped before the install finished."; return 1; }
    sleep 10
    ticks=$((ticks + 1))
    elapsed=$(( $(date +%s) - start ))
    if [ "$tty" -eq 1 ]; then
      printf '\r%b Still installing... %dm%02ds ' "${BLUE}[omarchy]${NC}" $((elapsed / 60)) $((elapsed % 60))
    elif (( ticks % 6 == 0 )); then
      say "Still installing... ($((elapsed / 60)) min)"
    fi
  done
  [ "$tty" -eq 0 ] || echo
  ok "Omarchy installed and reachable over SSH."

  # The installer media is no longer needed; drop it so later boots skip it.
  vm_eject_iso
  vm_eject_cidata

  local user="$AUTO_USER" grant="/etc/sudoers.d/zz-omarchy-vm-provision"
  # Temporary passwordless sudo for the unattended setup. verifypw=any lets the
  # `sudo -v` calls in omarchy update pass too, and a transient timer revokes the
  # grant after an hour even if this host process dies before cleaning up.
  say "Granting temporary sudo for guest setup..."
  printf '%s\n' "$AUTO_PASSWORD" | vm_guest_ssh "sudo -S -p '' sh -c '
    umask 337
    printf \"Defaults:$user verifypw=any\n$user ALL=(ALL) NOPASSWD: ALL\n\" > $grant
    visudo -cqf $grant || { rm -f $grant; exit 1; }
    systemd-run --on-active=60m --unit=omarchy-vm-provision-expire rm -f $grant >/dev/null 2>&1 || true'" \
    || { warn "Could not obtain sudo in the guest."; return 1; }

  say "Running guest setup (updates, guest tools, clipboard bridge)..."
  local rc=0
  vm_guest_ssh "OMARCHY_VM_UNATTENDED=1 bash -lc 'bash <(curl -fsSL http://10.0.2.2:$PROVISION_PORT)'" </dev/null || rc=$?

  # Apply the setup to the live desktop instead of rebooting: the guest setup
  # already started the agents and reloaded Hyprland, so only a VM still sitting
  # at the SDDM greeter needs SDDM restarted to pick up the new autologin. A
  # kernel the update installed simply takes effect on the next boot.
  if [ "$rc" -eq 0 ] && ! vm_guest_ssh 'pgrep -u "$USER" -x Hyprland' >/dev/null 2>&1; then
    say "Logging in to the desktop..."
    vm_guest_ssh "sudo systemctl restart sddm" </dev/null >/dev/null 2>&1 || true
  fi
  vm_guest_ssh "sudo sh -c 'rm -f $grant; systemctl stop omarchy-vm-provision-expire.timer'" </dev/null >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || { warn "Guest setup failed (exit $rc)."; return 1; }
}

vm_eject_cidata() {
  if virsh -c "$URI" domblklist "$DOMAIN" --details 2>/dev/null | awk '$3 == "sdb" && $4 != "-" { f = 1 } END { exit !f }'; then
    local flags=(--config)
    vm_is_running && flags=(--live --config)
    virsh -c "$URI" change-media "$DOMAIN" sdb --eject "${flags[@]}" >/dev/null 2>&1 || true
  fi
  rm -f "$CIDATA_ISO"
}
