# Lurking Profile - Base configuration for darknet browsing VMs
#
# This is the HYDRIX BASE profile - infrastructure only.
# MicroVMs use this directly (headless, waypipe forwarding).
#
# EPHEMERAL by design - all data lost on restart for maximum privacy.
#
# Services (Tor) and packages are configured in the user's
# hydrix-config/profiles/lurking/.
#
{ config, lib, pkgs, ... }:

let
  meta = config.hydrix.microvm.defaultProfiles.lurking;
in
{
  imports = [ ./packages.nix ];

  # VM identity
  hydrix.vmType = "lurking";

  # Default networking/identity from hydrix.microvm.defaultProfiles -- lets this VM
  # build and be reachable through the router with zero hydrix-config customization.
  # hydrix-config's own profiles/lurking/default.nix (plain assignment, from its
  # meta.nix) fully overrides these.
  hydrix.microvm.vsockCid = lib.mkDefault meta.vsockCid;
  hydrix.microvm.bridge = lib.mkDefault meta.bridge;
  hydrix.microvm.tapId = lib.mkDefault meta.tapId;
  hydrix.networking.vmSubnet = lib.mkDefault meta.subnet;

  # Sound (for waypipe audio forwarding)
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };
}
