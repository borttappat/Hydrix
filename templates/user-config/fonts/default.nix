{ config, lib, ... }:
{
  imports = [ ./iosevka.nix ./tamzen.nix ./cozette.nix ];

  config.hydrix.graphical.font.profileMap = {
    "Iosevka" = "iosevka";
    "Tamzen" = "tamzen";
    "tamzen" = "tamzen";
    "CozetteVector" = "cozette";
    "Cozette" = "cozette";
    "JetBrains Mono" = "iosevka";
    "Hack" = "iosevka";
    "Fira Code" = "iosevka";
    "Terminus" = "terminus";
  };
}
