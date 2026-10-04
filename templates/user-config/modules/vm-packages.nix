# VM Packages - Core packages for ALL VMs
#
# Lighter than host-packages.nix - no WiFi tools, nix build tools, VPN, etc.
# Profile-specific packages go in profiles/<type>/packages.nix
#
{ config, lib, pkgs, ... }:

{
  imports = [
    ./shell-packages.nix
  ];

  # Hardware graphics: mesa/llvmpipe for alacritty GL rendering
  hardware.graphics.enable = true;

  environment.variables = {
    EDITOR = config.hydrix.editor;
    VISUAL = config.hydrix.editor;
  };

  environment.systemPackages = with pkgs; [
    # Editors
    vim
    nano

    # System monitoring
    htop

    # File management
    ranger
    file
    tree

    # Core utilities
    coreutils
    findutils
    gnugrep
    gnused
    gawk

    # Media
    feh
    zathura
    mpv

    # Network tools
    wget
    curl

    # Version control
    git
    gh

    # Archive tools
    unzip
    p7zip

    # System utilities
    killall
    pciutils
    lshw

    # Nix tools
    nh

    # GUI apps (waypipe forwarded)
    pywal
  ];
}
