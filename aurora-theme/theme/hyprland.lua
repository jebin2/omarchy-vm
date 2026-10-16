-- Aurora window chrome: gradient borders plus a coloured glow on the focused
-- window. Replaces the generated hyprland.lua so the shadow can be themed too;
-- structural values (rounding, gaps, blur) live in ~/.config/hypr/looknfeel.lua.

local active_border_color = { colors = { "rgba(7dcfffee)", "rgba(bb9af7ee)" }, angle = 45 }
local inactive_border_color = "rgba(1a1f3399)"

hl.config({
  general = {
    col = {
      active_border = active_border_color,
      inactive_border = inactive_border_color,
    },
  },

  group = {
    col = {
      border_active = active_border_color,
      border_inactive = inactive_border_color,
    },
  },

  decoration = {
    shadow = {
      enabled = true,
      range = 26,
      render_power = 3,
      offset = { 0, 4 },
      color = "rgba(3a7fbf40)",
      color_inactive = "rgba(00000055)",
    },
  },
})
