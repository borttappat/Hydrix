# USB passthrough into a microVM, two ways (both from meta.nix):
#
# - usbPassthrough = true (hydrix.microvm.usbPassthrough.enable): the host can
#   hand a whole USB device to this VM with `usb attach <busid> <vm>`, which
#   asks for confirmation on the host first. The host's kernel never binds USB
#   storage, so this VM's kernel is the only one that parses the medium. USB
#   block devices arrive read-only; `usb-rw <dev>` makes one device and its
#   partitions writable.
# - usbDevices = ["vvvv:pppp" ...] (hydrix.microvm.usbPassthrough.devices):
#   these devices are attached whenever the VM runs, and again when replugged
#   (e.g. a USB WiFi adapter for the pentest VM). QEMU detaches the host driver
#   itself; the host grants the kvm group access to exactly these IDs.
#
# Either adds an xHCI controller (id "xhci").
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.microvm.usbPassthrough;
  utils = pkgs.util-linux;
  usbHost = id: let
    p = lib.splitString ":" id;
  in ["-device" "usb-host,bus=xhci.0,vendorid=0x${lib.elemAt p 0},productid=0x${lib.elemAt p 1}"];
in {
  options.hydrix.microvm.usbPassthrough = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Accept whole USB devices passed from the host (`usb attach <busid> <vm>`
        on the host). Set from the same meta.nix `usbPassthrough` value that the
        host registry reads, so the host only offers VMs that can take a device.
      '';
    };

    devices = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{4}");
      default = [];
      example = ["148f:5572"];
      description = ''
        USB devices ("vendor:product", lowercase hex from lsusb) attached
        whenever this VM runs. Set from the meta.nix `usbDevices` list, which
        the host registry also reads to grant access to these IDs only.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable || cfg.devices != []) {
      microvm.qemu.extraArgs = ["-device" "qemu-xhci,id=xhci"] ++ lib.concatMap usbHost cfg.devices;

      # Stock qemu_kvm already has the usb-host device, but microvm.nix
      # re-overrides it into a test-runner build without USB redirection or
      # libusb (its closure-size optimisation). Handing it a qemu_kvm whose
      # .override returns itself keeps the binary-cache build for this VM only.
      microvm.qemu.package = let
        qemu = config.microvm.vmHostPackages.qemu_kvm;
      in
        qemu // {override = _: qemu;};

      environment.systemPackages = [pkgs.usbutils];
    })

    (lib.mkIf cfg.enable {
      # Read-only until explicitly lifted with usb-rw: disks and partitions.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="${utils}/bin/blockdev --setro $devnode"
      '';

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "usb-rw" ''
          set -eu
          [ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
          dev=''${1:?usage: usb-rw /dev/sdX[N]}
          parent=$(${utils}/bin/lsblk -no PKNAME "$dev" 2>/dev/null | head -n1)
          disk=''${parent:+/dev/$parent}
          disk=''${disk:-$dev}
          for d in $(${utils}/bin/lsblk -lnpo NAME "$disk"); do
            ${utils}/bin/blockdev --setrw "$d"
          done
          echo "$disk and its partitions are now writable"
        '')
      ];
    })
  ];
}
