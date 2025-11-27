# Static color scheme module
# Each VM profile can set colors to visually differentiate
{ config, lib, ... }:

with lib;

{
  options.hydrix.colors = {
    # Base colors
    background = mkOption {
      type = types.str;
      default = "#0a0e14";
      description = "Background color";
    };

    foreground = mkOption {
      type = types.str;
      default = "#b3b1ad";
      description = "Foreground/text color";
    };

    # Accent color (main differentiation point)
    accent = mkOption {
      type = types.str;
      default = "#73d0ff";
      description = "Accent color for borders, highlights, etc.";
    };

    # 16 color palette (for compatibility)
    color0 = mkOption { type = types.str; default = "#01060e"; };
    color1 = mkOption { type = types.str; default = "#ea6c73"; };
    color2 = mkOption { type = types.str; default = "#91b362"; };
    color3 = mkOption { type = types.str; default = "#f9af4f"; };
    color4 = mkOption { type = types.str; default = "#53bdfa"; };
    color5 = mkOption { type = types.str; default = "#fae994"; };
    color6 = mkOption { type = types.str; default = "#90e1c6"; };
    color7 = mkOption { type = types.str; default = "#c7c7c7"; };
    color8 = mkOption { type = types.str; default = "#686868"; };
    color9 = mkOption { type = types.str; default = "#ea6c73"; };
    color10 = mkOption { type = types.str; default = "#91b362"; };
    color11 = mkOption { type = types.str; default = "#f9af4f"; };
    color12 = mkOption { type = types.str; default = "#53bdfa"; };
    color13 = mkOption { type = types.str; default = "#fae994"; };
    color14 = mkOption { type = types.str; default = "#90e1c6"; };
    color15 = mkOption { type = types.str; default = "#ffffff"; };
  };

  config = {
    # Export colors as environment variables for scripts
    environment.variables = {
      HYDRIX_BG = config.hydrix.colors.background;
      HYDRIX_FG = config.hydrix.colors.foreground;
      HYDRIX_ACCENT = config.hydrix.colors.accent;
    };
  };
}
