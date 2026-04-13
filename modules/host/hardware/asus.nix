# ASUS Hardware - Laptop-specific tools and services
#
# Include this module for ASUS laptops (ROG, Zenbook, etc.)
#
# Provides:
#   - asusd service for ASUS laptop control (fan curves, platform profiles)
#   - Battery charge limit management
#   - ASUS-specific power management
#   - Helper scripts for ASUS features
#
# Power Management Architecture:
#   - asusd: Controls ASUS platform profile (Quiet/Balanced/Performance)
#     - Quiet: Conservative fan curves, lower TDP limits
#     - Balanced: Normal operation
#     - Performance: Aggressive cooling, higher TDP limits
#   - power-mode: Controls CPU governor and max_perf_pct (in services.nix)
#     - powersave: 60% max perf, turbo off, powersave governor
#     - balanced: auto-cpufreq manages dynamically
#     - performance: 100% max perf, turbo on, performance governor
#
# For quietest operation: asus-profile quiet + power-mode powersave
# For maximum performance: asus-profile performance + power-mode performance

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  username = cfg.username;

  # Package scripts for runtime access (when Hydrix is imported from GitHub)
  hydrixScriptsPackage = pkgs.stdenvNoCC.mkDerivation {
    name = "hydrix-scripts";
    src = ../../../scripts;
    installPhase = ''
      mkdir -p $out/scripts
      cp -r $src/* $out/scripts/
      chmod +x $out/scripts/*
    '';
  };

  # Combined power profile switcher (ASUS platform + CPU governor)
  # Sets both asus-profile and power-mode together for convenience
  mkPowerProfileScript = pkgs.writeShellScriptBin "power-profile" ''
    case "$1" in
      quiet|save|powersave)
        echo "Setting quiet power profile..."
        ${pkgs.asusctl}/bin/asusctl profile -P Quiet
        power-mode powersave
        echo ""
        echo "Quiet mode active:"
        echo "  - ASUS platform: Quiet (conservative fans)"
        echo "  - CPU: 60% max, turbo off"
        ;;
      balanced|auto)
        echo "Setting balanced power profile..."
        ${pkgs.asusctl}/bin/asusctl profile -P Balanced
        power-mode balanced
        echo ""
        echo "Balanced mode active:"
        echo "  - ASUS platform: Balanced"
        echo "  - CPU: auto-cpufreq managed"
        ;;
      performance|high)
        echo "Setting performance power profile..."
        ${pkgs.asusctl}/bin/asusctl profile -P Performance
        power-mode performance
        echo ""
        echo "Performance mode active:"
        echo "  - ASUS platform: Performance (aggressive cooling)"
        echo "  - CPU: 100% max, turbo on"
        ;;
      status|*)
        echo "=== Power Profile Status ==="
        echo ""
        echo "ASUS Platform:"
        ${pkgs.asusctl}/bin/asusctl profile -p
        echo ""
        power-mode status
        echo ""
        if [ "$1" != "status" ]; then
          echo "Usage: power-profile <quiet|balanced|performance|status>"
          echo "  quiet       - Minimum noise, maximum battery"
          echo "  balanced    - Auto management (default)"
          echo "  performance - Maximum speed"
        fi
        ;;
    esac
  '';

in {
  config = lib.mkIf cfg.hardware.isAsus {
    # ASUS laptop control
    # This handles platform profiles, fan curves, and ASUS-specific features
    # NOTE: thermald is disabled in intel.nix - asusd handles thermal management
    services.asusd = {
      enable = true;
      enableUserService = true;
    };

    # Apply ASUS AC/battery profiles at boot from hydrix.hardware.asus options
    systemd.services.asus-profile-setup = {
      description = "Apply ASUS platform profiles";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        acProfile = cfg.hardware.asus.acProfile;
        batProfile = cfg.hardware.asus.batteryProfile;
      in ''
        # Set profiles via asusctl if available
        if command -v asusctl >/dev/null 2>&1; then
          echo "Setting ASUS AC profile to: ${acProfile}"
          asusctl profile -a "${acProfile}" 2>/dev/null || true
          echo "Setting ASUS battery profile to: ${batProfile}"
          asusctl profile -b "${batProfile}" 2>/dev/null || true
        fi
      '';
    };

    # Disable thermald - asusd handles thermal management better
    # with hardware-specific fan curves
    services.thermald.enable = lib.mkForce false;

    # Supergfxd for GPU switching (if applicable)
    services.supergfxd.enable = true;

    # ASUS packages
    environment.systemPackages = with pkgs; [
      asusctl
      supergfxctl
      # Combined power profile switcher
      mkPowerProfileScript
    ];
  };
}
