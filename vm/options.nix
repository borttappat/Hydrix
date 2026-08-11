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
  options.hydrix = {
    # =========================================================================
    # VM IDENTITY
    # Used by both microVMs (set by mkMicrovm/mkInfraVm) and libvirt VMs.
    # =========================================================================

    vm = {
      storeName = lib.mkOption {
        type = lib.types.str;
        default = "unknown-vm";
        description = "NixOS configuration key for this VM (e.g. microvm-lurking). Used for host-side paths and service names. Set by the flake — do not override in user configs.";
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
}
