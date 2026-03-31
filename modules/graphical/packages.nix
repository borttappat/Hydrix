# Graphical Environment Packages
#
# WM, theming, and X11 packages required for the graphical environment.
# Only included when hydrix.graphical.enable = true.
#
# Three tiers:
#   microvm     - theming + audio only (xpra-forwarded apps, no local WM)
#   standalone  - full WM environment (libvirt VMs with own desktop)
#   host        - adds hardware controls (lockscreen, brightness, saturation)
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  isHost = config.hydrix.vmType == null || config.hydrix.vmType == "host";
  isMicrovm = !isHost && !cfg.standalone;
in {
  config = lib.mkIf cfg.enable {
    # Fonts (populated by hydrix.graphical.font.packages option)
    fonts.packages = config.hydrix.graphical.font.packages;

    environment.systemPackages = with pkgs; [
      # All tiers: theming and color management
      wpgtk
      pywal
      pywalfox-native
      imagemagick
      feh

      # All tiers: X11 resources (pywal color reload)
      xorg.xrdb

      # All tiers: audio
      pulseaudioFull
    ] ++ lib.optionals (!isMicrovm) [
      # Standalone + host: full WM environment
      polybar
      rofi
      picom
      xdotool
      unclutter
      xcape
      scrot
      flameshot
      xorg.xmodmap
      xorg.xmessage
      xorg.xcursorthemes
      xorg.xdpyinfo
    ] ++ lib.optionals isHost [
      # Host only: lockscreen, hardware display controls, X server
      i3lock-color
      i3lock-fancy
      brightnessctl
      libvibrant
      xorg.xinit
      xorg.xorgserver
    ];
  };
}
