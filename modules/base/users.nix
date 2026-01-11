#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|

{ config, pkgs, lib, ... }:

let
  # Import local host config if it exists (requires --impure)
  # SUDO_USER preserves the original user when running with sudo
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  # Prefer SUDO_USER (set by sudo), fall back to USER, then "user"
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  # For single-repo Hydrix, use ~/Hydrix
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";

  # Host config stored in local/ directory (gitignored)
  # First try relative path, then absolute
  localHostPath = ./../../local/host.nix;
  hostConfigPath = "${basePath}/local/host.nix";

  # Default config if local file doesn't exist
  defaultConfig = {
    username = "user";
    description = "Default User";
    sshPublicKeys = [];
    extraGroups = [];
  };

  # Use local config if available, otherwise defaults
  # First try relative path (flake-local), then absolute path (HYDRIX_PATH)
  hostConfig = if builtins.pathExists localHostPath then import localHostPath
    else if builtins.pathExists hostConfigPath then import hostConfigPath
    else defaultConfig;

  username = hostConfig.username or defaultConfig.username;

in {
  # Set mainUser for virt.nix (which adds virtualization groups)
  virtualisation.mainUser = username;

  # Define user from local config
  users.users.${username} = {
    isNormalUser = true;
    description = hostConfig.description or username;
    extraGroups = [ "docker" "audio" "networkmanager" "wheel" "wireshark" "adbusers" ]
                  ++ (hostConfig.extraGroups or []);
    createHome = true;
    shell = pkgs.fish;

    # Note: No hashedPassword set - user's existing password from installation is preserved
    # For VMs, password is set during VM build

    # SSH authorized keys from local config
    openssh.authorizedKeys.keys = hostConfig.sshPublicKeys or [];
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
