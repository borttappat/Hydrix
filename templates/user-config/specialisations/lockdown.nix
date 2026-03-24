# Lockdown Mode - User customizations
#
# Base config IS lockdown. The framework handles:
#   - No default gateway (host isolated)
#   - Builder VM integration
#   - Mode identification
#
# Add your lockdown-specific packages and settings here.
# This file is imported at the TOP LEVEL of your machine config
# (not inside a specialisation block) because lockdown = base.
#
{ config, lib, pkgs, ... }:

{
  imports = [
    ./_base.nix
  ];

  # Extra lockdown packages
  environment.systemPackages = with pkgs; [
    # Local development (no network required)
    git

    # Encryption tools (local files)
    gnupg
    age

    # Archive tools
    gnutar
    gzip
    xz
  ];
}
