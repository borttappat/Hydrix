# Tamzen Font Profile
#
# Tamzen is a bitmap font — main size 13 at 96 DPI.
# Per-app relations scale from there. DPI scaling applies on top.
# maxSizes caps prevent scaling past sizes where Tamzen renders well.
#
#   App        Relation  → Standalone  → Max Cap
#   alacritty  0.95      → 11.0       → 11.5
#   polybar    1.0       → 12         → 13.5
#   rofi       0.95      → 11         → 11
#   dunst      0.95      → 11         → 11
#   firefox    1.5       → 17         → 17
#   gtk        1.0       → 12         → 12

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
        polybar = 1.0;
        rofi = 0.75;
        dunst = 0.75;
        firefox = 1.3;
        gtk = 1.0;
      };

      maxSizes = lib.mkDefault {
        alacritty = 12.0;
        polybar = 13.5;
        rofi = 11;
        dunst = 11;
        firefox = 17;
        gtk = 12;
      };

      familyOverrides = lib.mkDefault {};
    };

    hydrix.graphical.scaling = {
      standaloneScaleFactor = lib.mkDefault 0.9;
    };

    hydrix.graphical.ui = {
      # Tamzen is compact — reduced bar height
      barHeightFamilyRelations = lib.mkDefault {
        "Tamzen" = 0.75;
      };
      # Tamzen sits lower than Iosevka — less vertical offset needed
      polybarFontOffset = lib.mkDefault 1;
      # Extra bottom padding so the underline is more visible
      barPadding = lib.mkDefault 1;
    };

    # Bitmap fonts don't work for lockscreen (ImageMagick)
    hydrix.graphical.lockscreen.font = lib.mkDefault "CozetteVector";
  };
}
