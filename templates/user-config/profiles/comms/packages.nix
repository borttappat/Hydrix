# Comms Profile Packages
#
# Minimal communication toolkit.
# Core VM packages are in shared/vm-packages.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Chat client (Signal only)
    signal-desktop

    # Web browser for web-based comms (fallback)
    firefox

    # TUI file manager (for attachments)
    ranger

    # Archive tools
    unzip
    p7zip
  ];
}
