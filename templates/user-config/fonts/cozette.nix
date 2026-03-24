# CozetteVector Font Profile
#
# Cozette is a bitmap-style vector font — main size 13 at 96 DPI.

{ config, lib, ... }:

let
  isActive = config.hydrix.graphical.font._resolvedProfile == "cozette";
in {
  config = lib.mkIf (config.hydrix.graphical.enable && isActive) {
    hydrix.graphical.font = {
      size = lib.mkDefault 13;

      relations = lib.mkDefault {
        alacritty = 1.0;
        polybar = 1.0;
        rofi = 1.0;
        dunst = 1.0;
        firefox = 1.2;
        gtk = 1.0;
      };
    };

    hydrix.graphical.ui = {
      barHeightFamilyRelations = lib.mkDefault {
        "CozetteVector" = 0.85;
      };
    };

    hydrix.graphical.lockscreen.font = lib.mkDefault "CozetteVector";
  };
}
