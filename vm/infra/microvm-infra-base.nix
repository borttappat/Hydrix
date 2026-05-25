# microvm-infra-base — shared base for user-declared infrastructure VMs
#
# Provides headless defaults (console socket, virtiofs store, DHCP networking,
# no nix-daemon). User infra VMs import this and add their own services.
#
# Used by hydrix.lib.mkInfraVm — not intended for direct import.
{ config, lib, ... }:
let vmName = config.networking.hostName; in {
  system.stateVersion = "25.05";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  microvm = {
    hypervisor  = "qemu";
    qemu.machine = "pc";
    vcpu = lib.mkDefault 1;
    mem  = lib.mkDefault 1024;

    graphics.enable = false;
    qemu.extraArgs = [
      "-vga"     "none"
      "-display" "none"
      "-chardev" "socket,id=console,path=/var/lib/microvms/${vmName}/console.sock,server=on,wait=off"
      "-serial"  "chardev:console"
    ];

    shares = [{
      tag        = "nix-store";
      source     = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto      = "virtiofs";
    }];

    volumes = [{
      image      = "/var/lib/microvms/${vmName}/nix-overlay.qcow2";
      mountPoint = "/nix/.rw-store";
      size       = 2048;
      autoCreate = true;
    }];
  };

  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi" "squashfs"
  ];
  boot.kernelParams = [ "8250.nr_uarts=1" "console=tty1" "console=ttyS0,115200n8" ];

  networking = {
    useDHCP               = true;
    enableIPv6            = false;
    networkmanager.enable = false;
    firewall.enable       = false;
  };

  services.qemuGuest.enable = true;
  security.sudo.wheelNeedsPassword = false;
  nix.enable = false;
}
