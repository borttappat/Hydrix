# Host Packages - Core packages for the HOST system (all boot modes)
#
# Imported via specialisations/_base.nix so these are available in
# lockdown, administrative, and fallback modes.
#
# VM packages go in shared/vm-packages.nix instead.
# Profile-specific packages go in profiles/<type>/packages.nix
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  imports = [
    ./shell-packages.nix
  ];

  environment.systemPackages = with pkgs; [
    # Editors
    vim
    nano

    # Compilers/Languages (basic)
    gcc
    python3

    # Media
    mpv
    zathura
    feh

    # VPN
    mullvad-vpn

    # File management
    ranger
    joshuto
    file
    tree

    # System monitoring
    htop

    # Network tools
    wget
    curl
    iw
    wirelesstools

    # Version control
    git
    gh

    # Nix tools
    unstable.nix-output-monitor
    nh
    nix-prefetch
    nix-prefetch-github

    # Archive tools
    unzip
    rar
    p7zip

    # System utilities
    killall
    pciutils
    usbutils
    lshw
    toybox
    findutils
    busybox
    inetutils
    udisks
    tealdeer
    coreutils
    gnugrep
    gnused
    gawk

    # Fun
    cbonsai
    cmatrix
    pipes-rs
    artem
    asciinema
    cava

    # Notes
    obsidian

    # Qt/GTK theme support
    adwaita-icon-theme
    gtk-engine-murrine
    gtk_engines
    gsettings-desktop-schemas
  ];

  # Environment variables
  environment.variables = {
    BAT_THEME = "ansi";
    EDITOR = cfg.editor;
    VISUAL = cfg.editor;
    XCURSOR_SIZE = "32";
  };

  services.dbus.enable = true;

  # Qt theming
  qt = {
    enable = true;
    platformTheme = lib.mkDefault "gtk2";
  };

  # GTK dark theme
  environment.etc."gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
  '';
}
