# Browsing Profile Packages
#
# Minimal package set for web browsing and general leisure.
# Browser (firefox) is provided by the Hydrix graphical module.
# Core VM packages are in shared/vm-packages.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Document viewers
    zathura

    # TUI file manager
    ranger

    # Terminal sharing
    tmate

    # Archive tools
    unzip
    unrar
    p7zip
  ];
}
