# Intel-specific hardware configuration
# Include this module for Intel-based systems
#
# Provides:
#   - Intel graphics drivers and hardware acceleration
#   - Intel microcode updates
#   - Thermald for Intel thermal management
#   - Intel-specific kernel parameters

{ config, pkgs, lib, ... }:

{
  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

  # Intel graphics and hardware acceleration
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver    # VAAPI driver for newer Intel GPUs (Broadwell+)
      vaapiIntel           # VAAPI driver for older Intel GPUs
      vaapiVdpau           # VDPAU backend for VAAPI
      libvdpau-va-gl       # VDPAU driver using OpenGL
      intel-compute-runtime # OpenCL support
    ];
  };

  # Enable thermald for Intel thermal management
  services.thermald.enable = true;

  # Intel-specific kernel parameters for better graphics performance
  boot.kernelParams = [
    "i915.enable_fbc=1"      # Enable framebuffer compression
    "i915.enable_psr=1"      # Enable panel self-refresh (power saving)
  ];

  # Intel OpenCL support packages
  environment.systemPackages = with pkgs; [
    intel-compute-runtime
    ocl-icd
    intel-ocl
    intel-gpu-tools        # Intel GPU debugging tools (intel_gpu_top, etc.)

    # Intel GPU status script
    (writeShellScriptBin "intel-gpu-status" ''
      #!/bin/sh
      echo "Intel GPU Status"
      echo "================"
      echo ""
      echo "Driver info:"
      ${pkgs.pciutils}/bin/lspci -v | grep -A 10 "VGA compatible controller.*Intel" | head -15
      echo ""
      echo "VAAPI support:"
      ${pkgs.libva-utils}/bin/vainfo 2>/dev/null || echo "  vainfo not available"
      echo ""
      echo "GPU usage (press q to quit):"
      echo "  Run: sudo intel_gpu_top"
    '')
  ];

  # Environment variables for Intel graphics
  environment.variables = {
    LIBVA_DRIVER_NAME = "iHD";  # Use newer intel-media-driver
  };
}
