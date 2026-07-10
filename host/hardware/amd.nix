# AMD Platform - Microcode, graphics, power management
#
# Provides:
#   - AMD graphics drivers and hardware acceleration
#   - AMD microcode updates
#
# NOTE: thermald is DISABLED by default - on ASUS systems, asusd handles thermal
# management better with hardware-specific fan curves. Enable thermald for
# non-ASUS AMD systems if desired (thermald has limited AMD support).

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.hardware.platform == "amd") {
    # AMD microcode
    hardware.cpu.amd.updateMicrocode = true;

    # AMD graphics
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        amdvlk            # AMDVLK Vulkan (AMD's open driver)
        vulkan-radeon     # Mesa RADV Vulkan (usually preferred; higher compatibility)
        libva-mesa-driver # VA-API hardware video decode via Mesa
      ];
    };

    # Thermald for AMD thermal management
    # DISABLED by default: on ASUS systems, asusd handles thermals
    # Enable for non-ASUS AMD systems if desired
    services.thermald.enable = lib.mkDefault false;
  };
}
