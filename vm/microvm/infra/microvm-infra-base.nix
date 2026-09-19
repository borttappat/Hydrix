# microvm-infra-base - shared base for user-declared infrastructure VMs
#
# Provides headless defaults (console socket, virtiofs store, DHCP networking,
# no nix-daemon). User infra VMs import this and add their own services.
#
# Used by hydrix.lib.mkInfraVm - not intended for direct import.
{
  config,
  lib,
  ...
}: let
  vmName = config.networking.hostName;
in {
  imports = [
    # Live NixOS switch via vsock:14504 (microvm update / microvm switch)
    ./vm-switch.nix
  ];

  config = {
    system.stateVersion = "25.05";
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    microvm = {
      hypervisor = "qemu";
      # Verified working (gitsync) after fixing the qemu.serialConsole
      # collision below.
      qemu.machine = "microvm";
      vcpu = lib.mkDefault 1;
      mem = lib.mkDefault 1024;

      # Attach the virtio-balloon device (profile VMs already get this via
      # microvm-profile-base.nix; infra VMs never did, so QMP balloon requests
      # against them silently no-op with no device to target).
      balloon = lib.mkDefault true;
      deflateOnOOM = lib.mkDefault true;

      graphics.enable = false;

      # microvm.nix's own qemu.serialConsole (default true) unconditionally
      # adds its own "-serial chardev:stdio" on top of the console.sock one
      # below - two legacy serial ports total. "pc"/"q35" can host both, so
      # this went unnoticed, but "microvm" only supports one legacy serial
      # UART by design, and whichever port ttyS0 actually lands on stopped
      # being guaranteed to be the console.sock-backed one. Only ever needed
      # the one console.sock port to begin with.
      qemu.serialConsole = false;
      qemu.extraArgs = [
        "-vga"
        "none"
        "-display"
        "none"
        "-chardev"
        "socket,id=console,path=/var/lib/microvms/${vmName}/console.sock,server=on,wait=off"
        "-serial"
        "chardev:console"
      ];

      shares = [
        {
          tag = "nix-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "virtiofs";
        }
        # Host secrets directory - always mounted; host pre-creates for all enabled VMs.
        # Empty when no secrets are provisioned (vms.<name>.secrets = [] in machine config).
        {
          tag = "vm-secrets";
          source = "/run/hydrix-secrets/${vmName}";
          mountPoint = "/mnt/vm-secrets";
          proto = "virtiofs";
          readOnly = true;
        }
        # VM config directory - used by vm-switch to receive .switch-reg nix DB dump.
        # Created by `microvm build` at /var/lib/microvms/<name>/config on the host.
        {
          tag = "vm-config";
          source = "/var/lib/microvms/${vmName}/config";
          mountPoint = "/mnt/vm-config";
          proto = "9p";
        }
      ];

      # No writableStoreOverlay is set - /nix/store stays read-only in these VMs.
      # Ephemeral by default: any state a VM needs to survive restarts must come
      # from an explicit volume or virtiofs share declared in its own default.nix.
      volumes = [];
    };

    boot.initrd.availableKernelModules = [
      "virtio_balloon"
      "virtio_blk"
      "virtio_pci"
      "virtio_ring"
      "virtio_net"
      "virtio_scsi"
      "squashfs"
    ];
    boot.kernelParams = ["8250.nr_uarts=1" "console=tty1" "console=ttyS0,115200n8"];

    networking = {
      useDHCP = true;
      enableIPv6 = false;
      networkmanager.enable = false;
      firewall.enable = false;
    };

    services.qemuGuest.enable = true;
    security.sudo.wheelNeedsPassword = false;
    nix.enable = false;
  };
}
