# Disko Implementation - Generate disk config from hydrix.disko.* options
#
# This module generates disko.devices configuration based on the selected layout.
# Users set simple options, module generates the full BTRFS subvolume structure.
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  diskoCfg = cfg.disko;

  # Common BTRFS mount options
  btrfsOpts = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];

  # Common subvolumes for all layouts
  commonSubvolumes = {
    "@" = {
      mountpoint = "/";
      mountOptions = btrfsOpts;
    };
    "@home" = {
      mountpoint = "/home";
      mountOptions = btrfsOpts;
    };
    "@nix" = {
      mountpoint = "/nix";
      mountOptions = btrfsOpts;
    };
    "@persist" = {
      mountpoint = "/persist";
      mountOptions = btrfsOpts;
    };
    "@log" = {
      mountpoint = "/var/log";
      mountOptions = btrfsOpts;
    };
    "@vms" = {
      mountpoint = "/var/lib/libvirt/images";
      mountOptions = [ "noatime" "space_cache=v2" "discard=async" ];
    };
    "@vm-bases" = {
      mountpoint = "/var/lib/libvirt/bases";
      mountOptions = [ "noatime" "space_cache=v2" "discard=async" ];
    };
    "@snapshots" = {
      mountpoint = "/.snapshots";
      mountOptions = btrfsOpts;
    };
    "@swap" = {
      mountpoint = "/.swap";
      swap.swapfile.size = diskoCfg.swapSize;
    };
  };

in {
  config = lib.mkIf (cfg.vmType == "host" && diskoCfg.enable) {
    disko.devices = lib.mkMerge [
      # =========================================================================
      # FULL DISK PLAIN (no encryption)
      # =========================================================================
      (lib.mkIf (diskoCfg.layout == "full-disk-plain") {
        disk.main = {
          type = "disk";
          device = diskoCfg.device;
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "1G";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "defaults" "umask=0077" ];
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" "-L" "nixos" ];
                  subvolumes = commonSubvolumes;
                };
              };
            };
          };
        };
      })

      # =========================================================================
      # FULL DISK LUKS (encrypted)
      # =========================================================================
      (lib.mkIf (diskoCfg.layout == "full-disk-luks") {
        disk.main = {
          type = "disk";
          device = diskoCfg.device;
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "1G";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "defaults" "umask=0077" ];
                };
              };
              luks = {
                size = "100%";
                content = {
                  type = "luks";
                  name = "cryptroot";
                  settings = {
                    allowDiscards = true;
                    bypassWorkqueues = true;
                  };
                  content = {
                    type = "btrfs";
                    extraArgs = [ "-f" "-L" "nixos" ];
                    subvolumes = commonSubvolumes;
                  };
                };
              };
            };
          };
        };
      })

      # =========================================================================
      # DUAL BOOT LUKS (preserve existing EFI)
      # The installer pre-creates the NixOS partition; disko formats it directly
      # without touching the partition table (no sgdisk --clear).
      # =========================================================================
      (lib.mkIf (diskoCfg.layout == "dual-boot-luks") {
        disk.nixos = {
          type = "disk";
          device = diskoCfg.nixosPartition;
          content = {
            type = "luks";
            name = "cryptroot";
            settings = {
              allowDiscards = true;
              bypassWorkqueues = true;
            };
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "nixos" ];
              subvolumes = commonSubvolumes;
            };
          };
        };
      })

      # =========================================================================
      # DUAL BOOT PLAIN (preserve existing EFI, no encryption)
      # =========================================================================
      (lib.mkIf (diskoCfg.layout == "dual-boot-plain") {
        disk.nixos = {
          type = "disk";
          device = diskoCfg.nixosPartition;
          content = {
            type = "btrfs";
            extraArgs = [ "-f" "-L" "nixos" ];
            subvolumes = commonSubvolumes;
          };
        };
      })
    ];

    # For dual-boot, /boot is the reused EFI partition; declare it explicitly
    # since disko doesn't manage it (we avoid nodev to prevent automount conflicts).
    fileSystems."/boot" = lib.mkIf (lib.hasPrefix "dual-boot" diskoCfg.layout) {
      device = diskoCfg.efiPartition;
      fsType = "vfat";
      options = [ "defaults" "umask=0077" ];
    };

    # Boot loader config
    boot.loader = {
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
        useOSProber = lib.hasPrefix "dual-boot" diskoCfg.layout;
        # Chain-boot entries use insmod cryptodisk + cryptomount -u <UUID>
        # directly, so no global LUKS scan at GRUB startup is needed.
        # (enableCryptodisk = true would prompt for all LUKS devices before
        # the menu is shown, and is incorrect here since Hydrix kernel/initrd
        # are on the unencrypted EFI partition.)
        extraEntries = lib.mkIf (diskoCfg.grubExtraEntries != "") diskoCfg.grubExtraEntries;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };
  };
}
