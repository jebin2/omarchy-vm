#!/usr/bin/env bash
# Install the Dragon Ball Z theme into an Omarchy 4.x system. Run INSIDE the guest.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$HOME/.config/omarchy/themes"
rm -rf "$HOME/.config/omarchy/themes/dragon-ball-z"
cp -r "$SRC/theme" "$HOME/.config/omarchy/themes/dragon-ball-z"

# The glass/rounding layer (looknfeel.lua + the foot alpha template) is shared by
# every theme, not owned by this one. It ships next door with the Aurora theme;
# install it here only if it isn't already in place.
SHARED="$SRC/../aurora-theme"
if [[ -d $SHARED ]]; then
  if [[ ! -f $HOME/.config/omarchy/themed/foot.ini.tpl ]]; then
    mkdir -p "$HOME/.config/omarchy/themed"
    cp "$SHARED/foot.ini.tpl" "$HOME/.config/omarchy/themed/foot.ini.tpl"
    echo "installed shared foot.ini.tpl (terminal translucency)"
  fi
  if ! grep -q "layer_rule" "$HOME/.config/hypr/looknfeel.lua" 2>/dev/null; then
    cp "$HOME/.config/hypr/looknfeel.lua" \
       "$HOME/.config/hypr/looknfeel.lua.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    cp "$SHARED/looknfeel.lua" "$HOME/.config/hypr/looknfeel.lua"
    echo "installed shared looknfeel.lua (rounding, gaps, blur, animations)"
  fi
fi

# The QEMU virtio-gpu hardware cursor plane is invisible through SPICE.
# Keep this fix even when an existing shared looknfeel.lua was preserved.
LOOKNFEEL="$HOME/.config/hypr/looknfeel.lua"
if ! grep -Eq 'no_hardware_cursors[[:space:]]*=[[:space:]]*true' "$LOOKNFEEL" 2>/dev/null; then
  cat >> "$LOOKNFEEL" <<'LUA'

-- QEMU virtio-gpu cursor plane workaround for SPICE.
hl.config({ cursor = { no_hardware_cursors = true } })
LUA
  echo "enabled software cursor for the VM's SPICE display"
fi

omarchy-theme-set "Dragon Ball Z"
hyprctl reload >/dev/null
echo "Dragon Ball Z applied. Backgrounds cycle with: omarchy-theme-bg-next"
