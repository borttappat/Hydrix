# WiFi Configuration - Shared across all machines
#
# Run 'wifi-sync pull' to populate from router, or add networks manually.
# Run 'wifi-sync add SSID PASSWORD' to push to router and save in one step.
# Passwords may be plaintext or WPA PSK hashes (64-char hex) — both are accepted.
#
# IMPORTANT: All VMs share the host's Nix store and can read this file,
# including the PSK hashes. Use sops-nix to encrypt credentials at rest.

{ config, lib, pkgs, ... }:

{
  hydrix.router.wifi.networks = lib.mkDefault [
    # { ssid = "MyNetwork"; password = "plaintext-or-64char-psk-hash"; priority = 100; }
  ];
}
