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

PROVISION_GRANT="/etc/sudoers.d/zz-omarchy-vm-provision"
PROVISION_EXPIRE_UNIT="omarchy-vm-provision-expire"

# Wait until the installed system answers over SSH, showing elapsed time.
# Checks every 10s; on a terminal the time updates in place, in a log it gets a
# line per minute instead.
auto_wait_for_ssh() {
  local label="$1" deadline=$(( $(date +%s) + PROVISION_TIMEOUT )) start ticks=0 elapsed tty=0
  start=$(date +%s)
  [ -t 1 ] && tty=1
  say "$label (usually a few minutes)..."
  until auto_ssh_ready; do
    [ "$(date +%s)" -lt "$deadline" ] || { [ "$tty" -eq 0 ] || echo; warn "Timed out waiting for the installed system."; return 1; }
    vm_is_running || { [ "$tty" -eq 0 ] || echo; warn "VM stopped before the install finished."; return 1; }
    sleep 10
    ticks=$((ticks + 1))
    elapsed=$(( $(date +%s) - start ))
    if [ "$tty" -eq 1 ]; then
      printf '\r%b %s... %dm%02ds ' "${BLUE}[omarchy]${NC}" "$label" $((elapsed / 60)) $((elapsed % 60))
    elif (( ticks % 6 == 0 )); then
      say "$label... ($((elapsed / 60)) min)"
    fi
  done
  [ "$tty" -eq 0 ] || echo
  ok "Omarchy is up and reachable over SSH."
}

# Hands-free: the CIDATA drive answers the installer; wait for it, then provision.
auto_install_and_provision() {
  if [ "$AUTO_ENCRYPT" = "1" ]; then
    echo -e "\n${BOLD}${GREEN}Installing Omarchy automatically.${NC}"
    echo -e "${YELLOW}Encrypted disk: type your password in the VM window when it asks to unlock.${NC}"
  else
    echo -e "\n${BOLD}${GREEN}Installing Omarchy in the background — its window opens when everything is ready.${NC}"
  fi
  auto_wait_for_ssh "Installing" || return 1
  auto_provision_guest
}

# Fail the guided wait once the deadline passes or the VM goes away.
guided_alive() {
  [ "$(date +%s)" -lt "$1" ] && vm_is_running
}

# Full installer experience (--full-exp): the user goes through Omarchy's own
# installer in the VM window. Meanwhile the host, as root in the live ISO via its
# guest agent, hands the installer our SSH key and, once it finishes, seeds a
# temporary sudo grant into the still-mounted target. When the user clicks
# Reboot Now the window closes, setup runs here, and the window reopens on the
# finished desktop.
auto_guided_install() {
  local deadline=$(( $(date +%s) + PROVISION_TIMEOUT )) seen_installer=0 user="" encrypted=""

  echo -e "\n${BOLD}${GREEN}Go through the Omarchy installer in the VM window.${NC}"
  echo -e "When it finishes, click ${BOLD}Reboot Now${NC}; setup then continues here and the VM reopens when ready.\n"

  say "Waiting for the installer to start..."
  until vm_agent_up; do
    guided_alive "$deadline" || { warn "The installer never came up."; return 1; }
    sleep 2
  done
  # The ISO clears /root/authorized_keys just before its configurator starts,
  # and the installer reads it when the install begins, so write it in between.
  # (The [x] patterns keep pgrep from matching the sh -c that runs it.)
  until vm_agent_sh 'pgrep -f "[c]onfigurator|[o]rchestrator.main" >/dev/null' >/dev/null 2>&1; do
    guided_alive "$deadline" || { warn "The installer never came up."; return 1; }
    sleep 2
  done
  vm_agent_sh 'umask 077; cat > /root/authorized_keys' "$(cat "$PUBKEY")" >/dev/null \
    || { warn "Could not hand the SSH key to the installer."; return 1; }
  ok "Host SSH key handed to the installer."

  # The install is done when its orchestrator exits (the target stays mounted).
  # The wizard's answers are on disk once it starts, so read them right then:
  # by the time it exits, a Reboot Now click may already be on its way.
  say "Waiting for the installation to finish..."
  while true; do
    guided_alive "$deadline" || { warn "Timed out waiting for the installer."; return 1; }
    if vm_agent_sh 'pgrep -f "[o]rchestrator.main" >/dev/null' >/dev/null 2>&1; then
      if [ "$seen_installer" -eq 0 ]; then
        seen_installer=1
        user="$(vm_agent_sh 'jq -r ".users[0].username // empty" /root/user_credentials.json' 2>/dev/null | tr -d '[:space:]')" || true
        encrypted="$(vm_agent_sh 'cat /root/user_encrypt_installation.txt' 2>/dev/null | tr -d '[:space:]')" || true
        [ -n "$user" ] && { AUTO_USER="$user"; export OMARCHY_GUEST_USER="$user"; }
        [ "$encrypted" = "true" ] && AUTO_ENCRYPT=1
        ok "Installing Omarchy${user:+ for $user}..."
      fi
    elif [ "$seen_installer" -eq 1 ]; then
      break
    elif ! vm_agent_up; then
      warn "The installer rebooted before the host could prepare setup."
      break
    fi
    sleep 0.5
  done

  if [ -n "$user" ] && vm_agent_sh 'mountpoint -q /mnt' >/dev/null 2>&1; then
    # Seed the grant the hands-free path creates over SSH, plus a boot timer that
    # revokes it after an hour in case this host process never cleans up.
    vm_agent_sh "set -e
      d=/mnt/etc/systemd/system
      umask 337
      printf 'Defaults:$user verifypw=any\n$user ALL=(ALL) NOPASSWD: ALL\n' > /mnt$PROVISION_GRANT
      visudo -cqf /mnt$PROVISION_GRANT
      umask 022
      printf '[Unit]\nDescription=Revoke omarchy-vm setup sudo\n[Service]\nType=oneshot\nExecStart=/bin/sh -c \"rm -f $PROVISION_GRANT /etc/systemd/system/$PROVISION_EXPIRE_UNIT.* /etc/systemd/system/timers.target.wants/$PROVISION_EXPIRE_UNIT.timer\"\n' > \$d/$PROVISION_EXPIRE_UNIT.service
      printf '[Timer]\nOnBootSec=60min\n[Install]\nWantedBy=timers.target\n' > \$d/$PROVISION_EXPIRE_UNIT.timer
      mkdir -p \$d/timers.target.wants
      ln -sf ../$PROVISION_EXPIRE_UNIT.timer \$d/timers.target.wants/$PROVISION_EXPIRE_UNIT.timer" >/dev/null \
      || warn "Could not prepare sudo for setup; you will be asked for your password."
  fi

  echo -e "${GREEN}[   ok  ]${NC} Omarchy installed${user:+ for $user}. Click ${BOLD}Reboot Now${NC} in the VM window."
  # The live ISO's agent goes away as the VM reboots: close the window then.
  while vm_agent_up; do
    guided_alive "$deadline" || { warn "Timed out waiting for the reboot."; return 1; }
    sleep 1
  done
  if [ "$AUTO_ENCRYPT" = "1" ]; then
    echo -e "${YELLOW}Unlock the disk with your password in the VM window when it asks.${NC}"
  else
    vm_close_viewer
    echo -e "\n${BOLD}${GREEN}Rebooting into Omarchy — finishing setup in the background; the window reopens when ready.${NC}"
  fi

  [ -n "${OMARCHY_GUEST_USER:-}" ] || { warn "Could not read the username from the installer."; return 1; }
  auto_wait_for_ssh "Booting and setting up" || return 1
  auto_provision_guest
}

# Shared tail of both paths: get temporary sudo, run the guest setup over SSH,
# and apply it to the live desktop. Returns non-zero if setup could not finish.
auto_provision_guest() {
  # The installer media is no longer needed; drop it so later boots skip it.
  vm_eject_iso
  vm_eject_cidata

  local user="${OMARCHY_GUEST_USER:-$AUTO_USER}" grant="$PROVISION_GRANT" pw="$AUTO_PASSWORD"
  if ! vm_guest_ssh 'sudo -n true' </dev/null >/dev/null 2>&1; then
    # No grant seeded during the install: create one with the password.
    # verifypw=any lets the `sudo -v` calls in omarchy update pass too, and a
    # transient timer revokes it after an hour even if this host process dies.
    if [ -z "$pw" ]; then
      read -r -s -p "Password you set for $user in the installer (for setup's sudo): " pw; echo
    fi
    say "Granting temporary sudo for guest setup..."
    printf '%s\n' "$pw" | vm_guest_ssh "sudo -S -p '' sh -c '
      umask 337
      printf \"Defaults:$user verifypw=any\n$user ALL=(ALL) NOPASSWD: ALL\n\" > $grant
      visudo -cqf $grant || { rm -f $grant; exit 1; }
      systemd-run --on-active=60m --unit=$PROVISION_EXPIRE_UNIT rm -f $grant >/dev/null 2>&1 || true'" \
      || { warn "Could not obtain sudo in the guest."; return 1; }
  fi

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
  vm_guest_ssh "sudo sh -c 'systemctl stop $PROVISION_EXPIRE_UNIT.timer 2>/dev/null
    rm -f $grant /etc/systemd/system/$PROVISION_EXPIRE_UNIT.* /etc/systemd/system/timers.target.wants/$PROVISION_EXPIRE_UNIT.timer
    systemctl daemon-reload'" </dev/null >/dev/null 2>&1 || true
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
