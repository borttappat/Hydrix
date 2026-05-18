# Browsing VM - Libvirt profile
#
# Imports the unified browsing profile and adds libvirt-specific modules.
# The colorscheme and settings are defined in profiles/browsing/default.nix
# (single source of truth for both libvirt and microVM).
#
# Hostname customization:
#   - Default: "browsing-vm"
#   - Override: Set networking.hostName in your machine config
#
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # Hydrix options - MUST BE FIRST to define hydrix.* options before other modules use them
    ../modules/options.nix

    # VM base module - handles all common VM config (hardware, locale, etc.)
    ../modules/vm/vm-base.nix

    # Unified browsing profile (colorscheme, packages, graphical settings)
    # This is the single source of truth
    ./browsing
  ];

  # VM hostname (can be overridden in machine config)
  hydrix.vm.defaultHostname = "browsing-vm";
}
