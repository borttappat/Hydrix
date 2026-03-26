# Dev Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base dev profile.
# Hydrix base provides: xpra forwarding, sound, graphical stack
# This profile adds: packages, Docker, development tools
#
{ config, lib, pkgs, ... }:

{
  imports = [
    # Core VM packages (editors, shell, utils)
    ../../shared/vm-packages.nix
    # Profile-specific packages
    ./packages.nix
    # Custom packages (added via vm-sync pull)
    ./packages
  ];

  # =========================================================================
  # VM IDENTITY & COLORS
  # =========================================================================

  # Colorscheme for this VM
  hydrix.colorscheme = "puccy";
  # hydrix.vmThemeSync.focusOverrideColor = "#AABBCC";  # Per-VM focus border override (use with hydrix-focus on)

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # MicroVM resources (must match CID in host scripts)
  hydrix.microvm = {
    vcpu = 4;
    mem = 8192;  # 8GB (balloon reclaims idle)
    vsockCid = 103;  # Unique for dev VM
    bridge = "br-dev";
    tapId = "mv-dev";
    persistence = {
      enable = true;
      homeSize = 51200;  # 50GB
      extraVolumes = [{
        name = "docker";
        size = 20480;
        mountPoint = "/var/lib/docker";
      }];
    };
    secrets.github = true;
  };

  # =========================================================================
  # SERVICES
  # =========================================================================

  # Docker available but not started on boot
  # Start on demand: sudo systemctl start docker
  virtualisation.docker = {
    enable = true;
    enableOnBoot = false;
  };

  users.users.${config.hydrix.username}.extraGroups = [ "docker" ];

  hydrix.ollama = {
    enable = false;
    model = "deepseek-coder:6.7b";
    cpuCores = 5;
    memoryLimit = "10G";
  };

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   vscode
  #   jetbrains.idea-community
  # ];
}
