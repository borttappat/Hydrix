# Browsing Profile - Minimal base configuration for browsing VMs
#
# This is the HYDRIX BASE profile - minimal infrastructure only.
# MicroVMs use this directly (headless, xpra forwarding).
# Libvirt VMs can layer user profiles on top for graphical settings.
#
# User profiles (in ~/hydrix-config/profiles/browsing/) can add:
# - hydrix.colorscheme = "nord";
# - hydrix.graphical.enable = true; (for standalone mode)
# - Additional packages
#
{ config, lib, pkgs, ... }:

{
  imports = [ ./packages.nix ];

  # VM identity
  hydrix.vmType = "browsing";

  # Static IP on br-browse (files VM uses this to reach browsing VMs)
  hydrix.microvm.staticIp = "192.168.103.10";

  # Sound (needed for xpra audio forwarding)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
