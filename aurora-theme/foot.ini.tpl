# Aurora: the stock Omarchy foot palette plus an alpha channel, so
# decoration.blur in looknfeel.lua actually has something to frost.
# User templates in ~/.config/omarchy/themed override the built-in ones and
# survive theme switches -- every theme gets the same translucency.
[colors-dark]
alpha=0.86
foreground={{ foreground_strip }}
background={{ background_strip }}
selection-foreground={{ selection_foreground_strip }}
selection-background={{ selection_background_strip }}

cursor={{ background_strip }} {{ bright_foreground_strip }}

regular0={{ background_strip }}
regular1={{ red_strip }}
regular2={{ green_strip }}
regular3={{ yellow_strip }}
regular4={{ blue_strip }}
regular5={{ purple_strip }}
regular6={{ cyan_strip }}
regular7={{ foreground_strip }}

bright0={{ muted_strip }}
bright1={{ bright_red_strip }}
bright2={{ bright_green_strip }}
bright3={{ bright_yellow_strip }}
bright4={{ bright_blue_strip }}
bright5={{ bright_magenta_strip }}
bright6={{ bright_cyan_strip }}
bright7={{ bright_foreground_strip }}
