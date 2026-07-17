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
  username = config.hydrix.username;
  isHost = config.hydrix.vmType == null || config.hydrix.vmType == "host";
  isMicrovm = !isHost && !cfg.standalone;
  hasI3 = config.hydrix.i3.enable;
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

      # All tiers: audio
      pulseaudioFull
    ] ++ lib.optionals (hasI3 && !isMicrovm) [
      # i3/X11: bar, launcher, compositor, screenshot, tools
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
      xrdb
    ] ++ lib.optionals isHost [
      # Host: DDC/CI monitor control (WM-agnostic)
      ddcutil
    ] ++ lib.optionals (hasI3 && isHost) [
      # i3/X11 host: lockscreen, X server
      i3lock-color
      i3lock-fancy
      xorg.xinit
      xorg.xorgserver
    ];

    # DDC/CI: allow user-space tools (ddcutil) to talk to monitors over i2c
    hardware.i2c = lib.mkIf isHost { enable = true; };
    users.users.${username}.extraGroups = lib.mkIf isHost (lib.mkAfter [ "i2c" ]);
  };
}
