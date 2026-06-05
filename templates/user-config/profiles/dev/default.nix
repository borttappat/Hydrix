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
    ../../modules/vm-packages.nix
    # Profile-specific packages
    ./packages.nix
    # Custom packages (added via vm-sync pull)
    ./packages
  ];

  # =========================================================================
  # VM IDENTITY & COLORS
  # =========================================================================

  # Custom hostname (default: dev-vm)
  # WARNING: changing after first boot orphans the persistent volume.
  # hydrix.vm.hostname = "my-dev";

  # Colorscheme for this VM
  hydrix.colorscheme = "puccy";
  # Per-VM focus border - simple threat-level indicator for VM windows
  # Supports named colors: red, orange, yellow, green, cyan, blue, purple, pink, magenta
  # Or hex codes: #RRGGBB
  hydrix.vmThemeSync.focusBorder = "cyan";

  # Firefox user-agent: unset (null) keeps the real UA — useful when testing
  # web apps where accurate browser detection matters.
  # hydrix.graphical.firefox.userAgent = "edge-windows";
  # Extensions to force-install in this profile.
  # Available: ublock-origin, pywalfox, vimium-ff, detach-tab,
  #            bitwarden, foxyproxy, wappalyzer, singlefile, darkreader, styl-us
  hydrix.graphical.firefox.extensions = [
    "ublock-origin" "pywalfox" "vimium-ff" "detach-tab"
    "bitwarden"
  ];

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

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   vscode
  #   jetbrains.idea-community
  # ];
}
