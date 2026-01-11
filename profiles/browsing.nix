# Browsing VM - Full profile
# Web browsing and general leisure system
#
# Hostname customization:
#   - Default: "browsing-vm"
#   - Override: Create local/vm-instance.nix with: { hostname = "browsing-myname"; }
#   - The build-vm.sh script generates this automatically
#
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # Hydrix options - MUST BE FIRST to define hydrix.* options before other modules use them
    ../modules/base/hydrix-options.nix

    # VM base module - handles all common VM config (hardware, locale, etc.)
    ../modules/vm/vm-base.nix
  ];

  # VM identity
  hydrix.vmType = "browsing";
  hydrix.colorscheme = "nvid";
  hydrix.vm.defaultHostname = "browsing-vm";

  # Browsing and media packages
  environment.systemPackages = with pkgs; [
    # Document viewers
    zathura

    # Archive tools
    unzip
    unrar
    p7zip

    # File managers
    pcmanfm
  ];

  # Enable sound for media
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
