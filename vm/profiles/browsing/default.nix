# Browsing Profile - Minimal base configuration for browsing VMs
#
# This is the HYDRIX BASE profile - minimal infrastructure only.
# MicroVMs use this directly (headless, waypipe forwarding).
# Libvirt VMs can layer user profiles on top for graphical settings.
#
# User profiles (in ~/hydrix-config/profiles/browsing/) can add:
# - hydrix.colorscheme = "nord";
# - hydrix.graphical.enable = true; (for standalone mode)
# - Additional packages
#
{ config, lib, pkgs, ... }:

let
  meta = config.hydrix.microvm.defaultProfiles.browsing;
in
{
  imports = [
    ./packages.nix
  ];

  # VM identity
  hydrix.vmType = "browsing";

  # Default networking/identity from hydrix.microvm.defaultProfiles -- lets this VM
  # build and be reachable through the router with zero hydrix-config customization.
  # hydrix-config's own profiles/browsing/default.nix (plain assignment, from its
  # meta.nix) fully overrides these.
  hydrix.microvm.vsockCid = lib.mkDefault meta.vsockCid;
  hydrix.microvm.bridge = lib.mkDefault meta.bridge;
  hydrix.microvm.tapId = lib.mkDefault meta.tapId;
  hydrix.networking.vmSubnet = lib.mkDefault meta.subnet;

  # Sound (needed for waypipe audio forwarding)
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };
}
