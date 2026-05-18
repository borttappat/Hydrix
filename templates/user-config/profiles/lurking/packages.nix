# Lurking Profile Packages
#
# Tor-focused browsing toolkit for darknet access.
# Minimal footprint, maximum privacy.
# Core VM packages are in shared/vm-packages.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Tor Browser - pre-configured for anonymity
    tor-browser

    # Torify commands - route any CLI through Tor
    torsocks

    # Anonymous file sharing
    onionshare

    # Fallback browser (regular firefox, clearnet)
    firefox

    # TUI file manager
    ranger

    # Archive tools
    unzip
    p7zip
  ];
}
