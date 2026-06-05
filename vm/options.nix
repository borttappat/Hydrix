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
      description = "Seconds before a cached metric file is considered stale by polybar modules.";
      example = 10;
    };
  };
}
