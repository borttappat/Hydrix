# Comms VM - Full profile (applied after shaping)
# Communication and messaging focused system
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # QEMU guest profile
    (modulesPath + "/profiles/qemu-guest.nix")

    # Hardware configuration (generated on first boot)
    /etc/nixos/hardware-configuration.nix

    # Base system
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix
    ../modules/vm/qemu-guest.nix

    # Core desktop environment (i3, fish, etc.)
    ../modules/core.nix

    # Theming system
    ../modules/theming/static-colors.nix  # Static blue theme for comms
    ../modules/desktop/xinitrc.nix        # X session bootstrap + config deployment
  ];

  # Boot loader configuration for VMs
  boot.loader.grub = {
    enable = true;
    device = lib.mkForce "/dev/vda";
    efiSupport = false;
  };

  # Hostname is set during VM deployment (e.g., "comms-signal")
  # Do not override it here

  # VM type for static color generation
  hydrix.vmType = "comms";  # Generates blue theme

  # Communication-specific packages
  environment.systemPackages = with pkgs; [
    # Messaging apps
    signal-desktop
    telegram-desktop
    discord
    element-desktop  # Matrix client

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
