# Dev Profile - Base configuration for development VMs
#
# This is the HYDRIX BASE profile - infrastructure only.
# MicroVMs use this directly (headless, xpra forwarding).
#
# Services (Docker, Ollama) and packages are configured in the user's
# hydrix-config/profiles/dev/.
#
{ config, lib, pkgs, ... }:

{
  imports = [
    ./packages.nix
    ../../modules/vm/ollama-dev.nix
  ];

  # VM identity
  hydrix.vmType = "dev";

  # Sound (for xpra audio forwarding)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
