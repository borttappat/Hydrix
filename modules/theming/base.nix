{ config, pkgs, lib, ... }:

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
  # Uses "user" - the standard VM user from users-vm.nix
  systemd.tmpfiles.rules = [
    "d /home/user/.cache 0755 user users -"
    "d /home/user/.cache/wal 0755 user users -"
  ];

  # Note: Template files and actual config deployment happens in xinitrc.nix
  # This module only provides the base infrastructure
}
