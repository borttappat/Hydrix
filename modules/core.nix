# Core modules - Essential components for ALL Hydrix VMs and hosts
# This is imported by both base images and full profiles
{ config, pkgs, lib, ... }:

let
  # Detect username dynamically
  # For host: reads from local/host.nix
  # For VMs: defaults to "user"
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

  username = if hostConfig != null && hostConfig ? username
    then hostConfig.username
    else "user";
in
{
  imports = [
    # Window manager and desktop environment
    ./wm/i3.nix

    # Shell and terminal environment
    ./shell/fish.nix
    ./shell/packages.nix

    # Theming system
    ./theming/colors.nix
  ];

  # Essential packages that every VM needs
  environment.systemPackages = with pkgs; [
    # Editors
    vim

    # Network tools
    wget
    curl

    # System monitoring
    htop

    # File management
    ranger

    # Terminal utilities
    tmux
    fzf

    # Version control
    git
  ];

  # X11 essentials for desktop environment
  services.xserver = {
    enable = true;

    # Enable startx for "x" command
    displayManager.startx.enable = true;
  };

  # Auto-login (moved to new location in NixOS 25.05)
  services.displayManager.autoLogin = {
    enable = true;
    user = username;
  };

  # Auto-login to console (TTY1)
  # Use mkDefault so users.nix or users-vm.nix can override
  services.getty.autologinUser = lib.mkDefault username;
}
