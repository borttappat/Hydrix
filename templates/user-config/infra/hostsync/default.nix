# Hostsync infra VM — secure host file inbox
#
# Receives encrypted file transfers from the files VM and decrypts them
# into /mnt/host-inbox/, which is virtiofs-shared to ~/vm-inbox/ on the host.
# No internet access. Only the files VM (192.168.214.2) can reach port 8888.
#
# Usage from host:
#   microvm files transfer <src-vm>/<path> hostsync/<dest-subdir>
#   → files appear at ~/vm-inbox/<dest-subdir>/<filename>
#
#   Drop a file into ~/vm-inbox/, then:
#   microvm files transfer hostsync/<filename> <dst-vm>/<dest-path>
#   → file delivered from inbox into destination VM
#
# vsock 14506: host ↔ hostsync (ENCRYPT, SERVE, RECEIVE_PREPARE, DECRYPT, CLEANUP, PING)
{ config, lib, pkgs, ... }:
let
  meta = import ./meta.nix;

  hostUsername = config.hydrix.username;

  inbox = "/mnt/host-inbox";

  # One-shot HTTP GET server — serves xfer.enc to the files VM.
  # Invoked by SERVE; exits after the first completed GET.
  serveScript = pkgs.writeShellScript "hostsync-serve" ''
    ${pkgs.python3}/bin/python3 - "${inbox}/xfer.enc" << 'PYEOF'
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

  # One-shot HTTP PUT listener — saves received blob to the inbox.
  # Invoked by RECEIVE_PREPARE; exits after the first completed PUT.
  receiveScript = pkgs.writeShellScript "hostsync-receive" ''
    ${pkgs.python3}/bin/python3 - "${inbox}/xfer.enc" << 'PYEOF'
import sys, http.server, os

dest_file = sys.argv[1]
os.makedirs(os.path.dirname(dest_file), exist_ok=True)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        if self.path != '/xfer.enc':
            self.send_response(404); self.end_headers(); return
        length = int(self.headers.get('Content-Length', 0))
        with open(dest_file, 'wb') as f:
            rem = length
            while rem > 0:
                chunk = self.rfile.read(min(65536, rem))
                if not chunk: break
                f.write(chunk); rem -= len(chunk)
        self.send_response(200); self.end_headers(); self.wfile.write(b'OK\n')
        raise SystemExit(0)
    def log_message(self, *_): pass

http.server.HTTPServer(("", 8888), Handler).handle_request()
PYEOF
  '';

  # vsock command handler — one connection per command (socat fork model).
  # Protocol is compatible with the existing cmd_files_transfer flow:
  #   ENCRYPT <pass> <path>  — encrypt inbox/<path> → inbox/xfer.enc, returns SHA256=<hash>
  #   SERVE            — arms HTTP GET server serving xfer.enc, returns READY
  #   SERVE_STOP       — kills HTTP GET server, returns OK
  #   RECEIVE_PREPARE  — arms HTTP PUT listener, returns READY
  #   RECEIVE_STOP     — kills listener, returns OK
  #   DECRYPT <pass> <archive-ignored> <dest-subdir>
  #                    — decrypts inbox/xfer.enc into inbox/<dest-subdir>/, returns OK
  #   CLEANUP          — removes xfer.enc + kills all helpers, returns OK
  #   CHECKSUM <path>  — sha256 of inbox/<path>, returns SHA256=<hash>
  #   PING             — returns PONG
  handlerScript = pkgs.writeShellScript "hostsync-handler" ''
    set -euo pipefail
    INBOX="${inbox}"
    XFER_FILE="$INBOX/xfer.enc"
    SERVE_PID_FILE="$INBOX/.serve.pid"
    RECV_PID_FILE="$INBOX/.recv.pid"

    mkdir -p "$INBOX"

    read -r CMD REST

    case "$CMD" in

      PING)
        echo "PONG"
        ;;

      ENCRYPT)
        # ENCRYPT <passphrase> <source-path-relative-to-inbox>
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        SOURCE=$(echo "$REST" | cut -d' ' -f2-)
        SOURCE_FULL="$INBOX/$SOURCE"
        rm -f "$XFER_FILE"
        if [ -d "$SOURCE_FULL" ] || [ -f "$SOURCE_FULL" ]; then
          ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -cf - \
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
        echo "$!" > "$SERVE_PID_FILE"
        echo "READY"
        ;;

      SERVE_STOP)
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        echo "OK"
        ;;

      RECEIVE_PREPARE)
        # Kill any stale listener
        if [ -f "$RECV_PID_FILE" ]; then
          kill "$(cat "$RECV_PID_FILE")" 2>/dev/null || true
          rm -f "$RECV_PID_FILE"
        fi
        ${receiveScript} &
        echo "$!" > "$RECV_PID_FILE"
        echo "READY"
        ;;

      RECEIVE_STOP)
        if [ -f "$RECV_PID_FILE" ]; then
          kill "$(cat "$RECV_PID_FILE")" 2>/dev/null || true
          rm -f "$RECV_PID_FILE"
        fi
        echo "OK"
        ;;

      DECRYPT)
        # DECRYPT <passphrase> <archive-path-ignored> [<dest-subdir>]
        # archive-path is always xfer.enc in the inbox — field is ignored for
        # compatibility with the generic cmd_files_transfer protocol.
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        EXTRACT_PARENT=$(echo "$REST" | cut -d' ' -f3-)
        if [ -z "$EXTRACT_PARENT" ]; then
          EXTRACT_FULL="$INBOX"
        else
          EXTRACT_FULL="$INBOX/$EXTRACT_PARENT"
        fi
        mkdir -p "$EXTRACT_FULL"
        ${pkgs.openssl}/bin/openssl enc -d -aes-256-cbc -pbkdf2 \
          -pass pass:"$PASSPHRASE" -in "$XFER_FILE" \
          | ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
              -xf - -C "$EXTRACT_FULL"
        rm -f "$XFER_FILE"
        echo "OK"
        ;;

      CLEANUP)
        rm -f "$XFER_FILE"
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        if [ -f "$RECV_PID_FILE" ]; then
          kill "$(cat "$RECV_PID_FILE")" 2>/dev/null || true
          rm -f "$RECV_PID_FILE"
        fi
        echo "OK"
        ;;

      CHECKSUM)
        PATH_ARG="$REST"
        PATH_FULL="$INBOX/$PATH_ARG"
        if [ -f "$PATH_FULL" ]; then
          HASH=$(${pkgs.coreutils}/bin/sha256sum "$PATH_FULL" | cut -d' ' -f1)
          echo "SHA256=$HASH"
        else
          echo "ERROR: file not found: $PATH_FULL"
          exit 1
        fi
        ;;

      *)
        echo "ERROR: unknown command: $CMD"
        exit 1
        ;;
    esac
  '';

in {
  microvm.vsock.cid = meta.vsockCid;

  microvm.interfaces = [{
    type = "tap";
    id   = meta.tapId;
    mac  = meta.tapMac;
  }];

  microvm.mem = lib.mkForce 256;

  # Host inbox share — virtiofsd on host maps ~/vm-inbox → /mnt/host-inbox in VM.
  # Files decrypted here are immediately visible on the host.
  microvm.shares = [{
    tag        = "host-inbox";
    source     = "/home/${hostUsername}/vm-inbox";
    mountPoint = "${inbox}";
    proto      = "virtiofs";
  }];

  # nix-overlay only — no persistent home volume needed (inbox is the virtiofs share)
  microvm.volumes = lib.mkForce [{
    image      = "/var/lib/microvms/microvm-hostsync/nix-overlay.qcow2";
    mountPoint = "/nix/.rw-store";
    size       = 2048;
    autoCreate = true;
  }];

  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  networking.useDHCP = lib.mkForce false;

  systemd.network = {
    enable = true;
    networks."10-hostsync" = {
      matchConfig.MACAddress = meta.tapMac;
      address                = [ "${meta.subnet}.10/24" ];
      linkConfig.RequiredForOnline = "no";
    };
  };

  # Only the files VM (.2 on this bridge) may reach port 8888.
  # vsock traffic is kernel-mediated and not subject to nftables.
  networking.nftables = {
    enable = true;
    tables."hostsync" = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter; policy drop;
          iif lo accept
          ct state established,related accept
          ct state invalid drop
          ip protocol icmp accept
          ip saddr ${meta.subnet}.2 tcp dport 8888 accept
        }
        chain forward {
          type filter hook forward priority filter; policy drop;
        }
      '';
    };
  };

  systemd.services.hostsync-agent = {
    description = "Hostsync vsock agent (port 14506)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "always";
      RestartSec = "1s";
      ExecStart  = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14506,reuseaddr,fork EXEC:${handlerScript}";
    };
  };

  users.users.hostsync = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    password     = "hostsync";
    home         = "/home/hostsync";
  };
  services.getty.autologinUser = "hostsync";

  environment.systemPackages = with pkgs; [
    socat openssl python3 coreutils gnutar gzip
  ];
}
