# Hydrix VM Options
#
# VM type, Tor hardening, VM metrics.
# All VM profiles import this alongside shared/options.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;
in {
  imports = [
    (lib.mkRemovedOptionModule ["hydrix" "router" "polling" "interval"]
      "The router no longer samples on a timer: WiFi state follows nl80211/NetworkManager events, throughput and WireGuard are read per request.")
  ];

  options.hydrix = {
    # virtiofsd arguments for every share a VM can write to. Keeps the host
    # root virtiofsd from creating device nodes or file capabilities for the
    # guest; setuid bits are neutralised host-side by nosuid mounts.
    # Extract a .tar.gz that another VM authored. Every member must be a
    # regular file or directory with a relative path and no "..", and it is
    # extracted without owners or permissions. Prints "ERROR: ..." and exits
    # non-zero otherwise. Usage: <script> ARCHIVE DEST
    microvm.safeExtract = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.writeShellScript "hydrix-safe-extract" ''
        set -u
        export PATH=${lib.makeBinPath [pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.gnugrep]}
        archive=$1 dest=$2
        types=$(tar -tvzf "$archive" 2>/dev/null | cut -c1) || { echo "ERROR: unreadable archive"; exit 1; }
        names=$(tar -tzf "$archive" 2>/dev/null) || { echo "ERROR: unreadable archive"; exit 1; }
        if grep -qv '^[-d]$' <<< "$types"; then
          echo "ERROR: archive contains links or special files"
          exit 1
        fi
        while IFS= read -r n; do
          case "$n" in /*) echo "ERROR: absolute path in archive"; exit 1 ;; esac
          case "/$n/" in */../*) echo "ERROR: '..' in archive path"; exit 1 ;; esac
        done <<< "$names"
        tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$dest" || { echo "ERROR: extraction failed"; exit 1; }
      '';
      description = "Checked extraction for archives that come from another VM.";
    };

    # The desktop user on the host. Writable shares that hold the user's own
    # files (vault, hostsync inbox, gitsync repos) squash every guest uid/gid
    # to it, so nothing a guest creates there is root-owned on the host. The
    # VM's service user is pinned to the same uid so it keeps owning its files.
    microvm.hostOwner = {
      uid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "Host uid that owns the user-owned writable shares.";
      };
      gid = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "Host gid that owns the user-owned writable shares.";
      };
    };

    # virtiofsd arguments for shares holding the user's own files: the
    # writableShareArgs plus uid/gid squash to hostOwner. Such a share must set
    # posixAcl = false (virtiofsd refuses translation together with ACLs).
    microvm.ownedShareArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        cfg.microvm.writableShareArgs
        ++ [
          "--translate-uid"
          "squash-guest:0:${toString cfg.microvm.hostOwner.uid}:4294967295"
          "--translate-gid"
          "squash-guest:0:${toString cfg.microvm.hostOwner.gid}:4294967295"
        ];
      description = "virtiofsd extraArgs for writable shares that hold the host user's own files.";
    };

    microvm.writableShareArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["--modcaps=-mknod:-setfcap"];
      description = "virtiofsd extraArgs for writable shares (set on each share's extraArgs).";
    };

    # =========================================================================
    # VM IDENTITY
    # Used by both microVMs (set by mkMicrovm/mkInfraVm) and libvirt VMs.
    # =========================================================================

    vm = {
      storeName = lib.mkOption {
        type = lib.types.str;
        default = "unknown-vm";
        description = "NixOS configuration key for this VM (e.g. microvm-lurking). Used for host-side paths and service names. Set by the flake - do not override in user configs.";
      };
      hostname = lib.mkOption {
        type = lib.types.str;
        default = "unknown-vm";
        description = "Hostname visible inside the VM. Defaults to storeName for microVMs. Override freely in profiles/<name>/default.nix.";
      };
    };

    # =========================================================================
    # VM TYPE
    # =========================================================================

    vmType = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "System type: host or VM profile type (e.g. browsing, pentest, dev, or any user-defined profile name)";
    };

    # =========================================================================
    # TOR HARDENING
    # =========================================================================

    tor = {
      hardening = {
        enable = lib.mkEnableOption "Tor hardening with traffic shaping";

        level = lib.mkOption {
          type = lib.types.enum ["minimal" "moderate" "paranoid"];
          default = "minimal";
          description = "Privacy level vs usability trade-off";
        };

        bridgeType = lib.mkOption {
          type = lib.types.enum ["none" "obfs4" "meek-azure" "snowflake"];
          default = "none";
          description = "Pluggable transport for bypassing Tor blocks";
        };

        customBridges = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Custom bridge lines (overrides bridgeType if set)";
        };
      };
    };
  };

  options.hydrix.microvm.defaultProfiles = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        vsockCid = lib.mkOption {
          type = lib.types.int;
          description = "Default vsock CID for this profile.";
        };
        bridge = lib.mkOption {
          type = lib.types.str;
          description = "Default host bridge this profile's VM attaches to.";
        };
        tapId = lib.mkOption {
          type = lib.types.str;
          description = "Default TAP interface name on the VM side.";
        };
        routerTap = lib.mkOption {
          type = lib.types.str;
          description = "Default TAP interface name on the router side for this profile's link.";
        };
        subnet = lib.mkOption {
          type = lib.types.str;
          description = "Default /24 subnet prefix (without the last octet).";
        };
        workspace = lib.mkOption {
          type = lib.types.int;
          description = "Default Hyprland workspace number, if a desktop is in use.";
        };
        label = lib.mkOption {
          type = lib.types.str;
          description = "Default display label for this profile.";
        };
      };
    });
    default = {
      browsing = {
        vsockCid = 103;
        bridge = "br-browse";
        tapId = "mv-browse";
        routerTap = "mv-router-brow";
        subnet = "192.168.103";
        workspace = 3;
        label = "BROWSING";
      };
      comms = {
        vsockCid = 104;
        bridge = "br-comms";
        tapId = "mv-comms";
        routerTap = "mv-router-comm";
        subnet = "192.168.104";
        workspace = 4;
        label = "COMMS";
      };
      lurking = {
        vsockCid = 106;
        bridge = "br-lurking";
        tapId = "mv-lurking";
        routerTap = "mv-router-lurk";
        subnet = "192.168.106";
        workspace = 6;
        label = "LURKING";
      };
    };
    description = ''
      Default CID/bridge/tapId/subnet/workspace metadata for Hydrix's built-in profile
      VMs, so `hydrix.lib.mkMicroVM { profile = "browsing"; ... }` (etc for comms,
      lurking) is buildable and reachable through the router with zero hydrix-config
      customization -- no profiles/<name>/meta.nix required. hydrix-config's own
      profiles/<name>/default.nix (plain assignment, not mkDefault) fully overrides any
      entry here, so this is purely a fallback for consumers with nothing to override
      with; it changes nothing for an existing hydrix-config setup.

      `dev` and `pentest` are deliberately not included: pentest is
      individually-tweaked per engagement and out of scope for a "regular" user (run
      setup-hydrix instead); dev is not shipped as a zero-config default.
    '';
  };

  options.hydrix.vmMetrics = {
    vmCollectInterval = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Seconds between metric pre-collection cycles inside each VM.";
      example = 2;
    };
    hostPollInterval = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Seconds between host daemon polls of the current workspace VM.";
      example = 2;
    };
    staleThreshold = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = "Seconds before a cached metric file is considered stale by waybar modules.";
      example = 10;
    };
  };

  options.hydrix.router.polling = {
    enableNetStats = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Serve network throughput (NET, and the net part of ALL) from router-stats-server, measured per request.";
    };
    enableWgStatus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Serve WireGuard peer status (WG, and the wg part of ALL) from router-stats-server, read per request, plus endpoint geo-lookup.";
    };
  };
}
