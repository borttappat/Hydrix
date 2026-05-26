# Host Users - Create user account based on hydrix.username
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;

  # Map shell name to package
  shellPkg = {
    fish = pkgs.fish;
    bash = pkgs.bash;
    zsh = pkgs.zsh;
  }.${cfg.shell};
in {
  config = lib.mkIf (cfg.vmType == "host") {
    # Set mainUser for virt.nix (adds virtualization groups)
    virtualisation.mainUser = cfg.username;

    users.users.${cfg.username} = {
      isNormalUser = true;
      description = cfg.user.description;
      extraGroups = [
        "wheel"
        "networkmanager"
        "video"
        "audio"
        "input"
        "libvirtd"
        "docker"
        "kvm"
        "dialout"
      ] ++ cfg.user.extraGroups;
      shell = shellPkg;

      # SSH authorized keys from options
      openssh.authorizedKeys.keys = cfg.user.sshPublicKeys;

      # Note: No hashedPassword set - user's existing password is preserved
      # To set password declaratively, use: hydrix.user.hashedPassword = "...";
    };

    # Allow wheel group to sudo without password
    security.sudo.wheelNeedsPassword = false;

    # Auto-login (disabled by default on host)
    services.getty.autologinUser = lib.mkIf cfg.user.autologin cfg.username;
    services.displayManager.autoLogin = {
      enable = false;
      user = cfg.username;
    };
  };
}
