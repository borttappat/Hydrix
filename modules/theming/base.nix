{ config, pkgs, lib, ... }:

let
  # Check if we're building for a VM (vmType is set and not "host")
  isVM = (config.hydrix.vmType or null) != null && config.hydrix.vmType != "host";

  # Detect username dynamically
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";
  hostConfigPath = "${basePath}/local/host.nix";

  hostConfig = if builtins.pathExists hostConfigPath
    then import hostConfigPath
    else null;

  # VMs always use "user", host uses detected username
  username = if isVM then "user"
    else if hostConfig != null && hostConfig ? username
    then hostConfig.username
    else "user";
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
