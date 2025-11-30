{ config, pkgs, lib, ... }:

{
  # Base theming infrastructure shared by both static (VM) and dynamic (host) setups
  #
  # This module provides:
  # - Core theming packages (pywal, jq, xrandr, etc.)
  # - Display configuration script
  # - Cache directory structure
  # - Template processing utilities

  # Install theming dependencies
  environment.systemPackages = with pkgs; [
    pywal            # Color scheme generator
    jq               # JSON parsing for display-config.json
    xorg.xrandr      # Display resolution detection/management
    imagemagick      # Image processing for pywal
    sed              # Template variable substitution
  ];

  # Deploy load-display-config.sh script to system PATH
  environment.systemPackages = [
    (pkgs.writeScriptBin "load-display-config"
      (builtins.readFile ../../scripts/load-display-config.sh))
  ];

  # Ensure .cache/wal directory exists for pywal
  # This is created per-user to avoid permission issues
  systemd.tmpfiles.rules = [
    "d /home/traum/.cache 0755 traum users -"
    "d /home/traum/.cache/wal 0755 traum users -"
  ];

  # Note: Template files and actual config deployment happens in xinitrc.nix
  # This module only provides the base infrastructure
}
