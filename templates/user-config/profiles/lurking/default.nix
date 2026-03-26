# Lurking Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base lurking profile.
# Hydrix base provides: xpra forwarding, sound, graphical stack
# This profile adds: Tor, anonymous browsing packages
#
# EPHEMERAL by design - all data lost on restart for maximum privacy.
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
  hydrix.colorscheme = "punk";
  # hydrix.vmThemeSync.focusOverrideColor = "#AABBCC";  # Per-VM focus border override (use with hydrix-focus on)

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # MicroVM resources (ephemeral - no persistence)
  hydrix.microvm = {
    vcpu = 2;
    mem = 2048;  # 2GB (balloon reclaims idle)
    vsockCid = 105;  # Unique for lurking VM
    bridge = "br-lurking";
    tapId = "mv-lurking";
    persistence.enable = false;
  };

  # =========================================================================
  # SERVICES
  # =========================================================================

  services.tor = {
    enable = true;
    client.enable = true;
    settings.SOCKSPort = [ 9050 ];
  };

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   # Your packages
  # ];
}
