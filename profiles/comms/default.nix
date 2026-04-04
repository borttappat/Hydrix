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

  # Static IP on br-comms (files VM uses this to reach comms VMs)
  hydrix.microvm.staticIp = "192.168.102.10";

  # Sound (required for calls)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
