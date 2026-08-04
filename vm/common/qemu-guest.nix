# QEMU guest configuration
{ lib, pkgs, ... }:

{
  # VM guest services — always present regardless of display mode
  virtualisation.vmware.guest.enable = true;
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  # Virtio kernel modules
  boot.initrd.availableKernelModules = [
    "virtio_balloon"
    "virtio_blk"
    "virtio_pci"
    "virtio_ring"
    "virtio_net"
    "virtio_scsi"
    "virtio_console"
  ];

  # Disable power management for VMs
  powerManagement = {
    enable = false;
    cpuFreqGovernor = lib.mkDefault "performance";
  };

  # Disable services not needed in VMs
  services = {
    thermald.enable = false;
    tlp.enable = false;
  };

  # VM tools
  environment.systemPackages = with pkgs; [
    open-vm-tools
    spice-vdagent
    spice-gtk
  ];

  # Networking
  networking = {
    firewall.allowPing = true;
    useDHCP = lib.mkDefault true;
  };

  # Boot settings for VMs
  boot.loader.timeout = lib.mkDefault 1;
  boot.kernelParams = [
    "quiet"
    "console=tty1"
    "console=ttyS0,115200n8"
  ];

}
