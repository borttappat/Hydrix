# Dev Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base dev profile.
# Hydrix base provides: xpra forwarding, sound, graphical stack
# This profile adds: packages, Docker, development tools
#
{ config, lib, pkgs, ... }:
let meta = import ./meta.nix; in
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
  # Per-VM focus border - simple threat-level indicator for VM windows
  # Supports named colors: red, orange, yellow, green, cyan, blue, purple, pink, magenta
  # Or hex codes: #RRGGBB
  # hydrix.vmThemeSync.focusBorder = "yellow";  # red, orange, yellow, green, etc.

  # Firefox user-agent: unset (null) keeps the real UA — useful when testing
  # web apps where accurate browser detection matters.
  # hydrix.graphical.firefox.userAgent = "edge-windows";

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # MicroVM resources (must match CID in host scripts)
  hydrix.microvm = {
    vcpu = 4;
    mem = 8192;  # 8GB (balloon reclaims idle)
    inherit (meta) vsockCid bridge tapId;
    persistence = {
      enable = true;
      homeSize = 51200;  # 50GB
      extraVolumes = [{
        name = "docker";
        size = 20480;
        mountPoint = "/var/lib/docker";
      }];
    };
    secrets.github = false;
  };
  hydrix.networking.vmSubnet = meta.subnet;

  # =========================================================================
  # SERVICES
  # =========================================================================

  # Tailscale VPN (run `tailscale up` after first boot to authenticate)
  services.tailscale.enable = true;

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
