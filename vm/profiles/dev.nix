# Dev VM - Libvirt profile
#
# Imports the unified dev profile and adds libvirt-specific modules.
# The colorscheme and settings are defined in profiles/dev/default.nix
# (single source of truth for both libvirt and microVM).
#
# Hostname customization:
#   - Default: "dev-vm"
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

    # Unified dev profile (colorscheme, packages, graphical settings, docker)
    # This is the single source of truth
    ./dev
  ];

  # VM hostname (can be overridden in machine config)
  hydrix.vm.defaultHostname = lib.mkDefault "dev-vm";

  # PostgreSQL for database development (libvirt-specific, persistent VMs)
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
  };
}
