{ config, pkgs, lib, ... }:

{
  # Dynamic color theming for host machines
  #
  # This module provides the full walrgb workflow:
  # - walrgb script for changing colors based on wallpapers
  # - RGB hardware integration (asusctl for ASUS, openrgb for others)
  # - Pywalfox for Firefox color sync
  # - Supporting scripts for GTK, Zathura, etc.
  #
  # Usage: walrgb /path/to/wallpaper.jpg

  imports = [ ./base.nix ];

  config = {
    # Add full walrgb workflow scripts
    environment.systemPackages = with pkgs; [
      # Main theming workflow
      (pkgs.writeScriptBin "walrgb" (builtins.readFile ../../scripts/walrgb.sh))
      (pkgs.writeScriptBin "randomwalrgb" (builtins.readFile ../../scripts/randomwalrgb.sh))

      # Supporting scripts
      (pkgs.writeScriptBin "nixwal" (builtins.readFile ../../scripts/nixwal.sh))
      (pkgs.writeScriptBin "wal-gtk" (builtins.readFile ../../scripts/wal-gtk.sh))
      (pkgs.writeScriptBin "zathuracolors" (builtins.readFile ../../scripts/zathuracolors.sh))
      (pkgs.writeScriptBin "deploy-obsidian-config" (builtins.readFile ../../scripts/deploy-obsidian-config.sh))

      # Browser integration
      pywalfox-native

      # RGB hardware control
      asusctl        # For ASUS hardware RGB/keyboard backlight
      openrgb        # For generic RGB devices
    ];

    # Note: The walrgb script orchestrates updates across:
    # - pywal color generation
    # - RGB lighting (asusctl/openrgb)
    # - Polybar restart
    # - Firefox (pywalfox)
    # - GTK themes
    # - Dunst notifications
    # - Zathura PDF reader
    # - GitHub Pages colors (if applicable)
  };
}
