{ config, pkgs, lib, ... }:

let
  # Username is computed by hydrix-options.nix (single source of truth)
  username = config.hydrix.username;
in
{
  # Base theming infrastructure shared by both static (VM) and dynamic (host) setups
  #
  # This module provides:
  # - Core theming packages (pywal, jq, xrandr, etc.)
  # - Display configuration script
  # - Cache directory structure
  # - Template processing utilities

  # Install theming dependencies and deploy scripts
  environment.systemPackages = with pkgs; [
    pywal            # Color scheme generator
    jq               # JSON parsing for display-config.json
    xorg.xrandr      # Display resolution detection/management
    imagemagick      # Image processing for pywal
    # sed is built-in, no need to install

    # Deploy load-display-config.sh script to system PATH
    (pkgs.writeScriptBin "load-display-config"
      (builtins.readFile ../../scripts/load-display-config.sh))
  ];

  # Ensure .cache/wal directory exists for pywal
  # This is created per-user to avoid permission issues
  systemd.tmpfiles.rules = [
    "d /home/${username}/.cache 0755 ${username} users -"
    "d /home/${username}/.cache/wal 0755 ${username} users -"
  ];

  # Note: Template files and actual config deployment happens in xinitrc.nix
  # This module only provides the base infrastructure
}
