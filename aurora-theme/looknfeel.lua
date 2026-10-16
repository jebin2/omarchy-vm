-- Aurora look'n'feel. Structure only -- all colour lives in the theme
-- (~/.config/omarchy/themes/aurora). Loaded after the Omarchy defaults, so
-- every hl.config below overrides default/hypr/looknfeel.lua.

hl.config({
  general = {
    gaps_in = 6,
    gaps_out = 12,
    border_size = 2,
  },

  -- QEMU's virtio-gpu hardware cursor plane is not visible through SPICE.
  cursor = {
    no_hardware_cursors = true,
  },

  decoration = {
    -- rounding_power > 2 gives a squircle rather than a circular arc.
    rounding = 10,
    rounding_power = 3.0,

    active_opacity = 1.0,
    inactive_opacity = 0.97,

    dim_inactive = true,
    dim_strength = 0.10,
    dim_special = 0.4,

    blur = {
      enabled = true,
      size = 5,
      passes = 2,
      new_optimizations = true,
      ignore_opacity = true,
      xray = false,
      noise = 0.015,
      contrast = 1.05,
      brightness = 0.85,
      vibrancy = 0.25,
      vibrancy_darkness = 0.2,
      popups = true,
      popups_ignorealpha = 0.4,
    },
  },
})

-- Frost the shell surfaces so the bar, dock and menus read as glass over the
-- wallpaper. Without these the decoration.blur above only affects windows.
hl.layer_rule({ match = { namespace = "omarchy-bar" }, blur = true, ignore_alpha = 0.25 })
hl.layer_rule({ match = { namespace = "omarchy-dock" }, blur = true, ignore_alpha = 0.25 })
hl.layer_rule({
  match = { namespace = "^(omarchy-menu|omarchy-launcher|omarchy-emojis|omarchy-clipboard|omarchy-image-selector|omarchy-keyboard-panel|omarchy-notifications|omarchy-popup)$" },
  blur = true,
  ignore_alpha = 0.3,
})

-- Slightly quicker, softer motion than the stock curves.
hl.curve("auroraOut", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
hl.curve("auroraIn", { type = "bezier", points = { { 0.4, 0 }, { 0.2, 1 } } })

hl.animation({ leaf = "windows", enabled = true, speed = 4.2, bezier = "auroraOut" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.6, bezier = "auroraOut", style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.4, bezier = "auroraIn", style = "popin 92%" })
hl.animation({ leaf = "border", enabled = true, speed = 6.5, bezier = "auroraOut" })
hl.animation({ leaf = "layers", enabled = true, speed = 4, bezier = "auroraOut" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4.5, bezier = "auroraOut", style = "slidefade 15%" })
