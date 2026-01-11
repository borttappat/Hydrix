#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|
#
# VM User Configuration
# Uses config.hydrix.username from hydrix-options.nix (the single source of truth)
#
# Secrets file format (local/vms/<hostname>.nix):
#   {
#     username = "alice";           # Optional, default: "user"
#     hashedPassword = "$6$...";    # Optional, default: simple password
#     hostname = "pentest-alice";   # Optional, overrides profile default
#   }

{ config, pkgs, lib, ... }:

let
  # Get hostname (set by profile or override)
  hostname = config.networking.hostName;

  # Username comes from hydrix-options.nix which reads from local/vms/<hostname>.nix
  vmUser = config.hydrix.username;

  # We still need to read the secrets file for the password
  # Path: ../../local/vms/<hostname>.nix relative to modules/base/users-vm.nix
  secretsPath = ../../local/vms/${hostname}.nix;
  vmSecrets = if builtins.pathExists secretsPath then import secretsPath else {};
  vmHashedPassword = vmSecrets.hashedPassword or null;

in {
  # Define VM user with customizable username
  users.users.${vmUser} = {
    isNormalUser = true;
    description = "VM User (${vmUser})";
    extraGroups = [ "wheel" "audio" "video" "networkmanager" ];
    createHome = true;
    shell = pkgs.fish;
    home = "/home/${vmUser}";

    # Use VM-specific password if available
    hashedPassword = vmHashedPassword;

    # Fallback: if no hashed password, use simple password for convenience
    # This is acceptable because VMs are network-isolated
    password = if vmHashedPassword == null then "user" else null;
  };

  # Auto-login for VMs (convenience - VMs are already isolated)
  services.getty.autologinUser = vmUser;

  # Passwordless sudo for VM user
  security.sudo.extraRules = [
    {
      users = [ vmUser ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Set home directory ownership
  systemd.tmpfiles.rules = [
    "d /home/${vmUser} 0755 ${vmUser} users -"
  ];

  # Note: hydrix.vm.user option is defined in hydrix-options.nix
  # All modules should use config.hydrix.username (or config.hydrix.vm.user for compatibility)
}
