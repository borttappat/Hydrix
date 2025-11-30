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
    useDefaultShell = true;
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
