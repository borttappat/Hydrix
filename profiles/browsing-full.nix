# Browsing VM - Full profile
# Web browsing and general leisure system
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

    # Firefox with extensions
    ../modules/desktop/firefox.nix

    # Xpra server for seamless window forwarding to host
    ../modules/vm/xpra.nix
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
  networking.hostName = lib.mkForce "browsing-vm";

  # VM type and colorscheme
  hydrix.vmType = "browsing";
  hydrix.colorscheme = "nvid";

  # Browsing and media packages
  environment.systemPackages = with pkgs; [
    # Web browsers (Firefox is enabled via modules/desktop/firefox.nix)
    #firefox
    #google-chrome
    #chromium
    #brave

    # Media players
    #vlc
    #mpv

    # Image viewers/editors
    #feh
    #gimp
    #imagemagick

    # Document viewers
    zathura
    #evince

    # Download managers
    #yt-dlp

    # Screenshots
    #scrot
    #maim

    # Office suite
    #libreoffice

    # Archive tools
    unzip
    unrar
    p7zip

    # File managers
    pcmanfm

    # Rebuild script
    (pkgs.writeShellScriptBin "rebuild" ''
      #!/usr/bin/env bash
      set -e
      cd ~/Hydrix
      echo "Rebuilding system..."
      sudo nixos-rebuild switch --flake '.#vm-browsing' --impure
    '')
  ];

  # Enable sound for media
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
