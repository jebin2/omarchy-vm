# Omarchy VM

**Try [Omarchy](https://omarchy.org) without wiping your laptop.**
One command runs the real Omarchy installer in a window on your current Linux. Your system stays exactly as it is.

- Smooth, GPU-accelerated Hyprland, not a laggy VM
- Copy-paste works both ways
- The screen fits your monitor
- No root needed day to day

## Quick start

```bash
git clone https://github.com/jebin2/omarchy-vm.git ~/omarchy-vm
~/omarchy-vm/omarchy install
```

1. Go through the Omarchy installer in the window that opens.
2. Click **Reboot Now** at the end.
3. The window closes while setup finishes. When it reopens, Omarchy is ready.

The first run may ask for your sudo password to install a few packages, and it downloads the Omarchy ISO (~6 GB).

## Commands

| Command | What it does |
| :--- | :--- |
| `omarchy open` | Start Omarchy and open its window |
| `omarchy stop` | Shut it down |
| `omarchy reset` | Erase it and install again |
| `omarchy delete` | Remove it completely |
| `omarchy install` | Create it (first time only) |

You can also start it from your app launcher: **Omarchy VM**.

## Requirements

- Linux with KVM (virtualization enabled in BIOS)
- An Intel or AMD GPU for smooth graphics. NVIDIA-only laptops work, but without acceleration.
- About 50 GB of free disk space
- Arch, Fedora, Debian or Ubuntu (other distros need the packages installed by hand)

## Good to know

- **Release the mouse:** `Ctrl+Alt+G`. **Toggle fullscreen:** `Ctrl+Alt+F`.
- **Encrypted disk:** the first boot unlocks by itself. After that, type your disk password in the window, like on a real machine.
- **SSH into it:** `ssh -p 2222 <user>@127.0.0.1`
- **Already on Omarchy?** It has its own `omarchy` command, so run `~/omarchy-vm/omarchy` instead.
- **No clicking at all:** `omarchy install --auto` asks for a username and password in the terminal and installs everything out of sight.

## How it works

The VM runs on KVM with virgl 3D acceleration and a SPICE display. If the SPICE viewer crashes or remains stuck during startup, the host switches the VM to VNC with standard VGA and reopens it; this fallback has no 3D acceleration. The host remembers a successful fallback across delete/reset, so later installs open directly with VNC. While you go through the installer, the host prepares the new system through the installer's guest agent: it adds your SSH key, a temporary sudo grant and, for an encrypted disk, a one-time unlock key. After Reboot Now, it installs the guest tools (clipboard sync, cursor fix, screen fit) over SSH, then removes the temporary grant and key.
