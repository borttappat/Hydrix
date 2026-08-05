# Tamzen Font Profile
#
# Tamzen is a bitmap font — main size 13 at 96 DPI.
# Per-app relations scale from there. DPI scaling applies on top.

{ config, lib, ... }:

let
  isActive = config.hydrix.graphical.font._resolvedProfile == "tamzen";
in {
  config = lib.mkIf (config.hydrix.graphical.enable && isActive) {
    hydrix.graphical.font = {
      # Main size — the base all relations scale from
      size = lib.mkDefault 13;

      relations = lib.mkDefault {
        alacritty = 1.0;
        dunst = 0.75;
        wofi = 1.2;
        firefox = 1.3;
        gtk = 1.0;
      };

      familyOverrides = lib.mkDefault {};
    };

    hydrix.graphical.scaling = {
      standaloneScaleFactor = lib.mkDefault 0.9;
    };

    hydrix.graphical.ui = {
      # Extra bottom padding so the underline is more visible
      barPadding = lib.mkDefault 1;
    };

    # Bitmap fonts don't work for lockscreen (ImageMagick)
    hydrix.graphical.lockscreen.font = lib.mkDefault "CozetteVector";
  };
}
