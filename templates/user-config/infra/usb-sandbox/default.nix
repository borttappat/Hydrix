# USB Sandbox Infra VM - NixOS Configuration
#
# Ephemeral VM for safely handling USB storage devices.
# USB devices are passed through via QEMU USB hotplug (no network bridge to host).
# The host sends device_add/device_del commands to the QEMU monitor socket.
#
# Files can be transferred out via the files VM:
#   microvm files store usb-sandbox/<path>
#   microvm files transfer usb-sandbox/<path> dev/<dest>
#
# Paths are relative to /home/sandbox/ inside the VM.
# Mount USB drives at /home/sandbox/usb/ for convenient access.
{ config, lib, pkgs, ... }:

let
  meta = import ./meta.nix;

  sandboxUser = "sandbox";
  sandboxHome = "/home/${sandboxUser}";
  vmName      = "microvm-usb-sandbox";

  serveScript = pkgs.writeShellScript "usb-files-serve" ''
    set -euo pipefail
    XFER_FILE="${sandboxHome}/shared/xfer.enc"
    if [ ! -f "$XFER_FILE" ]; then
      echo "ERROR: $XFER_FILE not found" >&2
      exit 1
    fi
    ${pkgs.python3}/bin/python3 - "$XFER_FILE" <<'PYEOF'
import sys, http.server, os
xfer_file = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/xfer.enc':
            self.send_response(404); self.end_headers(); return
        size = os.path.getsize(xfer_file)
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.send_header('Content-Type', 'application/octet-stream')
        self.end_headers()
        with open(xfer_file, 'rb') as f:
            while True:
                chunk = f.read(65536)
                if not chunk: break
                self.wfile.write(chunk)
        raise SystemExit(0)
    def log_message(self, *_): pass
http.server.HTTPServer(("", 8888), Handler).handle_request()
PYEOF
  '';

  handlerScript = pkgs.writeShellScript "usb-files-handler" ''
    set -euo pipefail
    SHARED_DIR="${sandboxHome}/shared"
    XFER_FILE="$SHARED_DIR/xfer.enc"
    SERVE_PID_FILE="$SHARED_DIR/.serve.pid"
    mkdir -p "$SHARED_DIR"
    read -r CMD REST

    case "$CMD" in

      ENCRYPT)
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        SOURCE=$(echo "$REST" | cut -d' ' -f2-)
        SOURCE_FULL="${sandboxHome}/$SOURCE"
        rm -f "$XFER_FILE"
        if [ -d "$SOURCE_FULL" ] || [ -f "$SOURCE_FULL" ]; then
          ${pkgs.gnutar}/bin/tar \
            --use-compress-program=${pkgs.gzip}/bin/gzip \
            -cf - \
            -C "$(${pkgs.coreutils}/bin/dirname "$SOURCE_FULL")" \
            "$(${pkgs.coreutils}/bin/basename "$SOURCE_FULL")" \
            | ${pkgs.openssl}/bin/openssl enc -aes-256-cbc -pbkdf2 \
                -pass pass:"$PASSPHRASE" -out "$XFER_FILE"
        else
          echo "ERROR: source not found: $SOURCE_FULL"
          exit 1
        fi
        HASH=$(${pkgs.coreutils}/bin/sha256sum "$XFER_FILE" | cut -d' ' -f1)
        echo "SHA256=$HASH"
        ;;

      SERVE)
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        ${serveScript} &
        SERVE_PID=$!
        echo "$SERVE_PID" > "$SERVE_PID_FILE"
        echo "READY"
        ;;

      SERVE_STOP)
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        echo "OK"
        ;;

      CLEANUP)
        rm -f "$XFER_FILE"
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        echo "OK"
        ;;

      CHECKSUM)
        PATH_ARG=$(echo "$REST" | cut -d' ' -f1-)
        PATH_FULL="${sandboxHome}/$PATH_ARG"
        if [ -f "$PATH_FULL" ]; then
          HASH=$(${pkgs.coreutils}/bin/sha256sum "$PATH_FULL" | cut -d' ' -f1)
          echo "SHA256=$HASH"
        else
          echo "ERROR: file not found: $PATH_FULL"
          exit 1
        fi
        ;;

      PING)
        echo "PONG"
        ;;

      *)
        echo "ERROR: unknown command: $CMD"
        exit 1
        ;;
    esac
  '';

in {

  # =========================================================================
  # MICROVM CONFIGURATION
  # =========================================================================
  microvm = {
    mem  = 1023;

    interfaces = [{
      type = "tap";
      id   = meta.tapId;
      mac  = meta.tapMac;
    }];

    vsock.cid = meta.vsockCid;

    # QEMU monitor socket for host-side disk hotplug
    # Host sends: drive_add + device_add virtio-blk-pci  (no libusb needed)
    #             device_del + drive_del to release
    # -sandbox off: microvm.nix sets -sandbox on by default, which blocks openat()
    # for new devices after init — needed for drive_add hotplug to work.
    qemu.extraArgs = [
      "-sandbox"  "off"
      "-chardev" "socket,id=monitor,path=/var/lib/microvms/${vmName}/monitor.sock,server=on,wait=off"
      "-mon"     "chardev=monitor,mode=readline"
    ];
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # =========================================================================
  # NETWORK
  # =========================================================================
  networking.useDHCP = lib.mkForce false;

  systemd.network = {
    enable = true;
    networks."10-usb-sandbox" = {
      matchConfig.MACAddress = meta.tapMac;
      address = [ "${meta.subnet}.10/24" ];
      # No gateway — isolated bridge, files VM only, no internet
      linkConfig.RequiredForOnline = "no";
    };
  };

  # =========================================================================
  # FILES AGENT (vsock 14506)
  # =========================================================================
  systemd.tmpfiles.rules = [
    "d ${sandboxHome}        0750 ${sandboxUser} users -"
    "d ${sandboxHome}/shared 0750 ${sandboxUser} users -"
    "d ${sandboxHome}/usb    0750 ${sandboxUser} users -"
  ];

  systemd.services.usb-files-agent = {
    description = "USB sandbox files agent (vsock 14506)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "always";
      RestartSec = "1s";
      User       = sandboxUser;
      ExecStart  = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14506,reuseaddr,fork EXEC:${handlerScript}";
    };
  };

  networking.firewall = {
    enable = lib.mkForce true;
    allowedTCPPorts = [ 8888 ];  # HTTP file serving to files VM
  };

  # =========================================================================
  # USERS
  # =========================================================================
  users.groups.sandbox = {};
  users.users.sandbox = {
    isNormalUser = true;
    group        = "sandbox";
    extraGroups  = [ "wheel" "disk" ];
    password     = "sandbox";
    shell        = pkgs.bash;
  };
  services.getty.autologinUser = sandboxUser;

  users.motd = ''

    ╔══════════════════════════════════════════════════════╗
    ║              USB SANDBOX  —  microvm-usb-sandbox     ║
    ╚══════════════════════════════════════════════════════╝

    The USB drive has been passed in as /dev/vdb (read-only).
    Files leave only via the files VM — nothing else has egress.

    COMMANDS
      usb list              — show attached block devices
      usb scan              — detect filesystems on /dev/vdb*
      usb mount /dev/vdbX   — mount partition under ~/usb/
      usb umount /dev/vdbX  — unmount
      lsusb                 — USB device info
      lsblk                 — block device tree

    FILE TRANSFER (from host)
      microvm files store usb-sandbox/usb/vdbX/<path>
      microvm files transfer usb-sandbox/usb/vdbX/<path> <vm>/<dest>

    Ctrl+] to detach console (VM keeps running)

  '';

  # =========================================================================
  # PACKAGES
  # =========================================================================
  environment.systemPackages = with pkgs; [
    # USB & filesystem inspection
    usbutils exfatprogs ntfs3g
    # File transfer
    socat openssl python3 coreutils gnutar gzip
    # Utilities
    gawk gnugrep gnused unzip p7zip iproute2 file
    # USB helper
    (writeShellScriptBin "usb" ''
      USB_DIR="${sandboxHome}/usb"
      mkdir -p "$USB_DIR"
      case "''${1:-}" in
        list)
          lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || echo "No block devices"
          ;;
        scan)
          for dev in /dev/sd[a-z] /dev/sd[a-z][0-9] /dev/vd[b-z] /dev/vd[b-z][0-9]; do
            [ -b "$dev" ] || continue
            FS=$(${pkgs.file}/bin/file -bs "$dev" | cut -d: -f1)
            echo "$dev: $FS"
          done
          ;;
        mount)
          DEV="$2"
          if [ -z "$DEV" ]; then
            echo "Usage: usb mount /dev/vdbX"
            exit 1
          fi
          MP="$USB_DIR/$(basename "$DEV")"
          mkdir -p "$MP"
          sudo mount -t auto "$DEV" "$MP"
          echo "Mounted $DEV at $MP"
          ;;
        umount)
          DEV="$2"
          if [ -z "$DEV" ]; then
            echo "Usage: usb umount /dev/vdbX"
            exit 1
          fi
          sudo umount "$USB_DIR/$(basename "$DEV")"
          ;;
        *)
          echo "Usage: usb {list|scan|mount /dev/vdbX|umount /dev/vdbX}"
          ;;
      esac
    '')
  ];

}
