# Core modules - Essential components for ALL Hydrix VMs and hosts
# This is imported by both base images and full profiles
{ config, pkgs, lib, ... }:

let
  # Username is computed by hydrix-options.nix (single source of truth)
  username = config.hydrix.username;
in
{
  imports = [
    # Window manager and desktop environment
    ./wm/i3.nix

    # Shell and terminal environment
    ./shell/fish.nix
    ./shell/packages.nix

    # Note: TTY colors are set in static-colors.nix (imported in flake.nix)
    # based on the configured colorscheme
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

    # X11 utilities (for splash screen click-through)
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
    enable = true;
    user = username;
  };

  # Auto-login to console (TTY1)
  # Use mkDefault so users.nix or users-vm.nix can override
  services.getty.autologinUser = lib.mkDefault username;
}
