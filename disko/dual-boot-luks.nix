# Disko configuration: Dual-boot with LUKS encryption
# The installer pre-creates the NixOS partition; this config formats it
# directly as LUKS+btrfs without touching the partition table.
#
# Parameters:
#   nixosPartition - Pre-created partition device (e.g., "/dev/nvme0n1p3")
#   luksName       - LUKS device name (default: "cryptroot")
#   swapSize       - Swap file size (default: "16G")

{ nixosPartition, luksName ? "cryptroot", swapSize ? "16G", ... }:
{
  disko.devices.disk.nixos = {
    type = "disk";
    device = nixosPartition;
    content = {
      type = "luks";
      name = luksName;
      settings.allowDiscards = true;
      passwordFile = "/tmp/luks-password";
      content = {
        type = "btrfs";
        extraArgs = [ "-f" "-L" "nixos" ];
        subvolumes = {
          "@" = {
            mountpoint = "/";
            mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];
          };
          "@home" = {
            mountpoint = "/home";
            mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];
          };
          "@nix" = {
            mountpoint = "/nix";
            mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" "discard=async" ];
          };
          "@persist" = {
            mountpoint = "/persist";
            mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
          };
          "@log" = {
            mountpoint = "/var/log";
            mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
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
            mountOptions = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
          };
          "@swap" = {
            mountpoint = "/.swap";
            swap.swapfile.size = swapSize;
          };
        };
      };
    };
  };
}
