# Comms VM - Full profile
# Communication and messaging focused system
#
# Hostname customization:
#   - Default: "comms-vm"
#   - Override: Create local/vm-instance.nix with: { hostname = "comms-myname"; }
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
  hydrix.vmType = "comms";
  hydrix.colorscheme = "punk";
  hydrix.vm.defaultHostname = "comms-vm";

  # Communication-specific packages
  environment.systemPackages = with pkgs; [
    # Messaging apps
    signal-desktop
    telegram-desktop
    discord
    element-desktop

    # Email clients
    thunderbird

    # VoIP
    zoom-us

    # IRC/Chat
    hexchat
    weechat

    # File sharing
    qbittorrent

    # Privacy tools
    tor-browser-bundle-bin
    torsocks

    # Network utilities
    openvpn
    wireguard-tools
  ];

  # Tor service for privacy
  services.tor = {
    enable = true;
    client.enable = true;
  };
}
