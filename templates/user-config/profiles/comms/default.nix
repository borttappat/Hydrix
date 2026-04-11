# Comms Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base comms profile.
# Hydrix base provides: xpra forwarding, sound (required for calls), graphical stack
# This profile adds: packages (Signal, Firefox)
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
  hydrix.colorscheme = "deeporange";
  # Per-VM focus border - simple threat-level indicator for VM windows
  # Supports named colors: red, orange, yellow, green, cyan, blue, purple, pink, magenta
  # Or hex codes: #RRGGBB
  # hydrix.vmThemeSync.focusBorder = "green";  # red, orange, yellow, green, etc.

  # Firefox user-agent: avoid standing out on messaging platforms.
  # Presets: "edge-windows" | "chrome-windows" | "chrome-mac" | "safari-mac" | "firefox-windows"
  hydrix.graphical.firefox.userAgent = "chrome-windows";

  # Inherit host colors for consistent look
  hydrix.vmColors.enable = true;

  # MicroVM resources
  hydrix.microvm = {
    vcpu = 2;
    mem = 2304;  # 2.25GB (avoid QEMU 2GB-exact hang bug)
    inherit (meta) vsockCid bridge tapId;
    persistence = {
      enable = true;
      homeSize = 10240;  # 10GB - accounts, chat history, credentials
    };
    # Set persistence.enable = false for ephemeral/privacy-first comms
  };

  # =========================================================================
  # EXTRA PACKAGES
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   slack
  #   zoom-us
  # ];
}
