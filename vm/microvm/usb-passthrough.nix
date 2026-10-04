# USB passthrough target (hydrix.microvm.usbPassthrough.enable): the host can
# hand a whole USB device to this VM with `usb attach <busid> <vm>`, which asks
# for confirmation on the host first. The host's kernel never binds USB
# storage, so this VM's kernel is the only one that parses the medium.
#
# Adds an xHCI controller (id "xhci") that the host hotplugs `usb-host`
# devices onto over the VM's QMP socket. USB block devices arrive read-only;
# `usb-rw <dev>` makes one device and its partitions writable.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.microvm.usbPassthrough;
  utils = pkgs.util-linux;
in {
  options.hydrix.microvm.usbPassthrough.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Accept whole USB devices passed from the host (`usb attach <busid> <vm>`
      on the host). Set from the same meta.nix `usbPassthrough` value that the
      host registry reads, so the host only offers VMs that can take a device.
    '';
  };

  config = lib.mkIf cfg.enable {
    microvm.qemu.extraArgs = ["-device" "qemu-xhci,id=xhci"];

    # Read-only until explicitly lifted with usb-rw: disks and partitions.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="${utils}/bin/blockdev --setro $devnode"
    '';

    environment.systemPackages = [
      pkgs.usbutils
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
  };
}
