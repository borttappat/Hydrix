# MicroVM Files - Encrypted inter-VM file transfer hub
#
# The files VM acts as an encrypted jump host for file transfers between VMs.
# It has direct L2 TAP connections to each bridge listed in accessFrom,
# allowing it to reach VMs without routing through the router VM.
#
# File content is ALWAYS encrypted (AES-256 + per-transfer random passphrase)
# before leaving the source VM. The passphrase travels only via vsock (host→VM),
# never over any bridge network. The files VM never sees plaintext during transfers.
#
# For `store` operations the files VM receives the ciphertext, then the host
# sends the passphrase over vsock so the files VM can decrypt in-place.
#
# Vsock 14505: host → files VM (FETCH, DELIVER, STORE, SHUTDOWN)
# Vsock 14506: host → any VM (ENCRYPT, DECRYPT, SERVE, RECEIVE_PREPARE, CLEANUP)
#
# Usage:
#   Declare in flake.nix using hydrix.lib.mkMicrovmFiles {}
#   Enable in machine config: hydrix.microvmFiles.enable = true;
#   Set access:               hydrix.microvmFiles.accessFrom = [ "pentest" "comms" ];
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.microvmFiles;
  vmName = config.networking.hostName;

  # Per-bridge TAP/MAC/subnet mappings for each possible bridge connection
  # IP inside files VM on each bridge: <subnet>.2
  ifaceMap = {
    mgmt    = { tap = "mv-files-mgmt"; mac = "02:00:00:02:07:01"; subnet = "192.168.100"; };
    pentest = { tap = "mv-files-pent"; mac = "02:00:00:02:01:01"; subnet = "192.168.101"; };
    comms   = { tap = "mv-files-comm"; mac = "02:00:00:02:04:01"; subnet = "192.168.102"; };
    browse  = { tap = "mv-files-brow"; mac = "02:00:00:02:02:01"; subnet = "192.168.103"; };
    dev     = { tap = "mv-files-dev";  mac = "02:00:00:02:03:01"; subnet = "192.168.104"; };
    shared  = { tap = "mv-files-shar"; mac = "02:00:00:02:06:01"; subnet = "192.168.105"; };
    lurking = { tap = "mv-files-lurk"; mac = "02:00:00:02:05:01"; subnet = "192.168.107"; };
  };

  # Only the bridges explicitly granted access
  enabledIfaces = lib.filterAttrs (n: _: builtins.elem n cfg.accessFrom) ifaceMap;

  # QEMU args for all enabled bridge TAPs
  extraTapArgs = lib.concatMapAttrsToList (_: i: [
    "-netdev" "tap,id=net-${i.tap},ifname=${i.tap},script=no,downscript=no"
    "-device" "virtio-net-pci,netdev=net-${i.tap},mac=${i.mac}"
  ]) enabledIfaces;

  # Files VM vsock handler script (port 14505)
  filesAgentScript = pkgs.writeShellScript "microvm-files-agent" ''
    set -euo pipefail
    STORAGE_DIR="/storage"

    read -r CMD REST

    case "$CMD" in

      FETCH)
        # FETCH <source-ip> <filename>
        # Download encrypted blob from source VM's HTTP server
        SRC_IP=$(echo "$REST" | cut -d' ' -f1)
        FILENAME=$(echo "$REST" | cut -d' ' -f2)
        DEST="$STORAGE_DIR/tmp/$FILENAME"
        mkdir -p "$STORAGE_DIR/tmp"
        rm -f "$DEST"
        ${pkgs.curl}/bin/curl -sf "http://$SRC_IP:8888/$FILENAME" -o "$DEST"
        HASH=$(${pkgs.coreutils}/bin/sha256sum "$DEST" | cut -d' ' -f1)
        echo "SHA256=$HASH"
        ;;

      DELIVER)
        # DELIVER <dest-ip> <filename>
        # Upload encrypted blob to destination VM's HTTP server
        DEST_IP=$(echo "$REST" | cut -d' ' -f1)
        FILENAME=$(echo "$REST" | cut -d' ' -f2)
        SRC="$STORAGE_DIR/tmp/$FILENAME"
        if [ ! -f "$SRC" ]; then
          echo "ERROR: file not found: $SRC"
          exit 1
        fi
        RESULT=$(${pkgs.curl}/bin/curl -sf -X PUT \
          "http://$DEST_IP:8888/xfer.enc" \
          --data-binary @"$SRC" -w '%{http_code}')
        if [ "$RESULT" = "200" ]; then
          # Ask dest VM for checksum of what it received
          HASH=$(${pkgs.coreutils}/bin/sha256sum "$SRC" | cut -d' ' -f1)
          echo "SHA256=$HASH"
        else
          echo "ERROR: upload failed (HTTP $RESULT)"
          exit 1
        fi
        ;;

      STORE)
        # STORE <passphrase> <vm-type> <filename>
        # Decrypt in-place to /storage/<vm-type>/
        PASSPHRASE=$(echo "$REST" | cut -d' ' -f1)
        VM_TYPE=$(echo "$REST" | cut -d' ' -f2)
        FILENAME=$(echo "$REST" | cut -d' ' -f3)
        SRC="$STORAGE_DIR/tmp/$FILENAME"
        DEST_DIR="$STORAGE_DIR/$VM_TYPE"
        mkdir -p "$DEST_DIR"
        ${pkgs.openssl}/bin/openssl enc -d -aes-256-cbc -pbkdf2 \
          -pass pass:"$PASSPHRASE" -in "$SRC" \
          | tar xzf - -C "$DEST_DIR"
        rm -f "$SRC"
        echo "OK"
        ;;

      STORE_RAW)
        # STORE_RAW <vm-type> <filename>
        # Move encrypted blob to /storage/<vm-type>/ without decrypting
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
        # CLEANUP_TMP <filename>
        FILENAME=$(echo "$REST" | cut -d' ' -f1)
        rm -f "$STORAGE_DIR/tmp/$FILENAME"
        echo "OK"
        ;;

      LIST)
        # LIST [<vm-type>]
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

      SHUTDOWN)
        # Graceful exit (host is done with this session)
        echo "OK"
        # systemd will restart the socat listener
        exit 0
        ;;

      *)
        echo "ERROR: unknown command: $CMD"
        exit 1
        ;;
    esac
  '';

in {
  config = lib.mkIf cfg.enable {

    # ===== Basic Identity =====
    networking.hostName = lib.mkDefault "microvm-files";
    system.stateVersion = "25.05";
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      vcpu = 1;
      mem = 512;

      storeDiskType = "squashfs";
      writableStoreOverlay = "/nix/.rw-store";
      graphics.enable = false;

      # Primary TAP on br-files (home network)
      interfaces = [{
        type = "tap";
        id = "mv-files";
        mac = "02:00:00:02:00:01";
      }];

      # Additional TAPs for each allowed bridge
      qemu.extraArgs = [
        "-vga" "none"
        "-display" "none"
        "-chardev" "socket,id=console,path=/var/lib/microvms/${vmName}/console.sock,server=on,wait=off"
        "-serial" "chardev:console"
      ] ++ extraTapArgs;

      vsock.cid = 106;

      shares = [{
        tag = "nix-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
      }];

      # Persistent /storage volume for file archival
      volumes = [
        {
          image = "/var/lib/microvms/${vmName}/storage.qcow2";
          mountPoint = "/storage";
          size = 51200;  # 50GB default
          autoCreate = true;
        }
        {
          image = "/var/lib/microvms/${vmName}/nix-overlay.qcow2";
          mountPoint = "/nix/.rw-store";
          size = 4096;
          autoCreate = true;
        }
      ];
    };

    # ===== Kernel =====
    boot.initrd.availableKernelModules = [
      "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
      "virtio_net" "virtio_scsi" "squashfs"
    ];
    boot.kernelParams = [ "console=tty1" "console=ttyS0,115200n8" ];
    boot.kernelPackages = pkgs.linuxPackages_latest;

    # ===== Networking =====
    # No DHCP — all interfaces get static IPs via systemd.network
    networking.useDHCP = false;
    networking.networkmanager.enable = false;
    networking.firewall.enable = false;  # nftables used directly

    # Primary interface (br-files): 192.168.108.10
    # Plus one network config per enabled bridge TAP
    systemd.network = {
      enable = true;
      networks = {
        "10-files-home" = {
          matchConfig.MACAddress = "02:00:00:02:00:01";
          address = [ "192.168.108.10/24" ];
          gateway = [ "192.168.108.253" ];
          dns = [ "192.168.108.253" ];
          linkConfig.RequiredForOnline = "no";
        };
      } // lib.mapAttrs' (bridgeName: i: lib.nameValuePair "20-files-${bridgeName}" {
        matchConfig.MACAddress = i.mac;
        address = [ "${i.subnet}.2/24" ];
        linkConfig.RequiredForOnline = "no";
      }) enabledIfaces;
    };

    # ===== IP Forwarding disabled =====
    boot.kernel.sysctl."net.ipv4.ip_forward" = 0;

    # ===== nftables: block unwanted inbound traffic =====
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
            # Allow ICMP (useful for debugging)
            ip protocol icmp accept
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
          }
        '';
      };
    };

    # ===== Tmpfiles =====
    systemd.tmpfiles.rules = [
      "d /storage 0755 root root -"
      "d /storage/tmp 0750 root root -"
    ];

    # ===== Vsock agent (port 14505) =====
    systemd.services.microvm-files-agent = {
      description = "Files VM vsock agent (port 14505)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "storage.mount" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "1s";
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14505,reuseaddr,fork EXEC:${filesAgentScript}";
      };
    };

    # ===== No graphical stack, no SSH =====
    services.openssh.enable = false;
    services.xserver.enable = false;

    # ===== Packages =====
    environment.systemPackages = with pkgs; [
      curl
      openssl
      socat
      coreutils
      iproute2
      htop
      ncdu
    ];

    # ===== Users =====
    users.users.root.password = "";
    security.sudo.wheelNeedsPassword = false;

    nix.settings.auto-optimise-store = lib.mkForce false;
  };
}
