# Browsing Profile Packages
#
# This file is intentionally empty. Package decisions belong in the user's
# hydrix-config/profiles/browsing/packages.nix.
#
# Browser (firefox) is provided by modules/graphical/programs/firefox.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = [
    # Configured in user's hydrix-config
  ];
}
