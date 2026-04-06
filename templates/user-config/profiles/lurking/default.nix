# Lurking Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base lurking profile.
# Hydrix base provides: xpra forwarding, sound, graphical stack
# This profile adds: Tor, anonymous browsing packages
#
# EPHEMERAL by design - all data lost on restart for maximum privacy.
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
  hydrix.colorscheme = "punk";
  # hydrix.vmThemeSync.focusOverrideColor = "#AABBCC";  # Per-VM focus border override (use with hydrix-focus on)

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # MicroVM resources (ephemeral - no persistence)
  hydrix.microvm = {
    vcpu = 2;
    mem = 2304;  # 2.25GB (avoid QEMU 2GB-exact hang bug)
    inherit (meta) vsockCid bridge tapId;
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
