-- Dragon Ball Z window chrome: the focused window carries a gi-orange to
-- Super-Saiyan-gold aura, with a warm glow bleeding out behind it. Structural
-- values (rounding, gaps, blur) live in ~/.config/hypr/looknfeel.lua.

local active_border_color = { colors = { "rgba(ff7a1aee)", "rgba(ffc93cee)" }, angle = 45 }
local inactive_border_color = "rgba(2e241c99)"

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
      range = 30,
      render_power = 3,
      offset = { 0, 4 },
      color = "rgba(ff8a2a4d)",
      color_inactive = "rgba(00000059)",
    },
  },
})
