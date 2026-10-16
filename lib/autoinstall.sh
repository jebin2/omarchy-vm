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
    echo -e "${YELLOW}Encrypted disk: type your password in the VM window when it asks to unlock; it closes again while setup finishes.${NC}"
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
# temporary sudo grant into the still-mounted target. Reboot Now is turned into
# a power-off, so the click closes the window at once; the host then boots the
# VM out of sight, runs setup, and opens the window on the finished desktop.
auto_guided_install() {
  local deadline=$(( $(date +%s) + PROVISION_TIMEOUT )) seen_installer=0 user="" encrypted=""
  local target_prepared=0

  echo -e "\n${BOLD}${GREEN}Go through the Omarchy installer in the VM window.${NC}"
  echo -e "When Omarchy shows ${BOLD}Reboot Now${NC}, click it. The host holds the reboot briefly while it prepares the first boot; the VM reopens when setup is done.\n"

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

  # Hold a requested reboot in the live ISO until the host has finished preparing
  # the installed target. This lets the user click Reboot Now immediately while
  # qemu-guest-agent and /mnt remain available for the host-side work.
  vm_agent_sh "set -e
    sc=\$(command -v systemctl)
    cp -L \"\$sc\" /run/omarchy-vm-systemctl.real
    chmod 755 /run/omarchy-vm-systemctl.real
    for action in reboot poweroff halt shutdown; do
      ln -sf /run/omarchy-vm-systemctl.real \"/run/\$action\"
    done
    cat > \"\$sc\" <<'OMARCHY_VM_SYSTEMCTL'
#!/bin/sh
action=\${0##*/}
hold=0
case \"\$action\" in reboot|poweroff|halt|shutdown) hold=1 ;; esac
for arg do
  case \"\$arg\" in reboot|poweroff|halt|shutdown) hold=1 ;; esac
done
if [ \"\$hold\" -eq 1 ]; then
  : > /run/omarchy-vm-reboot-requested
  i=0
  while [ ! -e /run/omarchy-vm-seed-done ] && [ \"\$i\" -lt 2400 ]; do
    sleep 0.25
    i=\$((i + 1))
  done
fi
case "\$action" in
  reboot|poweroff|halt|shutdown) exec \"/run/\$action\" \"\$@\" ;;
esac
exec /run/omarchy-vm-systemctl.real \"\$@\"
OMARCHY_VM_SYSTEMCTL
    chmod 755 \"\$sc\"" >/dev/null \
    || warn "Could not hold the installer reboot; automatic setup may need the disk password."

  # For this run only (--live), a guest reboot powers the VM off instead.
  virsh -c "$URI" set-lifecycle-action "$DOMAIN" reboot destroy --live >/dev/null \
    || warn "Could not hold the VM at Reboot Now; it will reboot in the window."

  # The install is done when its orchestrator exits; the dashboard then shows
  # Reboot Now with the target still mounted. Read the wizard's answers as soon
  # as the orchestrator starts, and prepare the first boot only after it exits:
  # until then the installer still rewrites limine.conf (finalize_limine_boot)
  # and takes the factory snapshot, which must not capture the sudo grant. The
  # reboot hold above keeps an early Reboot Now click waiting meanwhile.
  say "Waiting for the installation to finish..."
  while true; do
    [ "$(date +%s)" -lt "$deadline" ] || { warn "Timed out waiting for the installer."; return 1; }
    vm_is_running || break
    if vm_agent_sh 'pgrep -f "[o]rchestrator.main" >/dev/null' >/dev/null 2>&1; then
      if [ "$seen_installer" -eq 0 ]; then
        seen_installer=1
        user="$(vm_agent_sh 'jq -r ".users[0].username // empty" /root/user_credentials.json' 2>/dev/null | tr -d '[:space:]')" || true
        encrypted="$(vm_agent_sh 'cat /root/user_encrypt_installation.txt' 2>/dev/null | tr -d '[:space:]')" || true
        [ -n "$user" ] && { AUTO_USER="$user"; export OMARCHY_GUEST_USER="$user"; }
        [ "$encrypted" = "true" ] && AUTO_ENCRYPT=1
        if [ "$AUTO_ENCRYPT" = "1" ]; then
          AUTO_PASSWORD="$(vm_agent_sh 'jq -j ".encryption_password // empty" /root/user_credentials.json' 2>/dev/null || true)"
        fi
        ok "Installing Omarchy${user:+ for $user}..."
      fi
    elif [ "$seen_installer" -eq 1 ]; then
      break
    fi
    sleep 0.5
  done

  if vm_is_running && vm_agent_sh 'mountpoint -q /mnt' >/dev/null 2>&1; then
    if [ -n "$user" ]; then
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
    if [ "$AUTO_ENCRYPT" = "1" ]; then
      auto_seed_unlock_key || warn "Could not set up automatic unlock; the window opens at boot so you can unlock the disk."
    fi
    target_prepared=1
  fi
  # Release the held reboot (if Reboot Now was already clicked, it goes through now).
  vm_agent_sh 'touch /run/omarchy-vm-seed-done' >/dev/null 2>&1 || true

  if vm_is_running; then
    [ "$target_prepared" -eq 1 ] || warn "The VM rebooted before host setup could be prepared."
    echo -e "${GREEN}[   ok  ]${NC} Omarchy installed${user:+ for $user}. Click ${BOLD}Reboot Now${NC} in the VM window."
    while vm_is_running; do
      [ "$(date +%s)" -lt "$deadline" ] || { warn "Timed out waiting for Reboot Now."; return 1; }
      sleep 0.5
    done
  fi
  vm_close_viewer

  # Boot the installed system ourselves after the intercepted reboot.
  vm_start >/dev/null
  if [ "$AUTO_ENCRYPT" = "1" ] && [ -z "$UNLOCK_KEY" ]; then
    vm_open_viewer
    echo -e "${YELLOW}Unlock the disk with your password in the VM window; it closes again while setup finishes.${NC}"
  else
    echo -e "\n${BOLD}${GREEN}Booting Omarchy and finishing setup in the background — the window opens when ready.${NC}"
  fi

  [ -n "${OMARCHY_GUEST_USER:-}" ] || { warn "Could not read the username from the installer."; return 1; }
  if [ -n "$UNLOCK_KEY" ]; then
    # Should the key not unlock the disk, the boot sits at the password prompt
    # out of sight: show the window after a while so it can be typed there.
    local waited=0
    say "Booting and unlocking the disk automatically..."
    until auto_ssh_ready || [ "$waited" -ge 120 ]; do
      sleep 5
      waited=$((waited + 5))
    done
    if ! auto_ssh_ready; then
      vm_open_viewer
      warn "Automatic unlock did not finish; type your disk password in the VM window."
    fi
  fi
  auto_wait_for_ssh "Booting and setting up" || return 1
  auto_provision_guest
}

# Shared tail of both paths: get temporary sudo, run the guest setup over SSH,
# and apply it to the live desktop. Returns non-zero if setup could not finish.
auto_provision_guest() {
  # A window left open for the unlock prompt closes once past it: setup runs out
  # of sight and the window reopens on the finished desktop.
  if [ "$AUTO_ENCRYPT" = "1" ] && pgrep -f "(^|/)virt-viewer -c .* -a $DOMAIN$" >/dev/null 2>&1; then
    vm_close_viewer
    say "Disk unlocked; finishing setup in the background — the window reopens when ready."
  fi

  # The installer media is no longer needed; drop it so later boots skip it.
  vm_eject_iso
  vm_eject_cidata

  local user="${OMARCHY_GUEST_USER:-$AUTO_USER}" grant="$PROVISION_GRANT" pw="$AUTO_PASSWORD"
  if ! vm_guest_ssh 'sudo -n true' </dev/null >/dev/null 2>&1; then
    # No grant seeded during the install: create one with the password.
    # verifypw=any lets the `sudo -v` calls in omarchy update pass too, and a
    # transient timer revokes it after an hour even if this host process dies.
    if [ -z "$pw" ]; then
      read -r -s -p "Password you set for $user in the installer (for setup's sudo): " pw </dev/tty; echo
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
  auto_remove_unlock_key
  vm_guest_ssh "sudo sh -c 'systemctl stop $PROVISION_EXPIRE_UNIT.timer 2>/dev/null
    rm -f $grant /etc/systemd/system/$PROVISION_EXPIRE_UNIT.* /etc/systemd/system/timers.target.wants/$PROVISION_EXPIRE_UNIT.timer
    systemctl daemon-reload'" </dev/null >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || { warn "Guest setup failed (exit $rc)."; return 1; }
}

UNLOCK_KEY=""
UNLOCK_IMG="$IMAGE_DIR/unlock.img"
UNLOCK_SERIAL="omvmunlock"
# Omarchy boots through mkinitcpio's encrypt hook, which reads a raw key from a
# block device given as device:offset:length, and falls back to the passphrase
# prompt when the key is missing or wrong.
# The encrypted root is unlocked in mkinitcpio's early userspace, before the
# normal udev by-id links are guaranteed to exist. The temporary raw key disk
# is attached as the second virtio block device, so use its stable guest block
# name directly for this one boot.
UNLOCK_PARAM="cryptkey=/dev/vdb:0:64"

# In the live ISO, with the new system still mounted: add a random one-time key
# to the LUKS volume (authorized with the passphrase from the installer's
# answers or terminal prompt), add UNLOCK_PARAM to the boot entries, and attach a
# tiny disk holding the key for the next start. Sets UNLOCK_KEY.
auto_seed_unlock_key() {
  local user="${OMARCHY_GUEST_USER:-$AUTO_USER}"
  local pw="${AUTO_PASSWORD:-}"
  if [ -z "$pw" ]; then
    pw="$(vm_agent_sh 'jq -j ".encryption_password // empty" /root/user_credentials.json' 2>/dev/null || true)"
  fi
  if [ -n "$pw" ]; then
    say "Using cached installer password for first-boot disk unlock..."
  else
    echo -e "${YELLOW}Disk encryption detected.${NC}"
    while true; do
      read -r -s -p "Password for ${user:-Omarchy} (to unlock disk on first boot): " pw </dev/tty; echo
      [ -n "$pw" ] && break
      warn "Password cannot be empty."
    done
    AUTO_PASSWORD="$pw"
  fi

  local key
  key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local stdin_data
  printf -v stdin_data '%s\n%s\n' "$pw" "$key"

  # Wait for guest agent to remain responsive (installer may be shutting down)
  for _ in $(seq 1 "${FIT_WAIT:-120}"); do
    if vm_agent_up && vm_agent_sh 'mountpoint -q /mnt' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! vm_agent_up; then
    warn "Guest agent is not responding; cannot set up automatic unlock."
    return 1
  fi

  local rc=0
  # Shell tracing would print both the passphrase and one-time key to the host log.
  vm_agent_sh "set -e
    umask 077
    IFS= read -r pw || [ -n \"\$pw\" ]
    IFS= read -r key || [ -n \"\$key\" ]
    if [ -z \"\$pw\" ]; then
      echo 'error: empty disk password received' >&2
      exit 1
    fi
    printf '%s' \"\$key\" > /tmp/omvm.key
    dev=\$(lsblk -rno PATH,FSTYPE | awk '\$2 == \"crypto_LUKS\" { print \$1; exit }')
    [ -n \"\$dev\" ] || dev=\$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1)
    if [ -z \"\$dev\" ]; then
      echo 'error: no crypto_LUKS partition found' >&2
      exit 1
    fi
    printf '%s' \"\$pw\" | cryptsetup luksAddKey --batch-mode --key-file=- --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \"\$dev\" /tmp/omvm.key
    rm -f /tmp/omvm.key

    # The Omarchy installer always boots with Limine from /boot/limine.conf.
    sed -i -E 's#^([[:space:]]*(kernel_)?cmdline:.*)\$#\\1 $UNLOCK_PARAM#' /mnt/boot/limine.conf
    grep -q '$UNLOCK_PARAM' /mnt/boot/limine.conf" "$stdin_data" >/dev/null 2>"$IMAGE_DIR/unlock.err" || rc=$?

  if [ "$rc" -ne 0 ]; then
    local err
    err="$(cat "$IMAGE_DIR/unlock.err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"
    warn "Unlock key setup failed: ${err:-guest command failed with exit code $rc and no output}"
    rm -f "$IMAGE_DIR/unlock.err"
    return 1
  fi
  rm -f "$IMAGE_DIR/unlock.err"

  ( umask 077; printf '%s' "$key" > "$UNLOCK_IMG"; truncate -s 1M "$UNLOCK_IMG" )
  local attach_err
  if ! attach_err="$(virsh -c "$URI" attach-disk "$DOMAIN" "$UNLOCK_IMG" vdb --targetbus virtio --subdriver raw --serial "$UNLOCK_SERIAL" --config 2>&1)"; then
    warn "Could not attach the unlock key disk: $attach_err"
    rm -f "$UNLOCK_IMG"
    return 1
  fi
  UNLOCK_KEY="$key"
  ok "Disk set to unlock automatically on the first boot."
}

# Undo auto_seed_unlock_key from the booted system: drop the key slot and the
# boot parameter, then detach and delete the key disk.
auto_remove_unlock_key() {
  [ -n "$UNLOCK_KEY" ] || return 0
  vm_guest_ssh 'sudo sh -s' >/dev/null <<EOF || warn "Could not remove the one-time unlock key from the guest."
set -e
dev=\$(lsblk -rno PATH,FSTYPE | awk '\$2 == "crypto_LUKS" { print \$1; exit }')
[ -n "\$dev" ] || dev=\$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1)
[ -n "\$dev" ] && printf '%s' '$UNLOCK_KEY' | cryptsetup luksRemoveKey --batch-mode --key-file=- "\$dev" || true
sed -i 's# $UNLOCK_PARAM##g' /boot/limine.conf
EOF
  local flags=(--config)
  vm_is_running && flags=(--live --config)
  virsh -c "$URI" detach-disk "$DOMAIN" vdb "${flags[@]}" >/dev/null 2>&1 || true
  rm -f "$UNLOCK_IMG"
  UNLOCK_KEY=""
}

vm_eject_cidata() {
  if virsh -c "$URI" domblklist "$DOMAIN" --details 2>/dev/null | awk '$3 == "sdb" && $4 != "-" { f = 1 } END { exit !f }'; then
    local flags=(--config)
    vm_is_running && flags=(--live --config)
    virsh -c "$URI" change-media "$DOMAIN" sdb --eject "${flags[@]}" >/dev/null 2>&1 || true
  fi
  rm -f "$CIDATA_ISO"
}
