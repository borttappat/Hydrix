# Base Packages - Available in ALL modes
#
# The Hydrix framework handles all infrastructure (networking, VFIO, services).
# Package definitions are in shared/host-packages.nix.
#
# Imported by your machine config at the top level.
#
{ config, lib, pkgs, ... }:

{
  imports = [
    ../shared/host-packages.nix
  ];
}
