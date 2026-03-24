# Graphical Environment Packages
#
# WM, theming, and X11 packages required for the graphical environment.
# Only included when hydrix.graphical.enable = true.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
in {
  config = lib.mkIf cfg.enable {
    # Fonts (populated by hydrix.graphical.font.packages option)
    fonts.packages = config.hydrix.graphical.font.packages;

    environment.systemPackages = with pkgs; [
      # Window Manager components
      polybar
      rofi
      picom

      # Theming
      wpgtk
      pywal
      pywalfox-native

      # Image handling
      imagemagick
      feh

      # Screenshots
      scrot
      flameshot

      # Lockscreen
      i3lock-color
      i3lock-fancy

      # X11 utilities
      xdotool
      unclutter       # Hide cursor when idle
      xcape           # Modifier key tap actions
      brightnessctl
      libvibrant      # Saturation/vibrancy control (vibrant-cli)

      # X11 core
      xorg.xinit
      xorg.xrdb
      xorg.xorgserver
      xorg.xmodmap
      xorg.xmessage
      xorg.xcursorthemes
      xorg.xdpyinfo

      # Audio
      pulseaudioFull
    ];
  };
}
