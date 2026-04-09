# microvm-vault — Bitwarden credential vault VM
#
# Headless infrastructure VM on br-vault (192.168.213.x, CID 213).
# Provides a vsock service (port 14507) for credential access from the host.
# All Bitwarden network traffic is isolated to this VM via the router.
#
# Enable on a machine:
#   hydrix.microvmVault.enable = true;
#   hydrix.microvmHost.vms."microvm-vault".enable = true;
#
# Vault-specific config (bw handler, vault user, services) is supplied
# via mkMicrovmVault modules = [...] in the user's flake.nix.
{ config, lib, ... }:
let
  cfg = config.hydrix.microvmVault;
in {
  config = lib.mkIf cfg.enable {
    networking.hostName = lib.mkForce "microvm-vault";
    system.stateVersion = "25.05";
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    microvm = {
      hypervisor = "qemu";
      vcpu = 1;
      mem  = 1024;

      graphics.enable = false;
      qemu.extraArgs = [
        "-vga" "none"
        "-display" "none"
        "-chardev" "socket,id=console,path=/var/lib/microvms/microvm-vault/console.sock,server=on,wait=off"
        "-serial" "chardev:console"
      ];

      interfaces = [{
        type = "tap";
        id   = "mv-vault";
        mac  = "02:00:00:02:13:01";  # CID 213 → last octet 13
      }];

      vsock.cid = 213;

      shares = [{
        tag        = "nix-store";
        source     = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto      = "virtiofs";
      }];

      volumes = [{
        image      = "/var/lib/microvms/microvm-vault/nix-overlay.qcow2";
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
    nix.enable = false;
  };
}
