# User configuration
{ config, pkgs, ... }:

{
  # Define user 'traum'
  users.users.traum = {
    isNormalUser = true;
    description = "A";
    extraGroups = [ "docker" "audio" "networkmanager" "wheel" "wireshark" ];
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
