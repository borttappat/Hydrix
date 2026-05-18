#                                      _
#   __  __________  __________  ____  (_)  __
#  / / / / ___/ _ \/ ___/ ___/ / __ \/ / |/_/
# / /_/ (__  )  __/ /  (__  ) / / / / />  <
# \__,_/____/\___/_/  /____(_)_/ /_/_/_/|_|
#
# VM User Configuration
# Uses config.hydrix.* options from the central options module.
#
# VM-specific credentials are set in the user's machine config or VM module:
#   hydrix = {
#     username = "alice";
#     user.hashedPassword = "$6$...";  # Optional, default: passwordless first login
#   };

{ config, pkgs, lib, ... }:

let
  # Get user config from central options
  cfg = config.hydrix;
  vmUser = cfg.username;
  vmHashedPassword = cfg.user.hashedPassword;

  # Map shell name to package
  shellPkg = {
    fish = pkgs.fish;
    bash = pkgs.bash;
    zsh = pkgs.zsh;
  }.${cfg.shell};

in {
  # Allow runtime password changes
  users.mutableUsers = true;

  # Define VM user with customizable username
  users.users.${vmUser} = {
    isNormalUser = true;
    description = "VM User (${vmUser})";
    extraGroups = [ "wheel" "audio" "video" "networkmanager" ];
    createHome = true;
    shell = shellPkg;
    home = "/home/${vmUser}";

    # Use VM-specific password if available, otherwise prompt on first login
    hashedPassword = vmHashedPassword;

    # If no hashed password baked in, use empty password (prompts to set one)
    initialPassword = lib.mkIf (vmHashedPassword == null) "";
  };

  # Auto-login for VMs (convenience - VMs are already isolated); can be disabled per-VM
  hydrix.user.autologin = lib.mkDefault true;
  services.getty.autologinUser = lib.mkIf cfg.user.autologin vmUser;

  # First-login password prompt service - DISABLED
  # TODO: Implement proper password prompting for Phase 15 (Profile Hardening)
  #
  # The previous approach blocked boot because:
  # - Service ran before user login, no TTY available
  # - passwd requires interactive input which fails on serial console
  # - Service blocking multi-user.target caused rebuild hangs
  #
  # For now: Use passwordless sudo + auto-login (VMs are isolated)
  # Future: Use --pass flag with deploy-vm.sh, or implement getty-based prompt

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

  # Note: hydrix.vm.user option is defined in modules/options.nix
  # All modules should use config.hydrix.username (or config.hydrix.vm.user for compatibility)
}
