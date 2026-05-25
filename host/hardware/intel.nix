# Intel Platform - Microcode, graphics, power management
#
# Provides:
#   - Intel graphics drivers and hardware acceleration
#   - Intel microcode updates
#   - Intel-specific kernel parameters
#
# NOTE: thermald is DISABLED by default - on ASUS systems, asusd handles thermal
# management better with hardware-specific fan curves. Enable thermald for
# non-ASUS Intel systems if needed.

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.hardware.platform == "intel") {
    # Intel microcode
    hardware.cpu.intel.updateMicrocode = true;

    # Intel graphics
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        intel-vaapi-driver
        libva-vdpau-driver
        libvdpau-va-gl
      ];
    };

    # Thermald for Intel thermal management
    # DISABLED by default: asusd handles thermals better on ASUS laptops
    # Enable this for non-ASUS Intel systems
    services.thermald.enable = lib.mkDefault false;
  };
}
