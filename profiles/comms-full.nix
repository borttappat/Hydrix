# Comms VM - Full profile
# Communication and messaging focused system
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # QEMU guest profile from nixpkgs
    (modulesPath + "/profiles/qemu-guest.nix")

    # Base system
    ../modules/base/nixos-base.nix
    ../modules/base/users-vm.nix  # VM-isolated user (not host secrets)
    ../modules/base/networking.nix
    ../modules/vm/qemu-guest.nix
    ../modules/vm/hydrix-clone.nix  # Clone Hydrix repo on first boot

    # Core desktop environment (i3, fish, etc.)
    ../modules/core.nix

    # Theming system
    ../modules/theming/static-colors.nix
    ../modules/desktop/xinitrc.nix

    # Firefox browser
    ../modules/desktop/firefox.nix
  ];

  # ===== Inline hardware configuration for QEMU VMs =====
  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi" "virtio_console"
    "ahci" "xhci_pci" "sd_mod" "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [ ];

  boot.loader.grub = {
    enable = true;
    device = lib.mkDefault "/dev/vda";
    efiSupport = false;
    useOSProber = false;
  };

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  swapDevices = [ ];
  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Hostname
  networking.hostName = lib.mkForce "comms-vm";

  # VM type and colorscheme
  hydrix.vmType = "comms";
  hydrix.colorscheme = "punk";

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

    # Rebuild script
    (pkgs.writeShellScriptBin "rebuild" ''
      #!/usr/bin/env bash
      set -e
      cd ~/Hydrix
      echo "Pulling latest changes..."
      git pull
      echo "Rebuilding system..."
      sudo nixos-rebuild switch --flake '.#vm-comms' --impure
    '')
  ];

  # Tor service for privacy
  services.tor = {
    enable = true;
    client.enable = true;
  };
}
