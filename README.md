# Omarchy VM

**Try [Omarchy](https://omarchy.org) without wiping your laptop.** One command gives you the real Omarchy install in a window on your current Linux, and your system stays exactly as it is.

- **The real installer**: you go through Omarchy's own setup screens. Click **Reboot Now** and the host takes over: the window closes, setup finishes in the background, and Omarchy reopens logged in and ready.
- **Smooth, not laggy**: GPU-accelerated Hyprland (virgl 3D on Intel/AMD) over a low-latency SPICE display.
- **Things just work**: copy-paste in both directions, a visible cursor, and a screen sized to your monitor.
- **No root day to day**: it runs in your user's libvirt session. When you're done, `omarchy delete` removes it all.

---

## ⚡ Quick Start

```bash
git clone https://github.com/jebin2/omarchy-vm.git ~/omarchy-vm
~/omarchy-vm/omarchy install
```

It installs any missing host packages (this may ask for your sudo password once), downloads the latest Omarchy ISO, and opens the VM on **Omarchy's own installer**, where you pick the keyboard, user, password and disk encryption yourself. When it shows **Reboot Now**, click it: the window closes, setup finishes in the background with progress in your terminal, and the window reopens on the ready, logged-in desktop. An encrypted disk unlocks itself for that first boot, so there's nothing to type after the installer.

After that, `omarchy open` and `omarchy stop` work from anywhere. With an encrypted disk, later boots ask for your disk password in the VM window, as they would on a real machine.

Inside the window, `Ctrl+Alt+F` toggles fullscreen and `Ctrl+Alt+G` releases the mouse.

### Requirements
- A Linux host with KVM (hardware virtualization enabled in BIOS: VT-x / AMD-V).
- An Intel or AMD GPU for smooth 3D-accelerated graphics. NVIDIA-only machines still work, but without 3D acceleration.
- About 50 GB of free disk space: a ~6 GB ISO plus a virtual disk that can grow to 40 GB.
- Arch, Fedora or Debian/Ubuntu for automatic package install (`pacman`, `dnf` or `apt`). Other distros need the packages listed below installed by hand.

## 🕹️ Commands

| Command | What it does |
| :--- | :--- |
| `omarchy install [ISO]` | Create the VM and install Omarchy through its own installer, then finish setup automatically. Downloads and verifies the latest ISO from omarchy.org unless you pass one |
| `omarchy open` | Start the VM (if needed) and open its window |
| `omarchy stop` | Shut the VM down cleanly (guest agent → ACPI → force) |
| `omarchy reset [ISO]` | Erase the VM and install Omarchy again from scratch |
| `omarchy delete` | Erase the VM completely (disk, firmware state, app launcher entry). The `omarchy` command and downloaded ISOs are kept |

`reset` and `delete` ask before erasing anything; `-y` skips the prompt.

**How the default install works:** the host works through the live installer's guest agent. It gives the installer your host SSH key and reads the username you chose. While the installer's reboot is held for a moment, it puts a temporary sudo grant into the new system and, for an encrypted disk, a one-time unlock key. Setup removes both again.

**Other ways to install:**
- `omarchy install --auto` is hands-free: you type a username and password in the terminal, the install runs out of sight, and the window opens when it's ready. `OMARCHY_ENCRYPT=1 omarchy install --auto` gives it an encrypted disk, which you unlock in the VM window at each boot.
- `omarchy install --manual` is the bare interactive installer: afterwards you run the printed setup command in the guest yourself.

After the first install, `omarchy` is on your `PATH` (`~/.local/bin/omarchy`), and **"Omarchy VM"** shows up in your app launcher. On an Omarchy host, which has its own `omarchy` command, the shortcut is skipped; run `~/omarchy-vm/omarchy` instead.

SSH into the guest: `ssh -p 2222 <user>@127.0.0.1` (your host key is already authorized).

### What `install` does
- Checks and offers to install the host packages it needs (`qemu`, `libvirt`, `virt-viewer`, `edk2-ovmf`, `python3`, `curl`, `xorriso`, `openssl`).
- Starts the libvirt user session (`virtqemud.socket`); no root is needed day to day.
- Binds **Intel/AMD virgl** 3D acceleration, skipping NVIDIA to avoid driver freezes.
- Creates a 40 GB sparse disk (`images/omarchy.qcow2`) and defines the `omarchy-vm` domain.
- **Runs Omarchy's installer** in the VM window and prepares the first boot behind the scenes when it finishes (see above). With `--auto`, the installer answers ride on a small `CIDATA`-labeled drive instead, the same mechanism Omarchy uses for headless installs.
- **Provisions the guest over SSH**: `omarchy update -y`, guest tools (`qemu-guest-agent`, `spice-vdagent`, `wl-clipboard`, `xclip`, `clipnotify`), the clipboard bridge, the SPICE cursor fix and desktop autologin.
- Applies it all to the running desktop (no reboot) and fits the screen to your monitor.

Sudo inside the guest uses a temporary passwordless grant. It is revoked when setup finishes and expires on its own after an hour. With `--auto`, the installer drive holds a hash of your password and is deleted once the install completes. If automatic setup stops partway, `install` falls back to the manual steps: run `bash <(curl -fsSL http://10.0.2.2:8765)` in a guest terminal.

---

## 🛠️ Architecture & Technical Details

- **Hypervisor**: KVM via unprivileged libvirt user session (`qemu:///session`). Does not require root privileges for daily usage.
- **Display**: SPICE protocol listening on loopback (`127.0.0.1:auto`), opened fullscreen with `virt-viewer` (`Ctrl+Alt+F` toggles fullscreen, `Ctrl+Alt+G` releases mouse pointer).
- **3D Acceleration**: virgl OpenGL rendering on the host iGPU (`/dev/dri/renderD128`) via `egl-headless` and `virtio-vga-gl`.
- **GPU Safety**: Proprietary NVIDIA render nodes are intentionally excluded. Testing revealed that passing NVIDIA nodes to QEMU EGL causes unrecoverable initialization hangs (`libvirglrenderer` fails to load).
- **Clipboard Sharing**: Uses a dedicated `spicevmc` channel (`com.redhat.spice.0`). Because `spice-vdagent` runs on XWayland, the guest runs `vm-clipboard-bridge` (a lightweight user systemd service using `clipnotify` + `wl-clipboard` + `xclip`) to maintain seamless two-way sync between XWayland and native Wayland clipboards.
- **Dynamic Resolution**: Supports multiple desktop environments on the host (`kscreen-doctor` for KDE, `hyprctl` for Hyprland, `wlr-randr` for wlroots, `swaymsg` for Sway, and `xrandr` for X11). Sends dynamic resize requests to Hyprland in the guest and persists them into `~/.config/hypr/monitors.lua`.
- **Network & SSH**: User-mode NAT (SLIRP) configured with host port forwarding: `127.0.0.1:2222 -> guest:22`.

---

## 📁 Modular Repository Architecture

```
omarchy-vm/
├── omarchy                  # CLI: install, open, stop, reset, delete
│
├── lib/                     # Modular host-side libraries
│   ├── common.sh            # Global paths, constants, and logging helpers
│   ├── detect.sh            # System, hardware, and dependency auto-detection
│   ├── vm.sh                # Libvirt domain XML synthesis & lifecycle control
│   ├── autoinstall.sh       # Install flows (guided, --auto) & SSH-driven guest setup
│   └── provisioner.py       # Standalone local HTTP provisioning server
│
├── guest/                   # In-guest onboarding assets
│   ├── setup.sh             # In-guest setup script (bash <(curl -fsSL http://10.0.2.2:8765))
│   ├── clipboard-bridge     # XWayland ↔ Wayland clipboard sync daemon
│   └── clipboard-bridge.service # Systemd user unit for clipboard bridge
│
└── images/                  # Virtual disk (omarchy.qcow2) and domain XML
```
