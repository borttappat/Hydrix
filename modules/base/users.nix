#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|
#
# Host User Configuration
# Uses config.hydrix.* options from the central options module.
#
# User configuration is set in the user's machine config:
#   hydrix = {
#     username = "alice";
#     user.hashedPassword = "$6$...";  # Optional
#     user.sshPublicKeys = [ "ssh-rsa ..." ];
#     user.extraGroups = [ "libvirtd" ];
#   };

{ config, pkgs, lib, ... }:

let
  # Get user config from central options
  cfg = config.hydrix;
  username = cfg.username;

  # Map shell name to package
  shellPkg = {
    fish = pkgs.fish;
    bash = pkgs.bash;
    zsh = pkgs.zsh;
  }.${cfg.shell};

in {
  # Set mainUser for virt.nix (which adds virtualization groups)
  virtualisation.mainUser = username;

  # Define user from options
  users.users.${username} = {
    isNormalUser = true;
    description = cfg.user.description;
    extraGroups = [ "docker" "audio" "networkmanager" "wheel" "wireshark" "adbusers" ]
                  ++ cfg.user.extraGroups;
    createHome = true;
    shell = shellPkg;

    # SSH authorized keys from options
    openssh.authorizedKeys.keys = cfg.user.sshPublicKeys;

    # Note: No hashedPassword set - user's existing password is preserved
    # To set password declaratively, use: hydrix.user.hashedPassword = "...";
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
