#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|

{ config, pkgs, lib, ... }:

{
  # Define user 'traum'
  users.users.traum = {
    isNormalUser = true;
    description = "A";
    extraGroups = [ "docker" "audio" "networkmanager" "wheel" "wireshark" "adbusers" ];
    createHome = true;
    shell = pkgs.fish;  # Explicitly use fish shell
    # Default password for VMs (can be overridden per-profile)
    password = "traum";
  };

  # Auto-login on TTY
  services.getty.autologinUser = "traum";

  # Sudo without password
  security.sudo.extraRules = [
    {
      users = [ "traum" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
