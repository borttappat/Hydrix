# Core Desktop Module - Graphical components for Hydrix hosts and standalone VMs
#
# This module provides the full desktop environment:
# - i3 window manager
# - X11 server with startx
# - Auto-login to graphical session
#
# Only activates when hydrix.graphical.enable = true.
# For headless VMs (xpra forwarding), use vm-minimal.nix instead.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
in
{
  imports = [
    # Window manager and desktop environment
    ./wm/i3.nix
    ./wm/focus-mode.nix

    # Shell configuration (fish, starship)
    ./shell/fish.nix
  ];

  config = lib.mkIf cfg.enable {
    # X11 utilities for desktop environment
    environment.systemPackages = with pkgs; [
      # X11 utilities (for splash screen click-through)
      libvibrant
      python3Packages.xlib
    ];

    # X11 essentials for desktop environment
    services.xserver = {
      enable = true;

      # Enable startx for "x" command
      displayManager.startx.enable = true;
    };

    # Auto-login (moved to new location in NixOS 25.05)
    services.displayManager.autoLogin = {
      enable = false;
      user = username;
    };
  };
}
