# Network configuration
{ config, pkgs, ... }:

{
  # Default hostname (override in profiles)
  networking.hostName = "hydrix";

  # NetworkManager for easy network management
  networking.networkmanager.enable = true;

  # Firewall settings
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 8080 4444 4445 8000 ];
    allowedUDPPorts = [ 22 53 80 4444 4445 5353 5355 5453 ];
  };

  # Disable nftables (use iptables)
  networking.nftables.enable = false;
}
