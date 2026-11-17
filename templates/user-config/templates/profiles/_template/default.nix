# __NAME_CAP__ Profile - User Customizations
#
# This is layered ON TOP of Hydrix's base profile (if one exists for this type),
# or stands alone as a new VM type discovered by the flake.
# Hydrix base provides: sound, graphical stack.
# This profile adds: packages, colorscheme, resource sizing.
#
{ config, lib, pkgs, ... }:
let meta = import ./meta.nix; in
{
  imports = [
    # Core VM packages (editors, shell, utils) — shared across all VMs
    ../../modules/vm-packages.nix
    # Guest kernel hardening on the stock kernel (sysctls, boot parameters, module lock)
    ../../modules/vm-hardening.nix
    # Trimmed guest kernel, off until enabled below (hydrix.vmKernel)
    ../../modules/vm-kernel.nix
    # Profile-specific packages
    ./packages.nix
    # Custom packages: every *.nix file in ./packages (vm-sync pull, or copied in by hand)
    ./packages
    # Note: waypipe-vm.nix is auto-included by the Hydrix framework (vm-base.nix)
    # for all profile VMs. No explicit import needed here.
  ];

  # Trimmed guest kernel (modules/vm-kernel.nix): strips bluetooth, wifi, USB peripheral,
  # sound and GPU drivers. Compiled locally on the first build, so off by default.
  # hydrix.vmKernel.enable = true;

  # =========================================================================
  # VM IDENTITY & COLORS
  # =========================================================================

  # VM type (must match profile name for auto-include modules)
  hydrix.vmType = "__NAME__";

  # Custom hostname (default: __NAME__-vm)
  # WARNING: changing after first run orphans the persistent volume — set once.
  # hydrix.vm.hostname = "__NAME__-custom";

  # Colorscheme for this VM (see colorschemes/ for options)
  hydrix.colorscheme = "__COLORSCHEME__";

  # Firefox user-agent: blend in or null for the real UA.
  # Presets: "edge-windows" | "chrome-windows" | "chrome-mac" | "safari-mac" | "firefox-windows"
  # hydrix.graphical.firefox.userAgent = "edge-windows";

  # MicroVM resources. mem/vcpu are ceilings; the elastic CPU/RAM daemon
  # (hydrix.vmElastic, auto-enabled per profile from these meta.nix values)
  # deflates down to memLowFloorMb/cpuLowFloorPct while a window is open but
  # idle, and further to memFloorMb/cpuFloorPct once no windows are open at
  # all. To override any of these for just one machine, plain-assign the
  # field on hydrix.vmElastic.vms.__NAME__ in machines/<serial>.nix instead
  # of editing this profile, e.g.:
  #   hydrix.vmElastic.vms.__NAME__.memFloorMb = 2048;
  hydrix.microvm = {
    notifyForward.enable = meta.notifyForward;
    inherit (meta) vsockCid bridge tapId mem vcpu memLowFloorMb memFloorMb cpuLowFloorPct cpuFloorPct;
    persistence = {
      enable = true;
      homeSize = 10240;  # 10GB — adjust as needed
    };
  };
  hydrix.networking.vmSubnet = meta.subnet;

  # Inherit host colors for consistent look
  # full = use all host colors | dynamic = host bg + vm text | none = ignore host
  hydrix.vmColors.enable = true;

  # =========================================================================
  # VPN ROUTING (optional)
  # =========================================================================
  # A network exits through Mullvad when its name is in networks in vpn/mullvad.nix
  # and its conf is in secrets/mullvad.yaml. At runtime, in the router console:
  #
  #   vpn-assign off __NAME__      # direct, bypassing the tunnel
  #   vpn-assign on __NAME__       # back through wg-__NAME__
  #   vpn-assign __NAME__ blocked  # kill switch

  # =========================================================================
  # EXTRA PACKAGES (optional — prefer packages.nix for larger sets)
  # =========================================================================

  # environment.systemPackages = with pkgs; [
  #   your-package
  # ];
}
