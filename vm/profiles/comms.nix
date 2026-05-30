# Comms VM - Libvirt profile
#
# Imports the unified comms profile and adds libvirt-specific modules.
# The colorscheme and settings are defined in profiles/comms/default.nix
# (single source of truth for both libvirt and microVM).
#
# Hostname customization:
#   - Default: "comms-vm"
#   - Override: Set networking.hostName in your machine config
#
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # Hydrix options
    ../../shared/options.nix
    ../../host/options.nix
    ../../vm/options.nix
    ../../theming/options.nix

    # VM base module - handles all common VM config (hardware, locale, etc.)
    ../base/vm-base.nix

    # Unified comms profile (colorscheme, packages, graphical settings)
    # This is the single source of truth
    ./comms
  ];

  # VM hostname (can be overridden in machine config)
  hydrix.vm.defaultHostname = lib.mkDefault "comms-vm";

  # Tor service for privacy (libvirt-specific, comms microVM is ephemeral)
  services.tor = {
    enable = true;
    client.enable = true;
  };
}
