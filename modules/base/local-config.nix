# Local Configuration Module
#
# This module imports local (gitignored) configuration files and applies them.
# It enforces isolation: VMs only get their specific secrets, never host secrets.
#
# Usage in flake.nix:
#   For host:     ./modules/base/local-config.nix { machineType = "host"; }
#   For VMs:      ./modules/base/local-config.nix { machineType = "pentest"; }
#
# Requires --impure flag for nixos-rebuild.

{ machineType ? "host" }:

{ config, pkgs, lib, ... }:

let
  # Base path for local config - uses environment variable for flexibility
  # SUDO_USER preserves the original user when running with sudo
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";
  localPath = "${basePath}/local";

  # Helper to safely import a file if it exists
  importIfExists = path: default:
    if builtins.pathExists path
    then import path
    else default;

  # Shared config (non-secret, used by all)
  sharedConfig = importIfExists "${localPath}/shared.nix" {
    timezone = "UTC";
    locale = "en_US.UTF-8";
    consoleKeymap = "us";
    xkbLayout = "us";
    xkbVariant = "";
    extraLocaleSettings = {};
  };

  # Host-only config (NEVER available to VMs)
  hostConfig = if machineType == "host"
    then importIfExists "${localPath}/host.nix" {
      username = "user";
      hashedPassword = null;
      description = "";
      sshKeys = [];
      extraGroups = [];
    }
    else {};  # VMs get empty host config - cannot access host secrets

  # VM-specific config (each VM type only gets its own)
  vmConfig = if machineType != "host"
    then importIfExists "${localPath}/vms/${machineType}.nix" {
      hashedPassword = null;
    }
    else {};  # Host doesn't need VM secrets

  # Determine if we're running as a VM
  isVM = machineType != "host";

in {
  # Timezone (all systems)
  time.timeZone = sharedConfig.timezone;

  # Locale settings (all systems)
  i18n.defaultLocale = sharedConfig.locale;
  i18n.extraLocaleSettings = sharedConfig.extraLocaleSettings or {};

  # Console keymap (all systems)
  console.keyMap = sharedConfig.consoleKeymap;

  # X11 keyboard (all systems)
  services.xserver.xkb = {
    layout = sharedConfig.xkbLayout;
    variant = sharedConfig.xkbVariant or "";
  };

  # User configuration - only for host
  # VMs have their own user config in their profile modules
  users.users = lib.mkIf (!isVM && hostConfig ? username && hostConfig.username != null) {
    "${hostConfig.username}" = {
      isNormalUser = true;
      description = hostConfig.description or hostConfig.username;
      extraGroups = [ "wheel" "networkmanager" "audio" "docker" "wireshark" "adbusers" ]
                    ++ (hostConfig.extraGroups or []);
      createHome = true;
      shell = pkgs.fish;
      hashedPassword = hostConfig.hashedPassword;
      openssh.authorizedKeys.keys = hostConfig.sshKeys or [];
    };
  };

  # Export local config for other modules to use
  # This allows other modules to access values without re-importing
  _module.args = {
    localConfig = {
      inherit sharedConfig;
      # Only expose what's appropriate for this machine type
      hostConfig = if isVM then {} else hostConfig;
      vmConfig = if isVM then vmConfig else {};
      machineType = machineType;
    };
  };
}
