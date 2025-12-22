#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|

{ config, pkgs, lib, ... }:

let
  # Import local host config if it exists (requires --impure)
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  basePath = if hydrixPath != "" then hydrixPath else
    let user = builtins.getEnv "USER";
    in if user != "" then "/home/${user}/Hydrix" else "/home/traum/Hydrix";

  hostConfigPath = "${basePath}/local/host.nix";

  # Default config if local file doesn't exist
  defaultConfig = {
    username = "user";
    hashedPassword = null;
    description = "Default User";
    sshKeys = [];
    extraGroups = [];
  };

  # Use local config if available, otherwise defaults
  hostConfig = if builtins.pathExists hostConfigPath
    then import hostConfigPath
    else defaultConfig;

  username = hostConfig.username or defaultConfig.username;

in {
  # Define user from local config
  users.users.${username} = {
    isNormalUser = true;
    description = hostConfig.description or username;
    extraGroups = [ "docker" "audio" "networkmanager" "wheel" "wireshark" "adbusers" ]
                  ++ (hostConfig.extraGroups or []);
    createHome = true;
    shell = pkgs.fish;

    # Use hashed password from local config (secure)
    # Falls back to no password if not set (login via SSH key only)
    hashedPassword = hostConfig.hashedPassword or null;

    # SSH authorized keys from local config
    openssh.authorizedKeys.keys = hostConfig.sshKeys or [];
  };

  # Auto-login on TTY (uses dynamic username)
  services.getty.autologinUser = username;

  # Sudo without password
  security.sudo.extraRules = [
    {
      users = [ username ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
