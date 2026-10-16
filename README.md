# Omarchy Linux VM — Automated Setup & Control

High-performance, hardware-accelerated **Omarchy Linux** (Arch + Hyprland / Wayland) virtual machine on KVM/libvirt user session (`qemu:///session`).

Features near-native **virgl 3D OpenGL acceleration**, **SPICE low-latency display**, **bi-directional Wayland↔XWayland clipboard sharing**, **dynamic host screen fitting**, and **SSH port forwarding**.

---

## ⚡ Quick Start (One Command Setup)

### 1. Run Setup on Host
Clone this repo and run the automated setup engine:

```bash
cd ~/omarchy-vm
./setup.sh
```

`setup.sh` automatically:
- Checks and offers to install required packages (`qemu`, `libvirt`, `virt-viewer`, `edk2-ovmf`, `python3`, `curl`).
- Starts libvirt user session services (`virtqemud.socket`).
- Inspects GPU render nodes and binds **Intel/AMD virgl** (safely skipping NVIDIA to avoid driver freezes).
- Auto-locates OVMF UEFI firmware and the Omarchy ISO.
- Creates a 40 GB sparse virtual disk (`images/omarchy.qcow2`).
- Synthesizes the libvirt domain XML and defines `omarchy-vm`.
- Installs the KDE/GNOME application shortcut and `~/.local/bin/omarchy` CLI command.
- Starts the local provisioning server and launches the VM in `virt-viewer`.

### 2. Complete Guest Installation & Onboarding
1. Follow the standard Omarchy graphical installer in the `virt-viewer` window.
2. Once installed, reboot into the installed system.
3. Open a terminal in Omarchy (**Super + Enter** or launch `foot`) and paste:

```bash
bash <(curl -fsSL http://10.0.2.2:8765)
```

(If you set `OMARCHY_PROVISION_PORT` on the host, use that port instead — the host prints the exact command.)

This single command automatically:
- Installs guest packages (`openssh`, `qemu-guest-agent`, `spice-vdagent`, `wl-clipboard`, `xclip`, `clipnotify`).
- Enables `sshd`, guest agent, and the clipboard bridge service.
- Authorizes your host's SSH key.
- Applies the software cursor workaround for SPICE.
- Signals the host, which automatically resizes the guest screen to match your monitor resolution.

---

## 🕹️ Unified Control CLI (`omarchy`)

Once installed, manage the VM using `./omarchy` or the global shortcut `omarchy`:

```bash
omarchy <command>
```

| Command | Action |
| :--- | :--- |
| `up` | Start the VM and open the screen in `virt-viewer` (fullscreen) |
| `open` | Open the SPICE display in `virt-viewer` |
| `ssh` | Connect directly into the VM via SSH (`127.0.0.1:2222`) |
| `stop` / `down` | Clean shutdown (Guest Agent → ACPI → Force) |
| `force-stop` | Immediate power off (`virsh destroy`) |
| `fit [RES]` | Match guest screen to host resolution (or custom `RES`, e.g. `1920x1080`) |
| `toggle` | Start and open the display if off, otherwise shut down |
| `status` | Print VM state, guest agent, SSH command, and installer ISO state |
| `eject` | Eject the installer ISO from the VM configuration |
| `reset` | Backup existing virtual disk and launch a clean reinstall |
| `clipboard [-f]` | Check host↔guest clipboard sharing and show (or `-f` follow live) the bridge log |
| `setup ISO --no-backup` | Fresh install: permanently delete any existing VM (no backup, asks to type `PURGE`; `-y` skips), then install |
| `setup --finish` | Shut down, eject the installer ISO, and boot the installed system |
| `provision` | Re-run the host provisioning server for the guest setup script |

Re-running `./setup.sh` on an existing install refreshes the VM configuration without re-attaching the installer ISO.

If another `omarchy` command already exists on your `PATH` (e.g. on an Omarchy host), the `~/.local/bin/omarchy` shortcut is skipped — use `./omarchy` from the repo instead.

You can also launch **"Omarchy VM"** directly from your desktop application launcher (KDE / GNOME / Rofi).

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
├── omarchy                  # Unified control CLI & setup engine
├── setup.sh                 # One-command setup entry point (./omarchy setup)
│
├── lib/                     # Modular host-side libraries
│   ├── common.sh            # Global paths, constants, and logging helpers
│   ├── detect.sh            # System, hardware, and dependency auto-detection
│   ├── vm.sh                # Libvirt domain XML synthesis & lifecycle control
│   └── provisioner.py       # Standalone local HTTP provisioning server
│
├── guest/                   # In-guest onboarding assets
│   ├── setup.sh             # In-guest setup script (bash <(curl -fsSL http://10.0.2.2:8765))
│   ├── clipboard-bridge     # XWayland ↔ Wayland clipboard sync daemon
│   └── clipboard-bridge.service # Systemd user unit for clipboard bridge
│
└── images/                  # Virtual disk (omarchy.qcow2) and domain XML
```
