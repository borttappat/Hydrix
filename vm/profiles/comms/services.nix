# Comms Profile - Services
#
# Privacy and communication services
{ config, pkgs, lib, ... }:

{
  # Tor service for privacy — override in hydrix-config profiles/comms/default.nix
  services.tor = {
    enable = lib.mkDefault true;
    client.enable = lib.mkDefault true;
  };
}
