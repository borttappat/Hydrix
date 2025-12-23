#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|
#
# VM User Configuration
# Simple, isolated user for VMs - does NOT use host secrets

{ config, pkgs, lib, ... }:

let
  # VM user is intentionally simple and isolated from host
  # VMs should not have access to host credentials
  vmUser = "user";

  # Try to read VM-specific secrets if available
  # This allows VMs to have their own local config after cloning Hydrix
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";

  # Determine VM type from hostname (e.g., "pentest-vm" → "pentest")
  vmType = let
    hostname = config.networking.hostName;
    parts = lib.splitString "-" hostname;
  in if builtins.length parts > 0 then builtins.head parts else "generic";

  # Path to VM-specific secrets
  vmSecretsPath = "${basePath}/local/vms/${vmType}.nix";

  # Load VM secrets if they exist, otherwise use defaults
  vmSecrets = if builtins.pathExists vmSecretsPath
    then import vmSecretsPath
    else { hashedPassword = null; };

in {
  # Define VM user - simple, predictable, isolated
  users.users.${vmUser} = {
    isNormalUser = true;
    description = "VM User";
    extraGroups = [ "wheel" "audio" "video" "networkmanager" ];
    createHome = true;
    shell = pkgs.fish;

    # Use VM-specific password if available, otherwise allow passwordless login
    # VMs are already isolated by network, so this is acceptable
    hashedPassword = vmSecrets.hashedPassword;

    # Fallback: if no hashed password, use simple password for convenience
    # This is OK because VMs are network-isolated
    password = if vmSecrets.hashedPassword == null then "user" else null;
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
}
