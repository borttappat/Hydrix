# __NAME_CAP__ Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base profile (if one exists for this type),
# or stands alone as a new VM type discovered by the flake.
# Hydrix base provides: xpra forwarding, sound, graphical stack.
# This profile adds: packages, colorscheme, resource sizing.
#
{ config, lib, pkgs, ... }:
let meta = import ./meta.nix; in
{
  imports = [
    # Core VM packages (editors, shell, utils) — shared across all VMs
    ../../shared/vm-packages.nix
    # Profile-specific packages
    ./packages.nix
    # Custom packages (added via vm-sync pull — do not edit manually)
    ./packages
  ];

  # =========================================================================
  # VM IDENTITY & COLORS
  # =========================================================================

  # Colorscheme for this VM (see colorschemes/ for options)
  hydrix.colorscheme = "__COLORSCHEME__";

  # Per-VM focus border color - simple threat-level indicator for VM windows.
  # Supports named colors: red, orange, yellow, green, cyan, blue, purple, pink, magenta
  # Or hex codes: #RRGGBB
  # hydrix.vmThemeSync.focusBorder = "orange";  # red, orange, yellow, green, etc.

  # Firefox user-agent: blend in or null for the real UA.
  # Presets: "edge-windows" | "chrome-windows" | "chrome-mac" | "safari-mac" | "firefox-windows"
  # hydrix.graphical.firefox.userAgent = "edge-windows";

  # MicroVM resources
  hydrix.microvm = {
    vcpu = 2;
    mem = 2304;  # 2.25GB (avoid QEMU 2GB-exact hang bug)
    inherit (meta) vsockCid bridge tapId;
    persistence = {
      enable = true;
      homeSize = 10240;  # 10GB — adjust as needed
    };
    secrets.github = true;
  };
  hydrix.networking.vmSubnet = meta.subnet;

  # Inherit host colors for consistent look
  # full = use all host colors | dynamic = host bg + vm text | none = ignore host
  hydrix.vmColors.enable = true;

  # =========================================================================
  # VPN ROUTING (optional)
  # =========================================================================
  # VPN exit node assignment happens at runtime via the host.
  # Requires: router.vpn.mullvad = import ../vpn/mullvad.nix; in machine config.
  #
  #   vpn-assign __NAME__ mullvad-se     # Route via Sweden
  #   vpn-assign __NAME__ none           # Direct (no VPN)

  # =========================================================================
  # EXTRA PACKAGES (optional — prefer packages.nix for larger sets)
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   your-package
  # ];
}
