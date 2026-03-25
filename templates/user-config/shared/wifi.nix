# WiFi Configuration - Shared across all machines
#
# This file is read by router VMs during build.
# Update these credentials to connect to your network.
#
# IMPORTANT: If using a private git repo, this is safe to commit.
# If using a public repo, consider using sops-nix for encryption.

{ config, lib, pkgs, ... }:

{
  hydrix.router.wifi = {
    ssid = lib.mkDefault "YourNetworkName";
    password = lib.mkDefault "YourPassword";
  };
}
