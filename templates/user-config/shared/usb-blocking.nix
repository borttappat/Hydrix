# USB Storage Blocking Configuration
#
# Prevents USB storage devices from auto-mounting on the host.
# IMPORTANT: Only affects USB MASS STORAGE (bInterfaceClass 08).
# USB mice, keyboards, monitors, and other HID devices work normally.
#
# Workflow:
#   1. Plug in USB drive — host blocks auto-mount via udev
#   2. usb list                        — see storage devices and their busids
#   3. usb attach <busid>              — unbind from host driver, pass to usb-sandbox VM
#   4. Inside usb-sandbox console: usb-mount scan
#   5. Inside usb-sandbox console: usb-mount mount /dev/sdX1
#   6. Transfer to files VM via: microvm files store usb-sandbox/<path>
#   7. usb detach                      — release device back to host

{ config, lib, pkgs, ... }:

{
  # =========================================================================
  # UDEV RULES — block USB storage from auto-mounting on host
  # bInterfaceClass 08 = Mass Storage; does NOT affect HID (03), audio (01), etc.
  # =========================================================================
  services.udev.extraRules = ''
    # Block USB mass storage devices from UDisks auto-mount
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="08", \
      ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"

    # Block auto-mount and allow kvm group access (microvm QEMU runs as group kvm)
    # so the usb-sandbox VM can read the raw block device via drive_add hotplug
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_USB_INTERFACES}=="*:08*", \
      ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1", \
      GROUP="kvm", MODE="0660"
  '';

  # =========================================================================
  # MICROVM DISK ACCESS
  # The microvm user needs read access to USB block devices (/dev/sdX) so
  # the usb-sandbox QEMU process can open them via drive_add hotplug.
  # Adding to the 'disk' group is the standard way to grant raw block access.
  # =========================================================================
  users.users.microvm.extraGroups = [ "disk" ];

  # =========================================================================
  # HOST-SIDE USB HELPER
  # Communicates with QEMU monitor socket — no network bridge to VM required.
  # =========================================================================
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "usb" ''
      set -euo pipefail
      MONITOR_SOCK="/var/lib/microvms/microvm-usb-sandbox/monitor.sock"

      send_monitor() {
        printf '%s\n' "$1" | sudo socat -T5 - UNIX-CONNECT:"$MONITOR_SOCK" 2>/dev/null
      }

      cmd="''${1:-}"
      shift || true

      case "$cmd" in

        list)
          echo "=== USB Storage Devices ==="
          found=0
          for d in /sys/bus/usb/devices/*/; do
            [ -f "$d/idVendor" ] || continue
            vid=$(cat "$d/idVendor" 2>/dev/null) || continue
            pid=$(cat "$d/idProduct" 2>/dev/null) || continue
            busid=$(basename "$d")
            for iface in "$d"*/bInterfaceClass; do
              [ -f "$iface" ] || continue
              cls=$(cat "$iface" 2>/dev/null)
              if [ "$cls" = "08" ]; then
                mfr=$(cat "$d/manufacturer" 2>/dev/null || echo "Unknown")
                prod=$(cat "$d/product" 2>/dev/null || echo "Unknown")
                echo "  busid=$busid  id=$vid:$pid  $mfr $prod"
                found=1
                break
              fi
            done
          done
          [ "$found" = "0" ] && echo "  (none detected)"
          echo ""
          echo "Usage: usb attach <busid>   — pass device to usb-sandbox VM"
          echo "       usb detach           — release device back to host"
          ;;

        attach)
          if [ -z "''${1:-}" ]; then
            echo "Usage: usb attach <busid>"
            echo "Run 'usb list' to find busids"
            exit 1
          fi
          BUSID="$1"

          # Find the block device exposed by this USB device via sysfs
          BLOCK_DIR=$(find /sys/bus/usb/devices/"$BUSID"/ -name "block" -type d 2>/dev/null | head -1)
          if [ -z "$BLOCK_DIR" ]; then
            echo "ERROR: no block device found for busid $BUSID (is usb-storage loaded?)"
            exit 1
          fi
          DEV=$(ls "$BLOCK_DIR" | head -1)
          if [ -z "$DEV" ]; then
            echo "ERROR: block device directory empty under $BLOCK_DIR"
            exit 1
          fi

          echo "Passing /dev/$DEV ($BUSID) to usb-sandbox VM as virtio disk..."
          OUT=$(send_monitor "drive_add 0 if=none,id=usb-drive,file=/dev/''${DEV},format=raw,read-only=on" || true)
          if echo "$OUT" | grep -qi "error\|could not\|failed"; then
            echo "ERROR adding drive: $OUT"; exit 1
          fi
          OUT=$(send_monitor "device_add virtio-blk-pci,drive=usb-drive,id=usb-disk" || true)
          if echo "$OUT" | grep -qi "error\|could not\|failed"; then
            send_monitor "drive_del usb-drive" > /dev/null 2>/dev/null || true
            echo "ERROR adding device: $OUT"; exit 1
          fi
          echo "OK — disk passed to VM as /dev/vdb (connect: microvm console microvm-usb-sandbox)"
          ;;

        detach)
          echo "Releasing disk from usb-sandbox VM..."
          send_monitor "device_del usb-disk"  > /dev/null 2>/dev/null || true
          send_monitor "drive_del usb-drive"  > /dev/null 2>/dev/null || true
          echo "OK — disk released back to host"
          ;;

        *)
          echo "Usage: usb {list|attach <busid>|detach}"
          echo ""
          echo "  list           — show USB storage devices and their busids"
          echo "  attach <busid> — pass device to usb-sandbox VM"
          echo "  detach         — release device back to host"
          exit 1
          ;;
      esac
    '')
  ];
}
