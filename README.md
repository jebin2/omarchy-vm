# Omarchy Linux VM — Automated Setup & Control

High-performance, hardware-accelerated **Omarchy Linux** (Arch + Hyprland / Wayland) virtual machine on KVM/libvirt user session (`qemu:///session`).

Features near-native **virgl 3D OpenGL acceleration**, **SPICE low-latency display**, **bi-directional Wayland↔XWayland clipboard sharing**, **dynamic host screen fitting**, and **SSH port forwarding**.

---

## ⚡ Quick Start

```bash
git clone https://github.com/jebin2/omarchy-vm.git ~/omarchy-vm
~/omarchy-vm/omarchy install
```

Choose a username and password when asked, and that's all the input it needs. It installs any missing host packages (this may ask for your sudo password once), downloads the latest Omarchy ISO, installs it hands-free, sets it up, and opens it fullscreen on your desktop.

After that, `omarchy open` and `omarchy stop` work from anywhere.

### Requirements
- A Linux host with KVM (hardware virtualization enabled in BIOS: VT-x / AMD-V).
- An Intel or AMD GPU for smooth 3D-accelerated graphics. NVIDIA-only machines still work, but without 3D acceleration.
- About 50 GB of free disk space: a ~6 GB ISO plus a virtual disk that can grow to 40 GB.
- Arch, Fedora or Debian/Ubuntu for automatic package install (`pacman`, `dnf` or `apt`). Other distros need the packages listed below installed by hand.

## 🕹️ Commands

| Command | What it does |
| :--- | :--- |
| `omarchy install [ISO]` | Create the VM and install Omarchy hands-free. Downloads and verifies the latest ISO from omarchy.org unless you pass one |
| `omarchy open` | Start the VM (if needed) and open its window |
| `omarchy stop` | Shut the VM down cleanly (guest agent → ACPI → force) |
| `omarchy reset [ISO]` | Erase the VM and install Omarchy again from scratch |
| `omarchy delete` | Erase the VM completely (disk, firmware state, app launcher entry). The `omarchy` command and downloaded ISOs are kept |

`reset` and `delete` ask before erasing anything; `-y` skips the prompt. `install --manual` uses the interactive Omarchy installer instead of the hands-free one. `OMARCHY_ENCRYPT=1 omarchy install` creates an encrypted disk, which you unlock in the VM window at each boot.

After the first install, `omarchy` is on your `PATH` (`~/.local/bin/omarchy`), and **"Omarchy VM"** shows up in your app launcher. On an Omarchy host, which has its own `omarchy` command, the shortcut is skipped; run `~/omarchy-vm/omarchy` instead.

SSH into the guest: `ssh -p 2222 <user>@127.0.0.1` (your host key is already authorized).

### What `install` does
- Checks and offers to install the host packages it needs (`qemu`, `libvirt`, `virt-viewer`, `edk2-ovmf`, `python3`, `curl`, `xorriso`, `openssl`).
- Starts the libvirt user session (`virtqemud.socket`); no root is needed day to day.
- Binds **Intel/AMD virgl** 3D acceleration, skipping NVIDIA to avoid driver freezes.
- Creates a 40 GB sparse disk (`images/omarchy.qcow2`) and defines the `omarchy-vm` domain.
- **Installs Omarchy unattended** through the ISO's built-in autoinstall. The installer answers ride on a small `CIDATA`-labeled drive, the same mechanism Omarchy uses for headless installs, and the installer authorizes your host SSH key.
- **Provisions the guest over SSH**: `omarchy update -y`, guest tools (`qemu-guest-agent`, `spice-vdagent`, `wl-clipboard`, `xclip`, `clipnotify`), the clipboard bridge, the SPICE cursor fix and desktop autologin.
- Reboots the guest and fits its screen to your monitor.

Sudo inside the guest uses a temporary passwordless grant. It is revoked when setup finishes and expires on its own after an hour. The installer drive holds a hash of your password and is deleted once the install completes. If the hands-free path stops partway, `install` falls back to the manual steps: run `bash <(curl -fsSL http://10.0.2.2:8765)` in a guest terminal.

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
│   ├── autoinstall.sh       # Hands-free install (CIDATA drive) & SSH-driven guest setup
│   └── provisioner.py       # Standalone local HTTP provisioning server
│
├── guest/                   # In-guest onboarding assets
│   ├── setup.sh             # In-guest setup script (bash <(curl -fsSL http://10.0.2.2:8765))
│   ├── clipboard-bridge     # XWayland ↔ Wayland clipboard sync daemon
│   └── clipboard-bridge.service # Systemd user unit for clipboard bridge
│
└── images/                  # Virtual disk (omarchy.qcow2) and domain XML
```
