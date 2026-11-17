# The VM's writable store layer (nix-overlay.qcow2 at /nix/.rw-store) as a cache, or wiped at
# each boot (hydrix.microvm.persistence.storeCache).
#
# /nix/store in a profile VM is an overlay: the read-only shared store (/nix/.ro-store, the
# host store or the VM's tier view) under the writable layer. Nix's database
# (/nix/var/nix) is on the tmpfs root by default and refilled at each boot from the system's
# registration only (regInfo, `nix-store --load-db` in boot.postBootCommands), so whatever
# the VM fetched or built is unregistered after a reboot: the files stay on the volume and
# Nix fetches or builds them again.
#
# "persistent" moves /nix/var/nix onto the volume, so the database and the files it records
# live and die together (until `shard -p` deletes the volume). Each boot, before the overlay
# is mounted, entries in the writable layer for paths the shared store has are removed: the
# shared copy is authoritative. That clears the whiteouts a garbage collection writes for
# shared paths (which would hide them once a later view brings them back) and anything that
# changed files of a shared path. The initrd comes from the host, so guest root cannot skip
# this. After boot, `nix-store --verify` drops database entries whose path vanished.
#
# "ephemeral" empties the writable layer at each boot instead.
{
  config,
  lib,
  ...
}: let
  cfg = config.hydrix.microvm;
  persistent = cfg.persistence.storeCache == "persistent";
  rw = "/sysroot${config.microvm.writableStoreOverlay}";
  ro = "/sysroot/nix/.ro-store";
in {
  config = lib.mkIf (cfg.shareStore && config.microvm.writableStoreOverlay != null) (lib.mkMerge [
    {
      boot.initrd.systemd.services.hydrix-store-overlay-prep = {
        description = "Prepare the writable store layer (${cfg.persistence.storeCache})";
        requiredBy = ["sysroot-nix-store.mount"];
        # rw-sysroot-nix-store creates the overlay's upper and work directories (NixOS
        # overlayfs.nix), so this runs first.
        before = ["sysroot-nix-store.mount" "rw-sysroot-nix-store.service"];
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = "${rw} ${ro}";
        };
        # The initrd can start this again after the overlay is up (the mount's Requires= pulls
        # it in when the units are reloaded): RemainAfterExit keeps it done, and the guard
        # below never touches the writable layer under a mounted overlay.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          ''
            while read -r _ mnt _; do
              if [ "$mnt" = /sysroot/nix/store ]; then
                echo "Store overlay already mounted: writable layer left as it is"
                exit 0
              fi
            done < /proc/self/mounts
          ''
          + (
            if persistent
            then ''
              mkdir -p -m 0755 ${rw}/var/nix /sysroot/nix/var/nix
              if [ -d ${rw}/store ]; then
                for e in ${rw}/store/* ${rw}/store/.[!.]*; do
                  [ -e "$e" ] || [ -L "$e" ] || continue
                  n=''${e##*/}
                  if [ -c "$e" ] || [ -e "${ro}/$n" ] || [ -L "${ro}/$n" ]; then
                    rm -rf -- "$e"
                  fi
                done
              fi
              mount --bind ${rw}/var/nix /sysroot/nix/var/nix
            ''
            else ''
              rm -rf -- ${rw}/store ${rw}/work ${rw}/var
              mkdir -p -m 0755 ${rw}/store ${rw}/work
            ''
          );
      };
    }

    (lib.mkIf persistent {
      # Mounted in the initrd above; declared here so systemd orders it after its source at
      # shutdown (a bind mount depends on the mount holding its source).
      fileSystems."/nix/var/nix" = {
        device = "${config.microvm.writableStoreOverlay}/var/nix";
        fsType = "none";
        options = ["bind"];
      };

      systemd.services.hydrix-store-cache-verify = {
        description = "Drop store database entries whose path vanished";
        wantedBy = ["nix-daemon.socket"];
        before = ["nix-daemon.socket" "nix-daemon.service" "shutdown.target"];
        after = ["local-fs.target"];
        conflicts = ["shutdown.target"];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # A path the shared store dropped (an exact view sync) while a cached path still
        # needs it stays listed; nix-store reports it here.
        script = ''
          ${config.nix.package}/bin/nix-store --verify || true
        '';
      };
    })
  ]);
}
