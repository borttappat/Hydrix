# Core modules - Essential components for ALL Hydrix VMs and hosts
# This is imported by both base images and full profiles
{ config, pkgs, lib, ... }:

{
  imports = [
    # Window manager and desktop environment
    ./wm/i3.nix

    # Shell and terminal environment
    ./shell/fish.nix
    ./shell/packages.nix

    # Theming system
    ./theming/colors.nix
  ];

  # Essential packages that every VM needs
  environment.systemPackages = with pkgs; [
    # Editors
    vim

    # Network tools
    wget
    curl

    # System monitoring
    htop

    # File management
    ranger

    # Terminal utilities
    tmux
    fzf

    # Version control
    git
  ];

  # X11 essentials for desktop environment
  services.xserver = {
    enable = true;

    # Enable startx for "x" command
    displayManager.startx.enable = true;
  };

  # Auto-login (moved to new location in NixOS 25.05)
  services.displayManager.autoLogin = {
    enable = true;
    user = "traum";
  };

  # Auto-login to console (TTY1)
  services.getty.autologinUser = "traum";
}
