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
    # Hydrix options - MUST BE FIRST to define hydrix.* options before other modules use them
    ../modules/options.nix

    # VM base module - handles all common VM config (hardware, locale, etc.)
    ../modules/vm/vm-base.nix

    # Unified dev profile (colorscheme, packages, graphical settings, docker)
    # This is the single source of truth
    ./dev
  ];

  # VM hostname (can be overridden in machine config)
  hydrix.vm.defaultHostname = "dev-vm";

  # PostgreSQL for database development (libvirt-specific, persistent VMs)
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
  };
}
