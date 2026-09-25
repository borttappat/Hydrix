# Dev Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base dev profile.
# Hydrix base provides: waypipe forwarding, sound, graphical stack
# This profile adds: packages, Docker, development tools
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  meta = import ./meta.nix;
in {
  imports = [
    # Core VM packages (editors, shell, utils)
    ../../modules/vm-packages.nix
    # Profile-specific packages
    ./packages.nix
    # Custom packages (added via vm-sync pull)
    ./packages
    # Declarative git repos, uncomment to enable (see hydrix.repos below)
    # ../../modules/repos.nix
  ];

  # =========================================================================
  # VM IDENTITY & COLORS
  # =========================================================================

  # Custom hostname (default: dev-vm)
  # WARNING: changing after first boot orphans the persistent volume.
  # hydrix.vm.hostname = "my-dev";

  # Colorscheme for this VM
  hydrix.colorscheme = "hydrix";

  # Firefox user-agent: unset (null) keeps the real UA — useful when testing
  # web apps where accurate browser detection matters.
  # hydrix.graphical.firefox.userAgent = "edge-windows";
  # Extensions to force-install in this profile.
  # Available: ublock-origin, pywalfox, vimium-ff, detach-tab,
  #            bitwarden, foxyproxy, wappalyzer, singlefile, darkreader, styl-us
  hydrix.graphical.firefox.extensions = [
    "ublock-origin"
    "pywalfox"
    "vimium-ff"
    "detach-tab"
    "bitwarden"
  ];

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # Repos to auto-clone on boot. Needs ../../modules/repos.nix imported above
  # and this VM's own machine-config entry in microvmHost.vms.<name>.secrets
  # to include "github" so the SSH key is present.
  # hydrix.repos = {
  #   enable = true;
  #   entries = {
  #     my-notes = {
  #       url = "https://github.com/youruser/my-notes.git";
  #       sshUrl = "git@github.com:youruser/my-notes.git";
  #       path = "/home/${config.hydrix.username}/my-notes";
  #       description = "Personal notes";
  #     };
  #   };
  # };

  # MicroVM resources (must match CID in host scripts)
  hydrix.microvm = {
    # Forward VM notifications to a host popup, tagged with the VM name.
    # To disable: notifyForward.enable = false;
    notifyForward.enable = true;
    inherit (meta) vsockCid bridge tapId mem vcpu memLowFloorMb memFloorMb cpuLowFloorPct cpuFloorPct;
    persistence = {
      enable = true;
      homeSize = 51200; # 50GB
      extraVolumes = [
        {
          name = "docker";
          size = 20480;
          mountPoint = "/var/lib/docker";
        }
      ];
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

  users.users.${config.hydrix.username}.extraGroups = ["docker"];

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   vscode
  #   jetbrains.idea-community
  # ];
}
