# Iosevka Font Profile (default baseline)
#
# Iosevka is the reference font — main size 10 at 96 DPI.
# All relations are 1.0 except firefox which needs slightly larger text.

{ config, lib, ... }:

let
  isActive = config.hydrix.graphical.font._resolvedProfile == "iosevka";
in {
  config = lib.mkIf (config.hydrix.graphical.enable && isActive) {
    hydrix.graphical.font = {
      size = lib.mkDefault 11;

      relations = lib.mkDefault {
        alacritty = 1.1;
        waybar    = 1.28;  # floor(11 * 1.28) = 14px
        polybar   = 0.8;
        rofi      = 1.0;
        dunst     = 1.0;
        wofi      = 1.3;
        firefox   = 1.2;
        gtk       = 1.0;
      };
    };

    hydrix.graphical.ui = {
      barHeightFamilyRelations = lib.mkDefault { "Iosevka" = 1.1; };
    };
  };
}
