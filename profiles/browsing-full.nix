# Browsing VM - Full profile (applied after shaping)
# Web browsing and general leisure system
{ config, pkgs, lib, ... }:

{
  imports = [
    # Base system
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix
    ../modules/vm/qemu-guest.nix

    # Core desktop environment (i3, fish, etc.)
    ../modules/core.nix

    # Theming system
    ../modules/theming/static-colors.nix  # Static green theme for browsing
    ../modules/desktop/xinitrc.nix        # X session bootstrap + config deployment
  ];

  # Hostname is set during VM deployment (e.g., "browsing-leisure")
  # Do not override it here

  # VM type for static color generation
  hydrix.vmType = "browsing";  # Generates green theme

  # Browsing and media packages
  environment.systemPackages = with pkgs; [
    # Web browsers
    firefox
    google-chrome
    chromium
    brave

    # Media players
    vlc
    mpv

    # Image viewers/editors
    feh
    gimp
    imagemagick

    # Document viewers
    zathura  # PDF viewer
    evince

    # Download managers
    youtube-dl
    yt-dlp

    # Screenshots
    scrot
    maim

    # Office suite
    libreoffice

    # Archive tools
    unzip
    unrar
    p7zip

    # File managers
    pcmanfm
  ];

  # Enable sound for media
  sound.enable = true;
  hardware.pulseaudio.enable = true;
}
