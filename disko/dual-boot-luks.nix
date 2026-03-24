# Disko configuration: Dual-boot with LUKS encryption
# Installs alongside existing OS, reuses existing EFI partition
#
# PREREQUISITES:
#   1. Shrink existing partition to create free space
#   2. Leave the free space unallocated
#   3. Note down your existing EFI partition (usually /dev/nvme0n1p1 or /dev/sda1)
#
# Usage in install script:
#   disko --mode disko \
#     --arg device '"/dev/nvme0n1"' \
#     --arg efiDevice '"/dev/nvme0n1p1"' \
#     --arg startSector '"END_OF_LAST_PARTITION"' \
#     ./disko/dual-boot-luks.nix
#
# Parameters:
#   device      - Target disk (e.g., "/dev/nvme0n1")
#   efiDevice   - Existing EFI partition to mount (e.g., "/dev/nvme0n1p1")
#   luksName    - LUKS device name (default: "cryptroot")
#   swapSize    - Swap file size (default: "16G")
#
# Note: This template creates a new partition in free space.
# The install script must handle partition creation separately.

{ device, efiDevice, luksName ? "cryptroot", swapSize ? "16G", ... }:
{
  disko.devices = {
    # Mount existing EFI partition (don't format!)
    nodev = {
      "/boot" = {
        fsType = "vfat";
        device = efiDevice;
        mountOptions = [ "defaults" "umask=0077" ];
      };
    };

    disk.main = {
      type = "disk";
      inherit device;
      content = {
        type = "gpt";
        partitions = {
          # LUKS encrypted partition in free space
          # Note: disko will use remaining space after existing partitions
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = luksName;
              settings.allowDiscards = true;
              passwordFile = "/tmp/luks-password";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" "-L" "nixos" ];
                subvolumes = {
                  # Root filesystem
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];
                  };
                  # User data (snapshot-able)
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];
                  };
                  # Nix store
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];
                  };
                  # Persistent state
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
                  };
                  # Logs
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
                  };
                  # VM instances
                  "@vms" = {
                    mountpoint = "/var/lib/libvirt/images";
                    mountOptions = [ "noatime" "space_cache=v2" "discard=async" ];
                  };
                  # Base images for VM cloning
                  "@vm-bases" = {
                    mountpoint = "/var/lib/libvirt/bases";
                    mountOptions = [ "noatime" "space_cache=v2" "discard=async" ];
                  };
                  # BTRFS snapshots
                  "@snapshots" = {
                    mountpoint = "/.snapshots";
                    mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
                  };
                  # Swap subvolume
                  "@swap" = {
                    mountpoint = "/.swap";
                    swap.swapfile.size = swapSize;
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
