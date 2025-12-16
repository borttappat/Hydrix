# VM-specific networking configuration
# Overrides base networking for VM guests
{ config, pkgs, lib, ... }:

{
  # VMs should use simple DHCP, not NetworkManager
  # NetworkManager is for interactive systems (laptops, desktops)
  # VMs just need to automatically get an IP from the bridge/router
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce true;

  # Enable all interfaces for DHCP (virtio NICs)
  networking.interfaces = lib.mkDefault {};
}
