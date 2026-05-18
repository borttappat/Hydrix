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

  # =========================================================================
  # MicroVM overrides - disable heavy/unnecessary services from Hydrix base
  # =========================================================================
  # MicroVMs use xpra for display, not a local X session.
  # Disable xsession to prevent .xsession/.xinitrc generation.
  # Disable dunst (notifications not useful via xpra).

  # Hardware graphics: mesa/llvmpipe for alacritty GL rendering
  hardware.graphics.enable = true;

  home-manager.users.${config.hydrix.username} = {
    xsession.enable = lib.mkForce false;
    services.dunst.enable = lib.mkForce false;
  };

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

    # GUI apps (xpra forwarded)
    firefox
    obsidian
    pywal
  ];
}
