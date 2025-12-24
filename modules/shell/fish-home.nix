# Fish shell configuration via home-manager
# Deploys config files only - fish shell itself is enabled in fish.nix
{ config, pkgs, lib, ... }:

let
  # Check if we're building for a VM (vmType is set)
  isVM = (config.hydrix.vmType or null) != null;

  # Detect username dynamically
  # For VMs: always "user"
  # For host: reads from local/host.nix
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";
  hostConfigPath = "${basePath}/local/host.nix";

  # Use local config username if available (host), otherwise "user" (VM)
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
  home-manager.users.${username} = {
    # Required by home-manager
    home.stateVersion = "25.05";

    # Deploy fish config and starship
    # Note: xinitrc.nix deploys fish_variables and functions
    home.file.".config/fish/config.fish".source = ../../configs/fish/config.fish;
    home.file.".config/starship.toml".source = ../../configs/starship/starship.toml;
  };
}
