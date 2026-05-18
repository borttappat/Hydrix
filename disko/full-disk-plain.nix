# Disko configuration: Full disk without encryption
# Use this only if you don't need disk encryption
#
# Usage in install script:
#   disko --mode disko --arg device '"/dev/nvme0n1"' ./disko/full-disk-plain.nix
#
# Parameters:
#   device    - Target disk (e.g., "/dev/nvme0n1", "/dev/sda")
#   swapSize  - Swap file size (default: "16G")

{ device, swapSize ? "16G", ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      inherit device;
      content = {
        type = "gpt";
        partitions = {
          # EFI System Partition
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
          # BTRFS root partition (no encryption)
          root = {
            size = "100%";
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
                # Persistent state (for impermanence setups)
                "@persist" = {
                  mountpoint = "/persist";
                  mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
                };
                # Logs (separate for rollback safety)
                "@log" = {
                  mountpoint = "/var/log";
                  mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
                };
                # VM instances - CoW enabled for reflink cloning
                "@vms" = {
                  mountpoint = "/var/lib/libvirt/images";
                  mountOptions = [ "noatime" "space_cache=v2" "discard=async" ];
                };
                # Base images for VM cloning
                "@vm-bases" = {
                  mountpoint = "/var/lib/libvirt/bases";
                  mountOptions = [ "noatime" "space_cache=v2" "discard=async" ];
                };
                # MicroVM instances - nodatacow prevents fragmentation of qcow2/luks volumes
                "@microvms" = {
                  mountpoint = "/var/lib/microvms";
                  mountOptions = [ "nodatacow" "noatime" "space_cache=v2" "discard=async" ];
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
}
