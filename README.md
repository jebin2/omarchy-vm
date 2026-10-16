# Omarchy VM — Control & Notes

Set up a KVM/libvirt **Omarchy 4.0.1** virtual machine on this machine (KDE Plasma / Wayland).

## Layout

| Path | Purpose |
|------|---------|
| `~/omarchy-vm/omarchy-4.0.1.iso` | Omarchy 4.0.1 install ISO (6.2 GB, verified) |
| `~/omarchy-vm/omarchy-4.0.1.iso.sha256` | Official SHA256 for the ISO |
| `~/omarchy-vm/images/omarchy.qcow2` | Virtual disk (40 GB) — the installed system |
| `~/omarchy-vm/omarchy-control.sh` | Control script (start/stop/open) |
| `~/omarchy-vm/provision-guest.sh` | Host side: serves `guest-setup.sh` to the guest and waits for it |
| `~/omarchy-vm/guest-setup.sh` | Guest side: SSH + host key, guest agent, clipboard agent |
| `~/omarchy-vm/vm-clipboard-bridge` (+ `.service`) | Guest side: syncs XWayland ↔ Wayland clipboards |
| `~/.local/share/applications/omarchy-vm.desktop` | KDE launcher entry |

## Control script

```bash
~/omarchy-vm/omarchy-control.sh <command>
```

| Command | Action |
|---------|--------|
| `up` | Start the VM and open the screen |
| `toggle` | Start & open if off, stop if running |
| `start` | Boot the VM |
| `stop` | Graceful shutdown: guest agent → ACPI → force power off |
| `force-stop` | Power off immediately |
| `open` | Open the VM's SPICE display in `virt-viewer` fullscreen |
| `fit` | Match the guest screen to the host resolution (or `fit 1600x900`) and save it for the next boot |
| `status` | Print VM state |

Examples:

```bash
~/omarchy-vm/omarchy-control.sh up        # boot and view
~/omarchy-vm/omarchy-control.sh toggle    # on/off flip
```

Or launch **"Omarchy VM"** from the KDE application menu (right-click for actions).

## VM details (libvirt)

- **Name / URI**: `omarchy-vm` · `qemu:///session`
- **Firmware**: UEFI (OVMF) — required by Omarchy
- **Resources**: 4 vCPUs · 8 GB RAM · 40 GB virtio disk
- **Network**: user-mode (SLIRP) NAT, virtio NIC
- **Display**: SPICE on loopback (auto-port), opened with `virt-viewer`
- **Screen size**: `open`/`up`/`toggle` match the guest screen to the host's resolution through the
  guest agent, in the background, waiting up to 4 min for the guest to boot. The size is applied
  live and saved as the last line of the guest's `~/.config/hypr/monitors.lua` (marked
  `-- omarchy-vm-host-res`), so the next boot starts at that size. Without it, virtio-gpu's
  1280x800 "preferred" mode wins. `provision-guest.sh` applies it once after a reset.
- **3D acceleration**: virgl — `virtio-vga-gl` + an `egl-headless` graphics device rendering on
  `/dev/dri/renderD128` (Intel UHD 770). QEMU does the GL work on the host GPU and sends the
  rendered display through SPICE to `virt-viewer`.
- **Guest agent**: `virtio-serial` controller + `org.qemu.guest_agent.0` channel. Requires
  `qemu-guest-agent` installed and enabled *inside* the guest.
- **Autostart**: disabled (does NOT start on system boot)

Raw libvirt commands (no wrapper):

```bash
virsh -c qemu:///session start omarchy-vm
virsh -c qemu:///session shutdown omarchy-vm
virsh -c qemu:///session destroy omarchy-vm
virsh -c qemu:///session domdisplay omarchy-vm
```

## Notes & gotchas

- **Use `virt-viewer` for the SPICE display.** Install it with
  `sudo pacman -S virt-viewer` (`ctrl+alt+f` toggles fullscreen, `ctrl+alt+g` releases the pointer).
- **Changing the guest resolution**: `hyprctl keyword` does not work on Omarchy's Lua config
  ("keyword can't work with non-legacy parsers"). Use
  `hyprctl eval 'hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })'`,
  and note the wildcard `output = ""` rule must stay *before* the `Virtual-1` rule in
  `monitors.lua`.
- **Autostart is disabled** — the VM will not start on system boot; start it manually.
- **Fresh VM installs use SPICE and SSH forwarding automatically.** `reset-omarchy-vm.sh`
  converts the display to SPICE and enables host port `127.0.0.1:2222` → guest port 22.
  It also starts `provision-guest.sh` in the background (log: `images/provision-guest.log`).
  After installing and logging in, run this once in a VM terminal:
  `bash <(curl -fsSL http://10.0.2.2:8765/guest-setup.sh)` — it installs and enables `sshd`
  (authorizing the host's SSH key), `qemu-guest-agent` and the clipboard agent. For an
  existing VM, run `./provision-guest.sh` on the host first, then the same line in the guest.
- **Clipboard sharing** uses a `spicevmc` channel (`com.redhat.spice.0`). The `qemu-vdagent`
  channel does *not* work here: it only serves QEMU's own VNC/GTK/D-Bus displays, not SPICE.
  `spice-vdagent` has no native Wayland clipboard, so the guest runs it on XWayland (`:0`) via
  the package's own `spice-vdagent.service` (starts with the session). Hyprland does *not* reliably
  mirror the XWayland clipboard to Wayland, so `vm-clipboard-bridge` (a user service in the guest,
  using `clipnotify`/`xclip`/`wl-clipboard`) syncs text between them in both directions.
- **Shutdown escalates in three stages.** `stop` pings the guest agent; if it answers it uses
  `shutdown --mode agent` (the reliable path). If the agent is absent or the guest doesn't stop
  within `SHUTDOWN_WAIT` (default 20 s), it falls back to `--mode acpi`, and finally to
  `virsh destroy`. **ACPI alone is ignored by the Omarchy guest**, which is why the agent path
  exists — without the agent installed, `stop` always ends in a force power-off.
- **Guest agent setup** — host side is configured; inside the guest run:
  `sudo pacman -S --needed qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent`.
  Verify from the host with:
  `virsh -c qemu:///session qemu-agent-command omarchy-vm '{"execute":"guest-ping"}'`
- **Cursor visibility** — this VM's virtio-gpu hardware cursor plane is not visible in the
  SPICE display. The theme installers set `cursor.no_hardware_cursors = true` in
  `~/.config/hypr/looknfeel.lua` so Hyprland draws the cursor in software. Reload Hyprland
  after applying the theme.
- **Boot order**: the installed disk boots first. The ISO is still attached but is **not** bootable, so it won't relaunch the installer.
- **virgl uses the Intel iGPU, not the RTX 4050 — and `renderD129` is TESTED BROKEN.**
  Pointing `rendernode` at `/dev/dri/renderD129` makes QEMU **hang at startup** (reproduced
  3x, driver 580.178.04): it opens the node and loads the NVIDIA EGL/GBM stack, then spins
  in EGL init and never loads `libvirglrenderer`. The VM would boot to a black screen.
  Do not retry without first testing in a throwaway VM:
  `echo quit | timeout 25 qemu-system-x86_64 -machine q35 -m 256 -accel tcg \
     -display egl-headless,rendernode=/dev/dri/renderD129 -device virtio-vga-gl -S -monitor stdio`
  Reaching the `(qemu)` prompt = works; timeout = still broken.
- **Do not route guest Vulkan to the dGPU either.** This RTX 4050 has GSP/PMU firmware bugs
  where *any* Vulkan workload crashes or wedges the GPU (OpenGL and CUDA are unaffected). The
  host runs 580xx with `NVreg_EnableGpuFirmware=0` as a deliberate mitigation — do not "upgrade"
  it to 610.x, which is open-module-only and requires the buggy GSP firmware. Full diagnosis:
  `~/nvidia_issue/README.md`. This rules out the QEMU Venus (Vulkan) path on NVIDIA regardless
  of whether the EGL hang above is ever fixed.
- The RTX 4050 is a **render-offload device with no display wired to it** (all `card0`
  connectors report `disconnected`; the panel is on `card1`/i915 `eDP-1`). Real NVIDIA
  acceleration would need VFIO passthrough, which `qemu:///session` cannot do (needs
  `qemu:///system`, and the host loses the GPU).
- Verify acceleration **inside the guest** with `glxinfo -B` — it should report `virgl`, not
  `llvmpipe`. If it says llvmpipe, check the host QEMU log at
  `~/.cache/libvirt/qemu/log/omarchy-vm.log`.
- The install ISO was a partial download originally (1.5 GB); it was resumed with `wget -c` and verified against the official SHA256 `69cbb4e10d98ad831c3c9f245b5757a9d1fedfd0c9592780e977d6f950dea8c3`.

## Desktop themes

Two custom themes live on the host, each with its own `README.md`:

| Theme | Directory | Look |
|-------|-----------|------|
| **Dragon Ball Z** *(active)* | `~/omarchy-vm/dragon-ball-z-theme/` | Goku's gi orange on warm charcoal, Super Saiyan gold, Kamehameha blue. Ray-burst aura wallpapers. |
| **Aurora** | `~/omarchy-vm/aurora-theme/` | Deep midnight, teal → violet accents, mesh-gradient wallpapers. |

Both are installed in the guest and appear in the theme switcher alongside the
22 built-ins from `/usr/share/omarchy/themes`.

- Install / reinstall inside the guest: `<theme-dir>/install.sh` (also applies the VM's
  software-cursor workaround)
- Switch: `omarchy-theme-set "Dragon Ball Z"` · `omarchy-theme-set aurora`
- Back to stock: `omarchy-theme-set tokyo-night`
- Cycle a theme's four wallpapers: `omarchy-theme-bg-next`
- Restore the stock Hyprland look'n'feel:
  `cp ~/.config/hypr/looknfeel.lua.bak-* ~/.config/hypr/looknfeel.lua && hyprctl reload`

Two files are **shared** by whichever theme is active rather than owned by one:
`~/.config/hypr/looknfeel.lua` (rounding, gaps, blur, inactive dim, layer blur
rules, animation curves) and `~/.config/omarchy/themed/foot.ini.tpl` (terminal
`alpha=0.86`, so the blur has something to frost). Both ship in `aurora-theme/`,
where they were written first; each theme's `install.sh` copies them only if
they are not already in place.

**`omarchy-theme-set` restarts terminals and the browser** to re-tint them, which
closes whatever is running in them. Applying a theme is not a background-safe
operation on a session you care about.

## Custom config

User configuration lives in `~/git/omarchy_custom_config/` (Hyprland, bash/zsh, waybar, etc.).
