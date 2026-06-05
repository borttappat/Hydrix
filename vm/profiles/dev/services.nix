# Dev Profile - Services
#
# Database and development services
{ config, pkgs, lib, ... }:

{
  # PostgreSQL for database development — override in hydrix-config profiles/dev/default.nix
  services.postgresql = {
    enable = lib.mkDefault true;
    enableTCPIP = lib.mkDefault true;
  };
}
