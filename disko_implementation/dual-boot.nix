# installer/disko-templates/dual-boot.nix
# Dual-boot configuration - uses existing EFI partition
# This assumes you have already partitioned the disk manually
# and are pointing to the NixOS-designated partition
{ device ? "/dev/sda", nixosPartition ? "/dev/sda3", efiPartition ? "/dev/sda1", swapSize ? "8G", ... }:
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = device;
        content = {
          type = "gpt";
          partitions = {
            # Reuse existing EFI partition
            ESP = {
              start = "1MiB";
              end = "513MiB";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" "umask=0077" ];
              };
            };
            # Optional swap
            swap = {
              start = "513MiB";
              end = swapSize;
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            # NixOS root - adjust start/end based on your partition layout
            root = {
              start = swapSize;
              end = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" "-L" "nixos" ];
                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                  };
                  "@vms" = {
                    mountpoint = "/var/lib/libvirt/images";
                    mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" "nodatacow" ];
                  };
                  "@snapshots" = {
                    mountpoint = "/.snapshots";
                    mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  # Note: For dual-boot, you'll need to manually set up GRUB to detect other OS
  # Add this to your configuration.nix:
  #
  # boot.loader.grub = {
  #   enable = true;
  #   device = "nodev";
  #   efiSupport = true;
  #   useOSProber = true;  # This detects other operating systems
  # };
}
