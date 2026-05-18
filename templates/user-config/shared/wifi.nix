# WiFi Configuration - Shared across all machines
#
# This file is read by router VMs during build.
# Populated automatically by the installer. Change here to update all machines at once.
#
# IMPORTANT: If using a private git repo, this is safe to commit.
# If using a public repo, consider using sops-nix for encryption.

{ config, lib, pkgs, ... }:

{
  hydrix.router.wifi = {
    ssid     = lib.mkDefault "@WIFI_SSID@";
    password = lib.mkDefault "@WIFI_PASSWORD@";
  };
}
