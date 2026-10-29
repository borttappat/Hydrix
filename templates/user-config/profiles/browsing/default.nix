# Browsing Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base browsing profile.
# Hydrix base provides: waypipe forwarding, sound, graphical stack
# This profile adds: packages, colorscheme, styling preferences
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
  ];

  # =========================================================================
  # VM IDENTITY & COLORS
  # =========================================================================

  # Custom hostname (default: browsing-vm)
  # WARNING: changing after first boot orphans the persistent volume.
  # hydrix.vm.hostname = "my-browsing";

  # Colorscheme for this VM (see colorschemes/ in Hydrix repo)
  hydrix.colorscheme = "hydrix";

  # Firefox user-agent: blend in with the dominant browser/OS fingerprint.
  # Presets: "edge-windows" | "chrome-windows" | "chrome-mac" | "safari-mac" | "firefox-windows"
  # Or pass a raw UA string. null = use Firefox's real UA.
  hydrix.graphical.firefox.userAgent = "edge-windows";
  # Extensions to force-install in this profile.
  # Available: ublock-origin, pywalfox, vimium-ff, detach-tab,
  #            bitwarden, foxyproxy, wappalyzer, singlefile, darkreader, styl-us
  hydrix.graphical.firefox.extensions = [
    "ublock-origin"
    "pywalfox"
    "vimium-ff"
    "detach-tab"
    "bitwarden"
    "darkreader"
    "styl-us"
  ];

  # MicroVM resources (must match CID in host scripts)
  # On lower-spec machines, or for single-tasked VMs like browsing, you can cap
  # the virtiofsd thread pool to reduce idle host threads (default = host CPU count):
  # microvm.virtiofsd.threadPoolSize = lib.mkForce 1;
  hydrix.microvm = {
    # Forward VM notifications to a host popup, tagged with the VM name.
    # Toggle via notifyForward in meta.nix (also gates the host listener).
    notifyForward.enable = meta.notifyForward;
    inherit (meta) vsockCid bridge tapId mem vcpu memLowFloorMb memFloorMb cpuLowFloorPct cpuFloorPct;
    persistence = {
      enable = true;
      homeSize = 10240; # 10GB
    };
  };
  hydrix.networking.vmSubnet = meta.subnet;

  # Inherit host colors for consistent look
  # full = use all host colors | dynamic = host bg + vm text | none = ignore host
  hydrix.vmColors.enable = true;

  # =========================================================================
  # VPN ROUTING
  # =========================================================================
  # A network exits through Mullvad when its name is in networks in vpn/mullvad.nix
  # and its conf is in secrets/mullvad.yaml. At runtime, in the router console:
  #
  #   vpn-assign off browsing      # direct, bypassing the tunnel
  #   vpn-assign on browsing       # back through wg-browsing
  #   vpn-assign browsing blocked  # kill switch

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   chromium
  #   thunderbird
  # ];
}
