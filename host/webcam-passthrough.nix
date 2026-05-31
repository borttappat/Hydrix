# Webcam USB Passthrough
#
# Passes a USB webcam to a profile VM via QEMU USB host passthrough.
# A udev rule grants the kvm group access to the device node so QEMU
# can claim it. The QEMU args are injected into the target profile VM
# via microvmHost.profileOverrides - only on this machine.
#
{ config, lib, ... }:

let
  cfg = config.hydrix.webcamPassthrough;
in {
  options.hydrix.webcamPassthrough = {
    enable = lib.mkEnableOption "USB webcam passthrough to a profile VM";

    vendorId = lib.mkOption {
      type    = lib.types.str;
      example = "046d";
      description = "USB vendor ID of the webcam (4 hex digits, from lsusb).";
    };

    productId = lib.mkOption {
      type    = lib.types.str;
      example = "0825";
      description = "USB product ID of the webcam (4 hex digits, from lsusb).";
    };

    targetProfile = lib.mkOption {
      type    = lib.types.str;
      default = "comms";
      description = "Profile name to pass the webcam into (e.g. \"comms\", \"dev\").";
    };
  };

  config = lib.mkIf cfg.enable {
    # Grant kvm group access to the webcam device node so QEMU can open it.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="${cfg.vendorId}", ATTR{idProduct}=="${cfg.productId}", GROUP="kvm", MODE="0660"
    '';

    # Inject USB passthrough args into the target VM on this machine only.
    # qemu-xhci provides a USB 3.0 controller; usb-host binds the physical device.
    hydrix.microvmHost.profileOverrides.${cfg.targetProfile} = { ... }: {
      microvm.qemu.extraArgs = [
        "-device" "qemu-xhci,id=webcam-ctrl"
        "-device" "usb-host,vendorid=0x${cfg.vendorId},productid=0x${cfg.productId}"
      ];
    };
  };
}
