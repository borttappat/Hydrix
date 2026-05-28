# Network configuration
{ config, pkgs, lib, ... }:

{
  # Default hostname (override in profiles with mkForce)
  networking.hostName = lib.mkDefault "hydrix";

  # NetworkManager for easy network management
  networking.networkmanager.enable = lib.mkDefault true;

  # Firewall: default-drop, no open ports.
  # Specialisations add ports as needed (e.g. administrative adds SSH).
  # VMs open port 8888 for files-agent via extraCommands (not here).
  networking.firewall = {
    enable = lib.mkDefault true;
    allowedTCPPorts = lib.mkDefault [];
    allowedUDPPorts = lib.mkDefault [];
  };
}
