# Comms Profile - Services
#
# Privacy and communication services
{ config, pkgs, lib, ... }:

{
  # Tor service for privacy
  services.tor = {
    enable = true;
    client.enable = true;
  };
}
