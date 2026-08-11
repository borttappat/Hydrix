# Comms Profile - Minimal base configuration for communication VMs
#
# This is the HYDRIX BASE profile - minimal infrastructure only.
# MicroVMs use this directly (headless, waypipe forwarding).
# Libvirt VMs can layer user profiles on top for graphical settings.
#
# Includes:
# - VM identity (vmType)
# - Sound (required for waypipe audio + calls)
# - Packages (via packages.nix)
#
{ config, lib, pkgs, ... }:

let
  meta = config.hydrix.microvm.defaultProfiles.comms;
in
{
  imports = [ ./packages.nix ./services.nix ];

  # VM identity
  hydrix.vmType = "comms";

  # Default networking/identity from hydrix.microvm.defaultProfiles -- lets this VM
  # build and be reachable through the router with zero hydrix-config customization.
  # hydrix-config's own profiles/comms/default.nix (plain assignment, from its
  # meta.nix) fully overrides these.
  hydrix.microvm.vsockCid = lib.mkDefault meta.vsockCid;
  hydrix.microvm.bridge = lib.mkDefault meta.bridge;
  hydrix.microvm.tapId = lib.mkDefault meta.tapId;
  hydrix.networking.vmSubnet = lib.mkDefault meta.subnet;

  # Sound (required for calls)
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };
}
