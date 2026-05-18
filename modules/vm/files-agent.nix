# Files Agent - Per-VM vsock service for file transfer operations
#
# This module is imported by all regular VMs (via microvm-base.nix).
# It listens on vsock port 14506 for commands from the host and executes
# encrypted file operations on behalf of the files VM transfer flow.
#
# Commands:
#   ENCRYPT <passphrase> <source-path>
#     Encrypts source path (file or directory) to ~/shared/xfer.enc
#     Returns: SHA256=<hash>
#
#   DECRYPT <passphrase> <archive-path> <target-dir>
#     Decrypts and unpacks archive into target-dir, then deletes archive
#     Returns: OK
#
#   SERVE
#     Starts ephemeral HTTP server on port 8888 serving ~/shared/xfer.enc
#     Returns: READY
#
#   SERVE_STOP
#     Stops the ephemeral HTTP server
#     Returns: OK
#
#   RECEIVE_PREPARE <dest-dir>
#     Creates dest-dir, starts one-shot HTTP PUT handler on port 8888
#     Blocks until the PUT request arrives, then exits
#     Returns: READY (before the PUT arrives)
#
#   CLEANUP
#     Deletes ~/shared/xfer.enc, kills any HTTP processes on port 8888
#     Returns: OK
#
#   CHECKSUM <path>
#     Returns: SHA256=<hash>
#
{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  userHome = "/home/${username}";
  vmType = config.hydrix.vmType;
  vmSubnet = config.hydrix.networking.vmSubnet;

  # Serve script: one-shot HTTP server serving ~/shared/xfer.enc
  serveScript = pkgs.writeShellScript "vm-files-serve" ''
    set -euo pipefail
    SHARED_DIR="${userHome}/shared"
    XFER_FILE="$SHARED_DIR/xfer.enc"

    if [ ! -f "$XFER_FILE" ]; then
      echo "ERROR: $XFER_FILE not found" >&2
      exit 1
    fi

    # Minimal HTTP server: serve exactly one file on port 8888
    # Exits after the first completed GET request
    ${pkgs.python3}/bin/python3 - "$XFER_FILE" << 'PYEOF'
import sys, http.server, os

xfer_file = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/xfer.enc':
            self.send_response(404)
            self.end_headers()
            return
        size = os.path.getsize(xfer_file)
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.send_header('Content-Type', 'application/octet-stream')
        self.end_headers()
        with open(xfer_file, 'rb') as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        # Shut down after one successful transfer
        raise SystemExit(0)
    def log_message(self, *_): pass

httpd = http.server.HTTPServer(("", 8888), Handler)
httpd.handle_request()
PYEOF
  '';

  # Receive script: one-shot HTTP server accepting PUT to /xfer.enc
  receiveScript = pkgs.writeShellScript "vm-files-receive" ''
    set -euo pipefail
    DEST_DIR="$1"

    ${pkgs.python3}/bin/python3 - "$DEST_DIR" << 'PYEOF'
import sys, http.server, os

dest_dir = sys.argv[1]
os.makedirs(dest_dir, exist_ok=True)
dest_file = os.path.join(dest_dir, 'xfer.enc')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        if self.path != '/xfer.enc':
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get('Content-Length', 0))
        with open(dest_file, 'wb') as f:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK\n')
        raise SystemExit(0)
    def log_message(self, *_): pass

httpd = http.server.HTTPServer(("", 8888), Handler)
httpd.handle_request()
PYEOF
  '';

  # Main handler script: reads one command from stdin, executes, writes response
  handlerScript = pkgs.writeShellScript "vm-files-handler" ''
    set -euo pipefail

    SHARED_DIR="${userHome}/shared"
    XFER_FILE="$SHARED_DIR/xfer.enc"
    SERVE_PID_FILE="$SHARED_DIR/.serve.pid"

    mkdir -p "$SHARED_DIR"

    # Read the command line
    read -r CMD REST

    case "$CMD" in

      ENCRYPT)
        # ENCRYPT <passphrase> <source-path>
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        SOURCE=$(echo "$REST" | cut -d' ' -f2-)
        SOURCE_FULL="${userHome}/$SOURCE"

        rm -f "$XFER_FILE"

        if [ -d "$SOURCE_FULL" ] || [ -f "$SOURCE_FULL" ]; then
          ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -cf - -C "$(${pkgs.coreutils}/bin/dirname "$SOURCE_FULL")" "$(${pkgs.coreutils}/bin/basename "$SOURCE_FULL")" \
            | ${pkgs.openssl}/bin/openssl enc -aes-256-cbc -pbkdf2 \
                -pass pass:"$PASSPHRASE" -out "$XFER_FILE"
        else
          echo "ERROR: source not found: $SOURCE_FULL"
          exit 1
        fi

        HASH=$(${pkgs.coreutils}/bin/sha256sum "$XFER_FILE" | cut -d' ' -f1)
        echo "SHA256=$HASH"
        ;;

      DECRYPT)
        # DECRYPT <passphrase> <archive-path> <extract-parent>
        # extract-parent: directory to extract INTO (the archive recreates the
        # top-level name). Empty string means extract directly into $HOME.
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        ARCHIVE=$(echo "$REST" | cut -d' ' -f2)
        EXTRACT_PARENT=$(echo "$REST" | cut -d' ' -f3-)
        ARCHIVE_FULL="${userHome}/$ARCHIVE"
        if [ -z "$EXTRACT_PARENT" ]; then
          EXTRACT_FULL="${userHome}"
        else
          EXTRACT_FULL="${userHome}/$EXTRACT_PARENT"
        fi

        mkdir -p "$EXTRACT_FULL"
        ${pkgs.openssl}/bin/openssl enc -d -aes-256-cbc -pbkdf2 \
          -pass pass:"$PASSPHRASE" -in "$ARCHIVE_FULL" \
          | ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -xf - -C "$EXTRACT_FULL"
        rm -f "$ARCHIVE_FULL"
        echo "OK"
        ;;

      SERVE)
        # Kill any existing serve process
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        # Start serve process in background, record PID
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

      RECEIVE_PREPARE)
        # Always receive into ~/shared/ — DECRYPT places files at the right path
        # Start receive server in background, return READY immediately
        ${receiveScript} "$SHARED_DIR" &
        RECV_PID=$!
        echo "$RECV_PID" > "$SHARED_DIR/.recv.pid"
        echo "READY"
        ;;

      RECEIVE_STOP)
        if [ -f "$SHARED_DIR/.recv.pid" ]; then
          kill "$(cat "$SHARED_DIR/.recv.pid")" 2>/dev/null || true
          rm -f "$SHARED_DIR/.recv.pid"
        fi
        echo "OK"
        ;;

      CLEANUP)
        rm -f "$XFER_FILE"
        if [ -f "$SERVE_PID_FILE" ]; then
          kill "$(cat "$SERVE_PID_FILE")" 2>/dev/null || true
          rm -f "$SERVE_PID_FILE"
        fi
        if [ -f "$SHARED_DIR/.recv.pid" ]; then
          kill "$(cat "$SHARED_DIR/.recv.pid")" 2>/dev/null || true
          rm -f "$SHARED_DIR/.recv.pid"
        fi
        echo "OK"
        ;;

      CHECKSUM)
        # CHECKSUM <path>
        PATH_ARG=$(echo "$REST" | cut -d' ' -f1-)
        PATH_FULL="${userHome}/$PATH_ARG"
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
  config = lib.mkIf (vmType != "") {

    # Ensure ~/shared exists for the user
    systemd.tmpfiles.rules = [
      "d ${userHome}/shared 0750 ${username} users -"
    ];

    # vsock 14506 listener — one handler per connection
    systemd.services.vm-files-agent = {
      description = "VM files agent (vsock 14506)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "1s";
        User = username;
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14506,reuseaddr,fork EXEC:${handlerScript}";
      };
    };

    # Firewall: open port 8888 exclusively for the files VM (.2 on this bridge).
    # The files VM reaches this VM's HTTP server (port 8888) during transfers.
    # vmSubnet is set from the profile's own meta.nix via hydrix.networking.vmSubnet.
    networking.firewall.extraCommands = lib.mkIf (vmSubnet != "") ''
      iptables -A nixos-fw -p tcp --dport 8888 -s ${vmSubnet}.2 -j ACCEPT
    '';

    environment.systemPackages = with pkgs; [
      socat
      openssl
      python3
      coreutils
      gnutar
      gzip
    ];
  };
}
