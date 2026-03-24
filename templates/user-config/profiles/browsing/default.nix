# Browsing Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base browsing profile.
# Hydrix base provides: xpra forwarding, sound, graphical stack
# This profile adds: packages, colorscheme, styling preferences
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

  # Colorscheme for this VM (see colorschemes/ in Hydrix repo)
  hydrix.colorscheme = "punk";

  # MicroVM resources (must match CID in host scripts)
  hydrix.microvm = {
    vcpu = 2;
    mem = 2048;  # 2GB (balloon reclaims idle)
    vsockCid = 101;  # Unique for browsing VM
    bridge = "br-browse";
    tapId = "mv-browse";
    persistence = {
      enable = true;
      homeSize = 10240;  # 10GB
    };
    secrets.github = true;
  };

  # Inherit host colors for consistent look
  # full = use all host colors | dynamic = host bg + vm text | none = ignore host
  hydrix.vmColors.enable = true;

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   chromium
  #   thunderbird
  # ];
}
