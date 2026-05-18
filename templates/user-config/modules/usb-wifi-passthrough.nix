# USB WiFi Passthrough Module
#
# Pass USB WiFi adapters to microVMs for WiFi pentesting.
# Uses native microvm.nix USB device passthrough with automatic host driver unbind.
#
# ─────────────────────────────────────────────────────────────────────────────
# SETUP INSTRUCTIONS (Fresh Install)
# ─────────────────────────────────────────────────────────────────────────────
#
# 1. Find your USB WiFi adapter's vendor and product ID on the host:
#    $ lsusb
#    Bus 003 Device 005: ID 148f:5572 Ralink Technology, Corp. RT5572
#                       ↑ VID:PID (e.g., 148f:5572)
#
# 2. Edit machines/<your-machine>.nix and add:
#    {
#      imports = [ ../modules/usb-wifi-passthrough.nix ];
#      hydrix.hardware.usbWifiPassthrough = {
#        enable = true;
#        vendorId = "148f";    # ← Replace with your VID (e.g., "148f", "0bda", "0cf3")
#        productId = "5572";   # ← Replace with your PID (e.g., "5572", "2838")
#      };
#    }
#
# 3. Edit profiles/<vm-type>/default.nix and add:
#    {
#      # USB controller + device passthrough (replace VID/PID)
#      microvm.qemu.extraArgs = [
#        "-device" "qemu-xhci,id=usb-controller"
#        "-device" "usb-host,vendorid=0x148f,productid=0x5572"  # ← Replace with your VID:PID
#      ];
#    }
#
# 4. Rebuild and restart the VM:
#    $ rebuild administrative
#    $ microvm restart <vm-name>
#
# 5. Verify in the VM:
#    $ lsusb
#    Bus 001 Device 002: ID 148f:5572 Ralink Technology, Corp. RT5572
#
# ─────────────────────────────────────────────────────────────────────────────
# TROUBLESHOOTING
# ─────────────────────────────────────────────────────────────────────────────
#
# Device not showing in VM:
#   1. Check host driver is unbound: lsusb -t | grep <VID:PID>
#   2. If Driver= appears, unbind manually:
#      $ echo -n "3-4" | sudo tee /sys/bus/usb/drivers/<driver>/unbind
#   3. Restart the VM
#
# Device re-claims by host after reboot:
#   1. Add a UDEV rule to persist permissions
#   2. Unplug and re-plug the adapter after boot
#
# ─────────────────────────────────────────────────────────────────────────────
# COMMON USB WiFi ADAPTER IDs
# ─────────────────────────────────────────────────────────────────────────────
#
# | Adapter                   | Vendor ID | Product ID |
# |---------------------------|-----------|------------|
# | Ralink RT2870/RT3070      | 148f      | 3070/5572  |
# | Ralink RT5370             | 148f      | 5370       |
# | Realtek RTL8812AU         | 0bda      | edc8/8812  |
# | Realtek RTL8822AU         | 0bda      | b711       |
# | Atheros AR9271            | 0cf3      | 9271       |
# | MediaTek MT7921AU         | 0e8d      | 7961       |
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.hardware.usbWifiPassthrough;
in

{
  options.hydrix.hardware = {
    usbWifiPassthrough = {
      enable = lib.mkEnableOption "USB WiFi passthrough to microVMs";

      vendorId = lib.mkOption {
        type = lib.types.str;
        default = "148f";
        description = "USB Vendor ID of the WiFi adapter (e.g., '148f' for Ralink)";
      };

      productId = lib.mkOption {
        type = lib.types.str;
        default = "5572";
        description = "USB Product ID of the WiFi adapter (e.g., '5572' for RT5572)";
      };

      deviceName = lib.mkOption {
        type = lib.types.str;
        default = "USB WiFi Adapter";
        description = "Descriptive name for the USB device (for logging)";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # UDEV rules for USB WiFi passthrough - sets KVM group permissions
    services.udev.extraRules = ''
      # USB WiFi passthrough - allow KVM group access
      # ${cfg.deviceName} (vendor=${cfg.vendorId}, product=${cfg.productId})
      SUBSYSTEM=="usb", ATTR{idVendor}=="${cfg.vendorId}", ATTR{idProduct}=="${cfg.productId}", GROUP="kvm"
    '';

    # Systemd service to unbind host driver before VM starts
    systemd.services.prepare-usb-wifi = {
      description = "Prepare USB WiFi for passthrough to microVM";
      after = [ "systemd-udevd.service" ];
      before = [ "microvm@" ];  # Runs before any microVM starts
      wantedBy = [ "microvm@" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        vendorId = cfg.vendorId;
        productId = cfg.productId;
      in ''
        # Find and unbind USB WiFi adapter from host driver
        for dev in /sys/bus/usb/devices/*/; do
          [ -f "$dev/idVendor" ] || continue
          [ -f "$dev/idProduct" ] || continue

          vid=$(cat "$dev/idVendor" 2>/dev/null)
          pid=$(cat "$dev/idProduct" 2>/dev/null)

          if [ "$vid" = "${vendorId}" ] && [ "$pid" = "${productId}" ]; then
            busid=$(basename "$dev")

            # Unbind from host driver if bound
            if [ -L "$dev/driver" ]; then
              driver=$(basename "$(readlink "$dev/driver")")
              echo "Unbinding $busid from $driver"
              echo -n "$busid" > "/sys/bus/usb/drivers/$driver/unbind" 2>/dev/null || true
            fi

            # Set permissions on USB device node
            busnum=$(cat "$dev/busnum" 2>/dev/null | tr -d '\0' || echo "")
            devnum=$(cat "$dev/devnum" 2>/dev/null | tr -d '\0' || echo "")
            if [ -n "$busnum" ] && [ -n "$devnum" ]; then
              devnode="/dev/bus/usb/$(printf '%03d' $busnum)/$(printf '%03d' $devnum)"
              if [ -e "$devnode" ]; then
                chown root:kvm "$devnode" 2>/dev/null || true
                chmod 660 "$devnode" 2>/dev/null || true
              fi
            fi

            echo "USB WiFi prepared for passthrough"
            exit 0
          fi
        done
        echo "No matching USB WiFi device found (looking for ${vendorId}:${productId})"
        exit 0
      '';
    };
  };
}
