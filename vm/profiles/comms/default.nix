# Comms Profile - Minimal base configuration for communication VMs
#
# This is the HYDRIX BASE profile - minimal infrastructure only.
# MicroVMs use this directly (headless, xpra forwarding).
# Libvirt VMs can layer user profiles on top for graphical settings.
#
# Includes:
# - VM identity (vmType)
# - Sound (required for xpra audio + calls)
# - Packages (via packages.nix)
#
{ config, lib, pkgs, ... }:

{
  imports = [ ./packages.nix ];

  # VM identity
  hydrix.vmType = "comms";

  # Sound (required for calls)
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };
}
