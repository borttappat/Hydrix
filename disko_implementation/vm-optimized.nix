# installer/disko-templates/vm-optimized.nix
# Optimized for VM workloads with reflink support
{ device ? "/dev/sda", swapSize ? "16G", vmStorageSize ? "500G", ... }:
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = device;
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
            swap = {
              size = swapSize;
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ 
                  "-f" 
                  "-L" "nixos"
                  # Optimizations for SSDs
                  "-m" "single"  # Single metadata (not RAID)
                  "-d" "single"  # Single data (not RAID)
                ];
                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [ 
                      "compress=zstd:1"  # Level 1 for faster compression
                      "noatime" 
                      "space_cache=v2"
                      "discard=async"    # SSD optimization
                    ];
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ 
                      "compress=zstd:1" 
                      "noatime" 
                      "space_cache=v2"
                      "discard=async"
                    ];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ 
                      "compress=zstd:1" 
                      "noatime" 
                      "space_cache=v2"
                      "discard=async"
                    ];
                  };
                  # VM storage - CoW enabled for reflinks, but nodatacow for VM images themselves
                  "@vms" = {
                    mountpoint = "/var/lib/libvirt/images";
                    mountOptions = [ 
                      "noatime"
                      "space_cache=v2"
                      "discard=async"
                      # Note: We enable CoW here for reflink support
                      # Individual VM images can be set to nodatacow with chattr +C
                    ];
                  };
                  # Separate subvolume for VM base images (with CoW)
                  "@vm-bases" = {
                    mountpoint = "/var/lib/libvirt/bases";
                    mountOptions = [ 
                      "noatime"
                      "space_cache=v2"
                      "discard=async"
                    ];
                  };
                  # Snapshots for easy rollback
                  "@snapshots" = {
                    mountpoint = "/.snapshots";
                    mountOptions = [ 
                      "compress=zstd:1" 
                      "noatime" 
                      "space_cache=v2"
                    ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  # Post-install setup hints:
  # 
  # 1. Create a base VM image directory:
  #    mkdir -p /var/lib/libvirt/bases
  #
  # 2. For VM images that need performance (no CoW):
  #    chattr +C /var/lib/libvirt/images/some-vm.qcow2
  #
  # 3. For base images you want to reflink (keep CoW):
  #    cp --reflink=always /var/lib/libvirt/bases/base.qcow2 /var/lib/libvirt/images/vm1.qcow2
  #
  # 4. Monitor disk usage:
  #    btrfs filesystem df /
  #    compsize /var/lib/libvirt/images
}
