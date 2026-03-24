# Shared /nix/store via virtiofs from host
# This allows VMs to use packages already built on the host without re-downloading
#
# Requirements:
#   - Host must have virtiofsd available (NixOS has it)
#   - VM must be deployed with virtiofs filesystem in libvirt XML
#   - Host's /nix/store is mounted read-only at /nix/.host-store
#
# How it works:
#   1. Host shares /nix/store via virtiofs (configured in libvirt XML)
#   2. VM mounts it read-only at /nix/.host-store
#   3. Nix is configured to use this as a local binary cache
#   4. When VM needs a package, it checks host store first
#   5. If found, nix copies from local mount (instant); else downloads normally
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.vm.sharedStore;
in
{
  options.hydrix.vm.sharedStore = {
    enable = lib.mkEnableOption "virtiofs shared /nix/store from host";

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/nix/.host-store";
      description = "Where to mount the host's /nix/store";
    };

    virtiofsMountTag = lib.mkOption {
      type = lib.types.str;
      default = "nix-store";
      description = "virtiofs mount tag (must match libvirt XML target dir)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Add virtiofs kernel module
    boot.initrd.availableKernelModules = [ "virtiofs" ];

    # Mount host's /nix/store read-only
    fileSystems.${cfg.mountPoint} = {
      device = cfg.virtiofsMountTag;
      fsType = "virtiofs";
      options = [
        "ro"
        "nofail"  # Don't fail boot if host store isn't available
      ];
    };

    # Create a script that serves as a local binary cache from the host store
    # This is more reliable than overlay-store which has experimental issues
    systemd.services.host-store-cache = {
      description = "Local binary cache from host /nix/store";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      # Only start if the host store is actually mounted
      unitConfig.ConditionPathIsMountPoint = cfg.mountPoint;

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.nix-serve}/bin/nix-serve --port 5557 --store ${cfg.mountPoint}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # Configure nix to use the local cache as a substituter
    nix.settings = {
      # Local cache has highest priority (checked first)
      substituters = lib.mkBefore [ "http://localhost:5557" ];

      # Trust our own local cache
      trusted-substituters = [ "http://localhost:5557" ];

      # Accept unsigned paths from local cache (it's our own host store)
      require-sigs = lib.mkDefault false;
    };

    # Add nix-serve to system packages for debugging
    environment.systemPackages = [ pkgs.nix-serve ];
  };
}
