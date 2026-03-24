# i3 Window Manager Module - Full Graphical Environment
#
# Provides i3-gaps window manager and complete desktop infrastructure.
# Only activates when hydrix.graphical.enable = true.
#
# Used by:
# - Host systems (always)
# - Libvirt VMs with standalone mode (for virt-manager/fullscreen use)
#
# NOT used by MicroVMs - they use xpra-apps.nix (minimal: alacritty, firefox, pywal)
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;
in
{
  config = lib.mkIf cfg.enable {
    services.xserver.displayManager.startx.enable = true;
    services.xserver.windowManager.i3.enable = true;
    services.xserver.windowManager.i3.package = pkgs.i3;

    environment.systemPackages = with pkgs; [
      # Window manager
      i3
      i3lock-color
      i3status

      # Compositor
      picom

      # Status bar
      polybar

      # Launcher
      rofi

      # Notifications
      dunst
      libnotify

      # Screenshot
      flameshot

      # Wallpaper
      feh

      # Display management
      arandr
      xorg.xrandr
      xorg.xmodmap

      # Audio
      pavucontrol

      # Clipboard
      xclip

      # Appearance
      lxappearance
    ];
  };

/*
services.picom = {
enable = true;
fade = true;
fadeDelta = 5;
fadeSteps = [0.028 0.03];
shadow = true;
shadowOffsets = [(-7) (-7)];
shadowOpacity = 0.7;
shadowRadius = 12;
activeOpacity = 0.95;
inactiveOpacity = 0.85;
backend = "glx";
vSync = true;
};
*/

}
