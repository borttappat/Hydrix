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
  # Per-VM focus border - simple threat-level indicator for VM windows
  # Supports named colors: red, orange, yellow, green, cyan, blue, purple, pink, magenta
  # Or hex codes: #RRGGBB
  # hydrix.vmThemeSync.focusBorder = "red";  # red, orange, yellow, green, etc.

  # Firefox user-agent: "firefox-windows" matches the Tor Browser UA, maximising
  # anonymity set when browsing over Tor (all Tor Browser users look identical).
  # Presets: "edge-windows" | "chrome-windows" | "chrome-mac" | "safari-mac" | "firefox-windows"
  hydrix.graphical.firefox.userAgent = "firefox-windows";
  # Minimal extension set — ephemeral profile, no password manager
  # Available: ublock-origin, pywalfox, vimium-ff, detach-tab,
  #            bitwarden, foxyproxy, wappalyzer, singlefile, darkreader, styl-us
  hydrix.graphical.firefox.extensions = [
    "ublock-origin" "pywalfox" "vimium-ff" "detach-tab"
  ];

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # MicroVM resources (ephemeral - no persistence)
  hydrix.microvm = {
    vcpu = 2;
    mem = 2304;  # 2.25GB (avoid QEMU 2GB-exact hang bug)
    inherit (meta) vsockCid bridge tapId;
    persistence.enable = false;
  };
  hydrix.networking.vmSubnet = meta.subnet;

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
