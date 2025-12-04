# Base VM - Minimal bootable image with core components
# VM will shape itself on first boot based on hostname
{ config, pkgs, lib, modulesPath, ... }:

{
  # Allow unfree firmware for hardware support
  nixpkgs.config.allowUnfree = true;

  imports = [
    # QEMU guest profile from nixpkgs
    (modulesPath + "/profiles/qemu-guest.nix")

    # Base system configuration
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix

    # VM-specific modules
    ../modules/vm/qemu-guest.nix
    ../modules/vm/hardware-setup.nix   # Auto-generates hardware-configuration.nix on first boot
    ../modules/vm/hydrix-clone.nix     # Clones Hydrix on first boot
    ../modules/vm/shaping.nix          # First-boot shaping service

    # Core desktop environment (i3, fish, alacritty, etc.)
    ../modules/core.nix
  ];

  # Boot loader configuration for VMs
  boot.loader.grub = {
    enable = true;
    device = lib.mkForce "/dev/vda";
    efiSupport = false;
  };

  # Filesystem config is handled by nixos-generators qcow format
  # It uses /dev/disk/by-label/nixos by default

  # VM kernel modules
  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi" "virtio_console"
    "ahci" "xhci_pci" "sd_mod" "sr_mod"
  ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];

  # Hostname will be set at build time based on VM type
  # Example: "pentest-vm", "comms-vm", "browsing-vm", "dev-vm"

  # Minimal additional packages for bootstrapping
  environment.systemPackages = with pkgs; [
    # Build tools needed for shaping
    nixos-rebuild

    # Network diagnostics
    inetutils
    curl

    # Tools for hardware detection
    util-linux

    # VM rebuild script (detects type from hostname)
    (pkgs.writeScriptBin "nixbuild-vm" (builtins.readFile ../scripts/nixbuild-vm.sh))
  ];
}
