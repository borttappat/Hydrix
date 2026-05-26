# VM Minimal Module - Essential shell and login configuration for headless/xpra VMs
#
# Packages and environment variables are configured in the user's
# hydrix-config/shared/vm-packages.nix.
#
# This module provides only the shell setup and auto-login (plumbing).
#
{ config, pkgs, lib, ... }:

let
  username = config.hydrix.username;
in {
  # Fish shell (used by all VMs)
  programs.fish.enable = true;
  users.users.${username}.shell = lib.mkDefault pkgs.fish;

  # Fish configuration
  programs.fish.interactiveShellInit = ''
    # Disable greeting
    set -g fish_greeting ""

    # Aliases
    alias ll='ls -la'
    alias la='ls -a'
    alias l='ls -l'
  '';

  # Auto-login to console (TTY1)
  services.getty.autologinUser = lib.mkDefault username;
}
