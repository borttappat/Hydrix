# Filesharing infra VM — encrypted inter-VM file transfer hub
#
# Base (headless, virtiofs store) provided by microvm-infra-base via mkInfraVm.
# This module adds: vsock agent, multi-bridge networking, persistent storage.
#
# Profile VMs are auto-discovered from profiles/. Privacy VMs (lurking) are
# excluded. User infra VMs that need transfer access are listed in infraParticipants.
#
# vsock 14505: host ↔ files VM (FETCH, DELIVER, STORE, STORE_RAW, LIST, PING)
{ config, lib, pkgs, ... }:
let
  meta = import ./meta.nix;

  vmName = config.networking.hostName;

  # Privacy VMs — intentionally excluded from file transfer
  privacyVMs = [ "lurking" ];

  # Auto-discover profile VMs from profiles/ directory
  profilesDir = ../../profiles;
  profileNames = builtins.attrNames (builtins.readDir profilesDir);
  validProfiles = builtins.filter (n:
    !(builtins.elem n privacyVMs) &&
    builtins.pathExists (profilesDir + "/${n}/meta.nix")
  ) profileNames;

  # TAP abbreviation: first 4 chars of profile name
  abbrev = n: builtins.substring 0 4 n;

  # Per-bridge TAP/MAC/IP mappings for profile VMs
  # MAC: 02:00:00:02:<cidN>:01, cidN = zero-padded decimal of (vsockCid - 100)
  # Valid for profile CIDs 102-199
  profileIfaceMap = builtins.listToAttrs (map (name:
    let
      pmeta = import (profilesDir + "/${name}/meta.nix");
      cidN  = lib.fixedWidthString 2 "0" (toString (pmeta.vsockCid - 100));
    in lib.nameValuePair name {
      tap    = "mv-files-${abbrev name}";
      mac    = "02:00:00:02:${cidN}:01";
      subnet = pmeta.subnet;
    }
  ) validProfiles);

  # Infra VMs that participate in file transfer (explicit — not auto-discovered)
  # MAC 5th octet: hex(vsockCid - 100), prefixed 0 to stay in valid range
  usbSandboxMeta = import ../usb-sandbox/meta.nix;
  hostsyncMeta   = import ../hostsync/meta.nix;
  infraIfaceMap = {
    # usb-sandbox: files VM gets a TAP on br-usb-sandbox so both VMs share that bridge
    "usb-sandbox" = {
      tap    = "mv-files-usb";
      mac    = "02:00:00:02:6d:02";  # Unique MAC on br-usb-sandbox (usb-sandbox itself uses :6d:01)
      subnet = usbSandboxMeta.subnet;
    };
    # hostsync: files VM gets a TAP on br-hostsync to HTTP-deliver blobs to 192.168.214.10
    "hostsync" = {
      tap    = "mv-files-hsy";
      mac    = "02:00:00:02:d6:02";  # CID 214 = 0xd6; :02 = files VM side on this bridge
      subnet = hostsyncMeta.subnet;
    };
  };

  ifaceMap = profileIfaceMap // infraIfaceMap;

  extraInterfaces = lib.mapAttrsToList (_: i: {
    type = "tap";
    id   = i.tap;
    mac  = i.mac;
  }) ifaceMap;

  filesAgentScript = pkgs.writeShellScript "microvm-files-agent" ''
    set -euo pipefail
    STORAGE_DIR="/storage"

    read -r CMD REST

    case "$CMD" in

      FETCH)
        # FETCH <source-ip> <filename>
        SRC_IP=$(echo "$REST" | cut -d' ' -f1)
        FILENAME=$(echo "$REST" | cut -d' ' -f2)
        DEST="$STORAGE_DIR/tmp/$FILENAME"
        mkdir -p "$STORAGE_DIR/tmp"
        rm -f "$DEST"
        CURL_RC=0
        ${pkgs.curl}/bin/curl -sf --connect-timeout 10 \
          "http://$SRC_IP:8888/$FILENAME" -o "$DEST" || CURL_RC=$?
        if [ "$CURL_RC" -ne 0 ]; then
          echo "ERROR: curl rc=$CURL_RC fetching from $SRC_IP:8888"
          exit 0
        fi
        HASH=$(${pkgs.coreutils}/bin/sha256sum "$DEST" | cut -d' ' -f1)
        echo "SHA256=$HASH"
        ;;

      DELIVER)
        # DELIVER <dest-ip> <filename>
        DEST_IP=$(echo "$REST" | cut -d' ' -f1)
        FILENAME=$(echo "$REST" | cut -d' ' -f2)
        SRC="$STORAGE_DIR/tmp/$FILENAME"
        if [ ! -f "$SRC" ]; then
          echo "ERROR: file not found: $SRC"
          exit 0
        fi
        # Use || to prevent set -e from silently exiting on curl failure
        HTTP_CODE=""
        CURL_RC=0
        HTTP_CODE=$(${pkgs.curl}/bin/curl -s --connect-timeout 10 -X PUT \
          "http://$DEST_IP:8888/xfer.enc" \
          --data-binary @"$SRC" -o /dev/null -w '%{http_code}') || CURL_RC=$?
        if [ "$CURL_RC" -ne 0 ]; then
          echo "ERROR: curl rc=$CURL_RC connecting to $DEST_IP:8888"
          exit 0
        fi
        if [ "$HTTP_CODE" = "200" ]; then
          HASH=$(${pkgs.coreutils}/bin/sha256sum "$SRC" | cut -d' ' -f1)
          echo "SHA256=$HASH"
        else
          echo "ERROR: upload failed (HTTP $HTTP_CODE)"
          exit 0
        fi
        ;;

      STORE)
        # STORE <passphrase> <vm-type> <filename>
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        VM_TYPE=$(echo "$REST" | cut -d' ' -f2)
        FILENAME=$(echo "$REST" | cut -d' ' -f3)
        SRC="$STORAGE_DIR/tmp/$FILENAME"
        DEST_DIR="$STORAGE_DIR/$VM_TYPE"
        if [ ! -f "$SRC" ]; then
          echo "ERROR: source not found: $SRC"
          exit 0
        fi
        mkdir -p "$DEST_DIR"
        ERRFILE=$(${pkgs.coreutils}/bin/mktemp)
        if ! ${pkgs.openssl}/bin/openssl enc -d -aes-256-cbc -pbkdf2 \
              -pass pass:"$PASSPHRASE" -in "$SRC" 2>"$ERRFILE" \
              | ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
                  -xf - -C "$DEST_DIR" 2>>"$ERRFILE"; then
          echo "ERROR: $(cat "$ERRFILE")"
          rm -f "$ERRFILE"
          exit 0
        fi
        rm -f "$ERRFILE" "$SRC"
        echo "OK"
        ;;

      STORE_RAW)
        # STORE_RAW <vm-type> <filename>
        VM_TYPE=$(echo "$REST" | cut -d' ' -f1)
        FILENAME=$(echo "$REST" | cut -d' ' -f2)
        SRC="$STORAGE_DIR/tmp/$FILENAME"
        DEST_DIR="$STORAGE_DIR/$VM_TYPE"
        mkdir -p "$DEST_DIR"
        mv "$SRC" "$DEST_DIR/$FILENAME"
        HASH=$(${pkgs.coreutils}/bin/sha256sum "$DEST_DIR/$FILENAME" | cut -d' ' -f1)
        echo "SHA256=$HASH"
        ;;

      CLEANUP_TMP)
        FILENAME=$(echo "$REST" | cut -d' ' -f1)
        rm -f "$STORAGE_DIR/tmp/$FILENAME"
        echo "OK"
        ;;

      LIST)
        VM_TYPE=$(echo "$REST" | cut -d' ' -f1)
        TARGET="$STORAGE_DIR"
        if [ -n "$VM_TYPE" ]; then
          TARGET="$STORAGE_DIR/$VM_TYPE"
        fi
        if [ -d "$TARGET" ]; then
          find "$TARGET" -type f | sort
        fi
        echo "END"
        ;;

      PING)
        echo "PONG"
        ;;

      SHUTDOWN)
        echo "OK"
        exit 0
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
  }] ++ extraInterfaces;

  microvm.mem = 512;

  microvm.volumes = lib.mkForce [
    {
      image      = "/var/lib/microvms/${vmName}/storage.qcow2";
      mountPoint = "/storage";
      size       = 51200;
      autoCreate = true;
    }
    {
      image      = "/var/lib/microvms/${vmName}/nix-overlay.qcow2";
      mountPoint = "/nix/.rw-store";
      size       = 4096;
      autoCreate = true;
    }
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules  = [ "vmw_vsock_virtio_transport" ];

  networking.useDHCP = lib.mkForce false;

  systemd.network = {
    enable = true;
    networks = {
      "10-files-home" = {
        matchConfig.MACAddress = meta.tapMac;
        address = [ "${meta.subnet}.10/24" ];
        gateway = [ "${meta.subnet}.253" ];
        dns     = [ "${meta.subnet}.253" ];
        linkConfig.RequiredForOnline = "no";
      };
    } // lib.mapAttrs' (name: i: lib.nameValuePair "20-files-${name}" {
      matchConfig.MACAddress       = i.mac;
      address                      = [ "${i.subnet}.2/24" ];
      linkConfig.RequiredForOnline = "no";
    }) ifaceMap;
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = 0;

  networking.nftables = {
    enable = true;
    tables."files-vm" = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter; policy drop;
          iif lo accept
          ct state established,related accept
          ct state invalid drop
          ip protocol icmp accept
          tcp dport 8888 accept
        }
        chain forward {
          type filter hook forward priority filter; policy drop;
        }
      '';
    };
  };

  # Format /dev/vda as ext4 on first boot (or if unformatted after corruption).
  # Must run before systemd-fsck, which would fail on an empty block device.
  systemd.services.storage-init = {
    description = "Initialize /storage filesystem if needed";
    wantedBy    = [ "local-fs-pre.target" ];
    before      = [ "systemd-fsck@dev-vda.service" "storage.mount" ];
    after       = [ "dev-vda.device" ];
    requires    = [ "dev-vda.device" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = pkgs.writeShellScript "storage-init" ''
        if ! ${pkgs.e2fsprogs}/bin/e2fsck -n /dev/vda >/dev/null 2>&1; then
          echo "Formatting /dev/vda as ext4..."
          ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L storage /dev/vda
        fi
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d /storage     0755 root root -"
    "d /storage/tmp 0750 root root -"
  ];

  systemd.services.microvm-files-agent = {
    description = "Files VM vsock agent (port 14505)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" "storage.mount" ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "always";
      RestartSec = "1s";
      ExecStart  = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14505,reuseaddr,fork EXEC:${filesAgentScript}";
    };
  };

  environment.systemPackages = with pkgs; [
    curl openssl socat coreutils gnutar gzip iproute2 htop ncdu e2fsprogs
  ];

  # Dedicated user for console autologin — matches builder/gitsync pattern.
  # Root autologin on ttyS0 is blocked by login(1)'s securetty check.
  users.users.files = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    password     = "files";
    home         = "/home/files";
  };
  services.getty.autologinUser = "files";

}
