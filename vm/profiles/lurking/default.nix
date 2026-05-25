# Lurking Profile - Base configuration for darknet browsing VMs
#
# This is the HYDRIX BASE profile - infrastructure only.
# MicroVMs use this directly (headless, xpra forwarding).
#
# EPHEMERAL by design - all data lost on restart for maximum privacy.
#
# Services (Tor) and packages are configured in the user's
# hydrix-config/profiles/lurking/.
#
{ config, lib, pkgs, ... }:

{
  imports = [ ./packages.nix ];

  # VM identity
  hydrix.vmType = "lurking";

  # Sound (for xpra audio forwarding)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
