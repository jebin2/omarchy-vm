# Dragon Ball Z — an Omarchy 4.x desktop theme

Goku's gi orange over warm charcoal, Super Saiyan gold, Kamehameha blue.
Built for the Omarchy 4.0.2 guest in this VM; portable to any Omarchy 4.x system.

## Install (inside the guest)

    ./install.sh

Or, if the theme is already copied in: `omarchy-theme-set "Dragon Ball Z"`

## The palette

| Role | Colour | Where it comes from |
|------|--------|---------------------|
| `accent` / `orange` | `#ff7a1a` | Goku's gi |
| `yellow` | `#ffc93c` | Super Saiyan gold |
| `cyan` | `#4fb8ff` | Kamehameha ki |
| `blue` | `#4a90e2` | the gi's undershirt |
| `green` | `#7ec850` | Namek |
| `red` | `#e8503c` | Kaio-ken |
| `magenta` | `#b07ae0` | Frieza / Beerus |
| `background` | `#171310` | warm charcoal, so the orange reads as heat |

## What's in it

| File | Applies to |
|------|-----------|
| `theme/colors.toml` | The single source of truth. Omarchy generates foot, ghostty, alacritty, kitty, btop, neovim, helix, chromium, vscode, obsidian and the whole shell palette from these ~25 keys. |
| `theme/hyprland.lua` | Orange→gold 45° gradient border on the focused window plus a warm glow — the Super Saiyan aura. |
| `theme/btop.theme` | Quiet warm box borders; meters ramp gold → orange → Kaio-ken red as load rises. `main_bg=""` makes btop inherit the terminal's alpha. |
| `theme/shell.bar.toml` | Bar at 62% alpha, 30px. Alert modules stay red — that's a semantic state, not a brand colour. |
| `theme/shell.lock.toml` | Lock-screen input card. |
| `theme/shell.popups.toml` | Flyouts and notifications at 92% alpha. |
| `theme/icons.theme` | `Yaru-yellow`. |
| `theme/chromium.theme` | Chromium frame tint. |
| `theme/backgrounds/*.jpg` | Four 3840×2400 wallpapers (below). Cycle with `omarchy-theme-bg-next`. |
| `theme/preview.png`, `unlock.png`, `preview-unlock.png` | Theme-switcher card and the gold lock-screen wordmark. |

## Wallpapers

| File | What it is |
|------|-----------|
| `1-super-saiyan.jpg` | Gold ray burst from low centre — the ascension aura. |
| `2-kamehameha.jpg` | A white-hot ki core off to the right with blue rays. |
| `3-namek-sky.jpg` | Calm green field, no rays. The quiet one. |
| `4-ki-charge.jpg` | A slow orange glow gathering. The subtlest one. |

Regenerate with:

    python3 generate-backgrounds.py theme/backgrounds

Two techniques in that script: `mesh()` upscales a tiny hex grid through a
Gaussian filter for calm colour fields, and `burst()` bends random vertical
stripes into rays with `-distort Polar`, masked by a radial falloff.

**Gamma is the knob that matters.** In the falloff masks, gamma **below 1**
tightens the glow to a small bright core; **above 1** floods the whole frame and
blows the wallpaper out. The first pass of these used `gamma=2.6` and was
unusable.

## Shared with the other themes

Two files are **not** owned by this theme and apply to whichever theme is active:

- `~/.config/hypr/looknfeel.lua` — rounding, gaps, blur, inactive dim, layer
  blur rules and animation curves; the installer also enables software cursors
  for the VM's SPICE display.
- `~/.config/omarchy/themed/foot.ini.tpl` — gives foot `alpha=0.86` so the blur
  has something to frost.

Both ship in `../aurora-theme/`. `install.sh` copies them only if they aren't
already in place.

## Notes

- `colors.toml` carries two non-standard keys, `hyprland_active_border` and
  `hyprland_inactive_border`. Omarchy's `shell.toml.tpl` reads them, so window
  borders, popups, notifications, the launcher and the lock input all share one
  gradient definition.
- A theme directory written by hand (not cloned from git) may ship Lua and
  terminal configs. A theme installed with `omarchy theme install` may not.
- `omarchy-theme-set` restarts terminals and the browser to re-tint them.
  Anything running in them is closed.
