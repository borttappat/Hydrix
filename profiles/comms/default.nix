# Comms Profile - Minimal base configuration for communication VMs
#
# This is the HYDRIX BASE profile - minimal infrastructure only.
# MicroVMs use this directly (headless, xpra forwarding).
# Libvirt VMs can layer user profiles on top for graphical settings.
#
# EPHEMERAL by design - all data lost on restart for privacy.
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
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
