# Aurora — an Omarchy 4.x desktop theme

Deep midnight base, teal → violet aurora accents, glass shell surfaces.
Built for the Omarchy 4.0.2 guest in this VM; portable to any Omarchy 4.x system.

## Install (inside the guest)

    ./install.sh

## What's in it

| File | Applies to |
|------|-----------|
| `theme/colors.toml` | The single source of truth. Omarchy generates foot, ghostty, alacritty, kitty, btop, neovim, helix, chromium, vscode, obsidian and the whole shell palette from these ~25 keys. |
| `theme/hyprland.lua` | Teal→violet 45° gradient border on the focused window, plus a coloured glow (`decoration.shadow`). |
| `theme/btop.theme` | Quiet single-hue box borders instead of the stock per-box rainbow. `main_bg=""` makes btop inherit the terminal's alpha, so it goes glass too. |
| `theme/shell.bar.toml` | Bar at 62% alpha, 30px tall. Merged into the generated `shell.toml` as a section override. |
| `theme/shell.lock.toml` | Lock-screen input card. |
| `theme/shell.popups.toml` | Flyouts and notifications at 92% alpha. |
| `theme/icons.theme` | `Yaru-purple`. |
| `theme/chromium.theme` | Chromium frame tint. |
| `theme/backgrounds/*.jpg` | Four 3840×2400 mesh-gradient wallpapers with film grain. Cycle with `omarchy-theme-bg-next`. |
| `theme/preview.png`, `unlock.png`, `preview-unlock.png` | Theme-switcher card and lock-screen wordmark. |
| `looknfeel.lua` | → `~/.config/hypr/looknfeel.lua`. Rounding 10 (squircle), gaps 6/12, blur, 10% inactive dim, layer rules that frost the bar/dock/menus, snappier animation curves, and software cursors for the VM's SPICE display. |
| `foot.ini.tpl` | → `~/.config/omarchy/themed/foot.ini.tpl`. Adds `alpha=0.86` to the stock foot palette so `decoration.blur` has something to frost. Applies to **every** theme, not just Aurora. |

## Regenerating the wallpapers

    python3 generate-backgrounds.py theme/backgrounds

Edit the hex grids in the script to retune. Each is a tiny pixel grid
(4×3 to 5×5) upscaled with a Gaussian filter and blurred, then grained.

## Notes

- `colors.toml` carries two non-standard keys, `hyprland_active_border` and
  `hyprland_inactive_border`. Omarchy's `shell.toml.tpl` reads them, so the
  window border, popup borders, notifications, launcher and lock input all
  share one gradient definition.
- A theme directory written by hand (not cloned from git) may ship Lua and
  terminal configs. A theme installed with `omarchy theme install` may not —
  `omarchy-theme-set` strips those, since they would run code.
- `omarchy-theme-set` restarts terminals and the browser to re-tint them.
  Anything running in them is closed.
