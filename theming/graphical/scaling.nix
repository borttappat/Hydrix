# Build-time UI values: scaling.computed.* mirrors the unified ui.* options
# and derives shared values (panelRadius, shadow) so modules do not repeat
# the math. Wayland modules read these at build time; scaling.json is an
# X11-only artifact and is not read under Hyprland.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.graphical;
  ui = cfg.ui;
  round = x: builtins.floor (x + 0.5);
in {
  options.hydrix.graphical.scaling = {
    # Computed values - aliases to unified ui.* options
    # These are BASE values (not scaled) - actual scaling happens at runtime
    computed = {
      factor = lib.mkOption {
        type = lib.types.float;
        readOnly = true;
        default = 1.0;
        description = "Scale factor placeholder (actual scaling is runtime)";
      };

      gaps = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.gaps;
      };

      border = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.border;
      };

      barPadding = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.barPadding;
      };

      barGaps = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default =
          if ui.barGaps != null
          then ui.barGaps
          else ui.gaps;
        description = "Bar floating margins (falls back to gaps if not set)";
      };

      padding = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.padding;
      };

      paddingSmall = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.paddingSmall;
      };

      cornerRadius = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.cornerRadius;
      };

      # A Hyprland window's visible corner is its rounding plus the border
      # drawn outside it; GTK panels (eww blocks, wofi) sit one px under that
      # so their plain circular corners read the same as the squarer windows.
      panelRadius = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = lib.max 0 (ui.cornerRadius + ui.border - 1);
      };

      # GTK box-shadow for a surface, from that surface's baseline blur (px)
      # and alpha at strength 1.0. `room` is the space the shadow needs around
      # the surface (one px more at the bottom for the 1px drop), 0 when
      # shadows are off.
      shadow = lib.mkOption {
        type = lib.types.functionTo lib.types.attrs;
        readOnly = true;
        default = {
          blur,
          alpha,
        }: let
          s = ui.shadow.strength;
          b = round (blur * s);
        in
          if ui.shadow.enable && s > 0
          then {
            css = "0 1px ${toString b}px rgba(0, 0, 0, ${toString (lib.min 1.0 (alpha * s))})";
            room = b;
            roomBottom = b + 1;
          }
          else {
            css = "none";
            room = 0;
            roomBottom = 0;
          };
      };

      rofiWidth = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.rofiWidth;
      };

      rofiHeight = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.rofiHeight;
      };
    };
  };
}
