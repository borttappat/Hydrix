# Dev Profile - Services
#
# Database and development services
{ config, pkgs, lib, ... }:

{
  # PostgreSQL for database development
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
  };
}
