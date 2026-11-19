# A microVM whose store is a tier store (hydrix.microvm.storeSource other than /nix/store).
# Imported by the profile, infra and router bases; inert for a VM on the host store.
#
# microvm.nix only treats a share with source "/nix/store" as the store, so the overlay
# lower, its boot ordering and storeOnDisk are set here. A VM without a writable store layer
# (infra VMs) gets one with its upper on the tmpfs root: microvm.nix mounts a store share
# with any other source only through an overlay. init= and the closure registration
# (regInfo=, loaded into the guest's Nix database at boot) lose their string context and the
# runner gets no system symlink: the host builds the runner without realising the system.
# The tier builder builds system.build.tierSystem, which holds both, into the tier store.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.microvm;
  # Profile VMs can turn the shared store off (storeOnDisk instead); infra VMs always share.
  tierStore = (cfg.shareStore or true) && cfg.storeSource != "/nix/store";
  # Same derivation as microvm.nix's regInfo (store-disk.nix), built in the tier store.
  tierRegInfo = pkgs.closureInfo {rootPaths = [config.system.build.toplevel];};
in {
  config = lib.mkIf tierStore {
    microvm.storeOnDisk = lib.mkForce false;
    microvm.systemSymlink = false;
    microvm.writableStoreOverlay = lib.mkDefault "/nix/.rw-store";
    # microvm.nix enables nix-daemon with a writable store layer; a VM without Nix has none.
    systemd.services.nix-daemon.enable = lib.mkIf (!config.nix.enable) false;
    systemd.sockets.nix-daemon.enable = lib.mkIf (!config.nix.enable) false;
    microvm.kernelParams = lib.mkForce (config.boot.kernelParams
      ++ ["init=${builtins.unsafeDiscardStringContext config.system.build.toplevel}/init"]
      ++ lib.optional (config.microvm.registerClosure && config.nix.enable)
      "regInfo=${builtins.unsafeDiscardStringContext tierRegInfo}/registration");
    system.build.tierSystem = pkgs.linkFarm "hydrix-tier-system" [
      {
        name = "system";
        path = config.system.build.toplevel;
      }
      {
        name = "registration";
        path = tierRegInfo;
      }
    ];
    # What the host builds for a tier VM, before the tier build: the runner, and the kernel
    # outputs the tier system links (the runner holds only bzImage). The kernel is compiled
    # on the host, and shard exports it to the host cache for the tier builder.
    system.build.tierHost = pkgs.linkFarm "hydrix-tier-host" [
      {
        name = "runner";
        path = config.microvm.declaredRunner;
      }
      {
        name = "kernel";
        path = config.boot.kernelPackages.kernel;
      }
      {
        name = "kernel-modules";
        path = config.boot.kernelPackages.kernel.modules;
      }
    ];
    fileSystems = {
      "/nix/.ro-store".neededForBoot = true;
      "/nix/store".overlay.lowerdir = lib.mkForce ["/nix/.ro-store"];
    };
  };
}
