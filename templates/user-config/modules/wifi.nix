# WiFi Configuration - Shared across all machines
#
# Run 'wifi-sync add SSID PASSWORD' (admin mode) to add via router.
# Run 'wifi-sync' (fallback mode) to capture the current host connection.
# Run 'wifi-sync pull' to merge all router NM connections into this list.

{ config, lib, pkgs, ... }:

{
  hydrix.router.wifi.networks = [ ];
}
