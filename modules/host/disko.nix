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
      # =========================================================================
      (lib.mkIf (diskoCfg.layout == "dual-boot-luks") {
        disk.main = {
          type = "disk";
          device = diskoCfg.device;
          content = {
            type = "gpt";
            partitions = {
              # Don't create ESP - use existing one
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
      # DUAL BOOT PLAIN (preserve existing EFI, no encryption)
      # =========================================================================
      (lib.mkIf (diskoCfg.layout == "dual-boot-plain") {
        disk.main = {
          type = "disk";
          device = diskoCfg.device;
          content = {
            type = "gpt";
            partitions = {
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
    ];

    # Boot loader config
    boot.loader = {
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
        useOSProber = lib.hasPrefix "dual-boot" diskoCfg.layout;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };
  };
}
