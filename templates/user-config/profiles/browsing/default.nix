# Browsing Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base browsing profile.
# Hydrix base provides: xpra forwarding, sound, graphical stack
# This profile adds: packages, colorscheme, styling preferences
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

  # Colorscheme for this VM (see colorschemes/ in Hydrix repo)
  hydrix.colorscheme = "punk";
  # Per-VM focus border override — pick a color from your colorscheme's palette
  # To find palette values: cat ~/.cache/wal/colors.json  (or colorschemes/<scheme>.json)
  # hydrix.vmThemeSync.focusOverrideColor = "#AABBCC";

  # MicroVM resources (must match CID in host scripts)
  hydrix.microvm = {
    vcpu = 2;
    mem = 2304;  # 2.25GB (avoid QEMU 2GB-exact hang bug)
    inherit (meta) vsockCid bridge tapId;
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
  # VPN ROUTING
  # =========================================================================
  # VPN exit node assignment happens at runtime via the host — not declarative here.
  # Requires: router.vpn.mullvad = import ../vpn/mullvad.nix; in your machine config.
  #
  #   vpn-assign browse mullvad-se                  # Route via Sweden
  #   vpn-assign browse mullvad-ch                  # Route via Switzerland
  #   vpn-assign --persistent browse mullvad-se     # Persist across reboots
  #   vpn-assign browse none                        # Direct (no VPN)

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   chromium
  #   thunderbird
  # ];
}
