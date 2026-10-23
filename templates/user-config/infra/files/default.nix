# Filesharing infra VM - relay for encrypted inter-VM file transfers
#
# Base (headless, virtiofs store) provided by microvm-infra-base via mkInfraVm.
# This module adds: vsock agent, multi-bridge networking.
# A transfer streams ciphertext from the source VM's port 8888 straight to the
# destination's: this VM holds no key and stores nothing. It has no volumes
# (tmpfs root only), so every start is clean; `shard files transfer` starts it
# and stops it again when the transfer ends.
#
# Profile VMs are auto-discovered from profiles/. Privacy VMs (lurking) are
# excluded. User infra VMs that need transfer access are listed in infraParticipants.
#
# vsock 14505: host -> files VM (RELAY, ABORT, PING)
{
  config,
  lib,
  pkgs,
  ...
}: let
  meta = import ./meta.nix;

  # Auto-discover profile VMs from profiles/ directory
  profilesDir = ../../profiles;
  profileNames = builtins.attrNames (builtins.readDir profilesDir);
  # Profiles that opt out with `filesAccess = false;` in their meta.nix get no
  # files VM interface (same filter as tapBridges in ./meta.nix, the host side)
  validProfiles =
    builtins.filter (
      n:
        builtins.pathExists (profilesDir + "/${n}/meta.nix")
        && (import (profilesDir + "/${n}/meta.nix")).filesAccess or true
    )
    profileNames;

  # TAP abbreviation: first 4 chars of profile name
  abbrev = n: builtins.substring 0 4 n;

  # Per-bridge TAP/MAC/IP mappings for profile VMs
  # MAC: 02:00:00:02:<cidN>:01, cidN = zero-padded decimal of (vsockCid - 100)
  # Valid for profile CIDs 102-199
  profileIfaceMap = builtins.listToAttrs (map (
      name: let
        pmeta = import (profilesDir + "/${name}/meta.nix");
        cidN = lib.fixedWidthString 2 "0" (toString (pmeta.vsockCid - 100));
      in
        lib.nameValuePair name {
          tap = "mv-files-${abbrev name}";
          mac = "02:00:00:02:${cidN}:01";
          subnet = pmeta.subnet;
        }
    )
    validProfiles);

  # Infra VMs that participate in file transfer (explicit - not auto-discovered)
  # MAC 5th octet: hex(vsockCid - 100), prefixed 0 to stay in valid range
  usbSandboxMeta = import ../usb-sandbox/meta.nix;
  hostsyncMeta = import ../hostsync/meta.nix;
  infraIfaceMap = {
    # usb-sandbox: files VM gets a TAP on br-usb-sandbox so both VMs share that bridge
    "usb-sandbox" = {
      tap = "mv-files-usb";
      mac = "02:00:00:02:6d:02"; # Unique MAC on br-usb-sandbox (usb-sandbox itself uses :6d:01)
      subnet = usbSandboxMeta.subnet;
    };
    # hostsync: files VM gets a TAP on br-hostsync to HTTP-deliver blobs to 192.168.214.214
    "hostsync" = {
      tap = "mv-files-hsy";
      mac = "02:00:00:02:d6:02"; # CID 214 = 0xd6; :02 = files VM side on this bridge
      subnet = hostsyncMeta.subnet;
    };
  };

  # One interface per task slot bridge, same MAC scheme as profile VMs
  taskIfaceMap = builtins.listToAttrs (map (t:
    lib.nameValuePair t.name {
      tap = "mv-files-${t.name}";
      mac = "02:00:00:02:${toString (t.vsockCid - 100)}:01";
      inherit (t) subnet;
    })
  (import ../../tasks/slots.nix));

  ifaceMap = profileIfaceMap // taskIfaceMap // infraIfaceMap;

  extraInterfaces =
    lib.mapAttrsToList (_: i: {
      type = "tap";
      id = i.tap;
      mac = i.mac;
    })
    ifaceMap;

  xfer = config.hydrix.microvm.xfer;

  # One command per vsock connection. Fields go to the helper as --opt=value
  # and the helper validates every value (see hydrix.microvm.xfer).
  filesAgentScript = pkgs.writeShellScript "microvm-files-agent" ''
    set -euo pipefail
    X() { ${xfer} --state /run/microvm-files-agent "$@"; }
    read -r CMD A1 A2 _ || exit 0

    case "$CMD" in
      RELAY)
        # RELAY <src-ip> <dst-ip>: pipe the ciphertext from the source's port
        # 8888 to the destination's. Nothing is stored here and no key is held.
        X relay --src="$A1:8888" --dst="$A2:8888"
        ;;

      ABORT)
        X abort --root /run/microvm-files-agent
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
  config = {
    microvm.vsock.cid = meta.vsockCid;
    microvm.interfaces =
      [
        {
          type = "tap";
          id = meta.tapId;
          mac = meta.tapMac;
        }
      ]
      ++ extraInterfaces;

    microvm.mem = 512;

    # Nothing survives a stop: no volumes at all, the root is tmpfs.
    microvm.volumes = lib.mkForce [];

    boot.kernelPackages = pkgs.linuxPackages_latest;
    boot.kernelModules = ["vmw_vsock_virtio_transport"];

    networking.useDHCP = lib.mkForce false;

    systemd.network = {
      enable = true;
      networks =
        {
          "10-files-home" = {
            matchConfig.MACAddress = meta.tapMac;
            address = ["${meta.subnet}.10/24"];
            gateway = ["${meta.subnet}.253"];
            dns = ["${meta.subnet}.253"];
            linkConfig.RequiredForOnline = "no";
          };
        }
        // lib.mapAttrs' (name: i:
          lib.nameValuePair "20-files-${name}" {
            matchConfig.MACAddress = i.mac;
            address = ["${i.subnet}.2/24"];
            linkConfig.RequiredForOnline = "no";
          })
        ifaceMap;
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
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
          }
        '';
      };
    };

    systemd.services.microvm-files-agent = {
      description = "Files VM vsock agent (port 14505)";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "1s";
        RuntimeDirectory = "microvm-files-agent";
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14505,reuseaddr,fork EXEC:${filesAgentScript}";
      };
    };

    # Console debugging only; the agent uses store paths.
    environment.systemPackages = with pkgs; [
      iproute2
      htop
    ];

    # Dedicated user for console autologin - matches builder/gitsync pattern.
    # Root autologin on ttyS0 is blocked by login(1)'s securetty check.
    users.users.files = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      password = "files";
      home = "/home/files";
    };
    services.getty.autologinUser = "files";
  };
}
