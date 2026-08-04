# Graphical Environment Packages
#
# WM, theming, and X11 packages required for the graphical environment.
# Only included when hydrix.graphical.enable = true.
#
# Three tiers:
#   microvm     - theming + audio only (waypipe-forwarded apps, no local WM)
#   standalone  - full WM environment (libvirt VMs with own desktop)
#   host        - adds hardware controls (lockscreen, brightness, saturation)
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  isHost = config.hydrix.vmType == null || config.hydrix.vmType == "host";
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
    ] ++ lib.optionals isHost [
      # Host: DDC/CI monitor control (WM-agnostic)
      ddcutil
    ];

    # DDC/CI: allow user-space tools (ddcutil) to talk to monitors over i2c
    hardware.i2c = lib.mkIf isHost { enable = true; };
    users.users.${username}.extraGroups = lib.mkIf isHost (lib.mkAfter [ "i2c" ]);
  };
}
