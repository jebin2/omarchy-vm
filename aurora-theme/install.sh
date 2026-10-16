#!/usr/bin/env bash
# Install the Aurora theme into an Omarchy 4.x system. Run this INSIDE the guest.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$HOME/.config/omarchy/themes" "$HOME/.config/omarchy/themed"

# 1. The theme package.
rm -rf "$HOME/.config/omarchy/themes/aurora"
cp -r "$SRC/theme" "$HOME/.config/omarchy/themes/aurora"

# 2. Hyprland look'n'feel: rounding, gaps, blur, dim, animations, layer rules.
if [[ -f $HOME/.config/hypr/looknfeel.lua ]]; then
  cp "$HOME/.config/hypr/looknfeel.lua" "$HOME/.config/hypr/looknfeel.lua.bak-$TS"
  echo "backed up looknfeel.lua -> looknfeel.lua.bak-$TS"
fi
cp "$SRC/looknfeel.lua" "$HOME/.config/hypr/looknfeel.lua"

# 3. Terminal translucency, applied to every theme (not just Aurora).
cp "$SRC/foot.ini.tpl" "$HOME/.config/omarchy/themed/foot.ini.tpl"

omarchy-theme-set aurora
hyprctl reload >/dev/null
echo "Aurora applied. Backgrounds cycle with: omarchy-theme-bg-next"
