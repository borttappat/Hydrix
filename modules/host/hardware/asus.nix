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
#   - power-mode: Controls CPU governor, max_perf_pct, and ASUS fan profiles
#     - powersave: 60% max perf, turbo off, powersave governor, Quiet ASUS profile
#     - balanced: auto-cpufreq manages dynamically, Balanced ASUS profile
#     - performance: 100% max perf, turbo on, performance governor, Performance ASUS profile
#
# For quietest operation: power-mode powersave (sets both CPU + ASUS Quiet profile)
# For maximum performance: power-mode performance (sets both CPU + ASUS Performance profile)

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;

  # Power mode toggle script (ASUS-specific: controls CPU governor + ASUS fan profiles)
  powerModeScript = pkgs.writeShellScriptBin "power-mode" ''
    #!/usr/bin/env bash
    STATE_FILE="/run/hydrix/power-mode-state"

    get_current() {
      if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
      else
        # Check actual state
        local gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        if [[ "$gov" == "powersave" ]]; then
          # Check EPP to distinguish between forced powersave and auto
          local epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "unknown")
          if [[ "$epp" == "power" ]]; then
            echo "powersave"
          else
            echo "auto"
          fi
        elif [[ "$gov" == "performance" ]]; then
          echo "performance"
        else
          echo "auto"
        fi
      fi
    }

    set_mode() {
      local mode="$1"
      case "$mode" in
        powersave|save|low|quiet)
          echo "Setting power-save mode..."
          sudo systemctl stop auto-cpufreq.service 2>/dev/null || true
          for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo powersave | sudo tee "$cpu" > /dev/null
          done
          # Also set energy performance preference to power
          for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo power | sudo tee "$epp" > /dev/null 2>&1 || true
          done
          # Cap max performance to 60% for quieter operation
          echo 60 | sudo tee /sys/devices/system/cpu/intel_pstate/max_perf_pct > /dev/null 2>&1 || true
          # Disable turbo boost
          echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null 2>&1 || true
          # Set ASUS platform profile to Quiet for minimal fan noise
          if command -v asusctl >/dev/null 2>&1; then
            sudo asusctl profile -P Quiet >/dev/null 2>&1 || true
          fi
          echo "powersave" > "$STATE_FILE"
          echo "Mode: powersave — CPU 60%, turbo off, fans quiet"
          ;;
        balanced|auto)
          echo "Restoring auto management..."
          # Restore max performance to 100%
          echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/max_perf_pct > /dev/null 2>&1 || true
          # Re-enable turbo
          echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null 2>&1 || true
          sudo systemctl start auto-cpufreq.service
          # Set ASUS platform profile to Balanced
          if command -v asusctl >/dev/null 2>&1; then
            sudo asusctl profile -P Balanced >/dev/null 2>&1 || true
          fi
          echo "auto" > "$STATE_FILE"
          echo "Mode: balanced — auto-cpufreq, fans balanced"
          ;;
        performance|high)
          echo "Setting performance mode..."
          sudo systemctl stop auto-cpufreq.service 2>/dev/null || true
          # Restore max performance to 100%
          echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/max_perf_pct > /dev/null 2>&1 || true
          # Re-enable turbo
          echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null 2>&1 || true
          for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance | sudo tee "$cpu" > /dev/null
          done
          for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo performance | sudo tee "$epp" > /dev/null 2>&1 || true
          done
          # Set ASUS platform profile to Performance for aggressive fan cooling
          if command -v asusctl >/dev/null 2>&1; then
            sudo asusctl profile -P Performance >/dev/null 2>&1 || true
          fi
          echo "performance" > "$STATE_FILE"
          echo "Mode: performance — 100% CPU, turbo on, fans high"
          ;;
        *)
          echo "Unknown mode: $mode"
          echo "Use: powersave, balanced, performance"
          return 1
          ;;
      esac
    }

    toggle() {
      local current=$(get_current)
      case "$current" in
        powersave) set_mode balanced ;;
        auto|balanced) set_mode powersave ;;
        performance) set_mode balanced ;;
        *) set_mode balanced ;;
      esac
    }

    # asusctl prints verbose zbus/tracing output to stdout — filter it out
    asusctl_quiet() { asusctl "$@" 2>/dev/null | grep -v "^\[INFO\|^Starting version\|^$" ; }

    get_fan_profile() {
      asusctl_quiet profile -p | grep "^Active profile" | sed 's/Active profile is //'
    }

    set_fans() {
      local level="$1"
      if ! command -v asusctl >/dev/null 2>&1; then
        echo "asusctl not available" >&2
        return 1
      fi
      case "$level" in
        low|quiet|silent)
          sudo asusctl profile -P Quiet >/dev/null 2>&1
          echo "Fans: low (Quiet)"
          ;;
        medium|balanced|auto)
          sudo asusctl profile -P Balanced >/dev/null 2>&1
          echo "Fans: medium (Balanced)"
          ;;
        high|max|performance)
          sudo asusctl profile -P Performance >/dev/null 2>&1
          echo "Fans: high (Performance)"
          ;;
        status|*)
          echo "Fan profile: $(get_fan_profile)"
          echo "Usage: power-mode fans [low|medium|high]"
          ;;
      esac
    }

    case "''${1:-status}" in
      powersave|save) set_mode powersave ;;
      balanced|auto) set_mode balanced ;;
      performance) set_mode performance ;;
      toggle) toggle ;;
      fans) set_fans "''${2:-status}" ;;
      status|*)
        current=$(get_current)
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "n/a")
        turbo_off=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "n/a")
        freq=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))
        fan_profile=$(get_fan_profile)

        echo "Mode:     $current  |  Governor: $gov  |  EPP: $epp"
        echo "Turbo:    $([ "$turbo_off" = "0" ] && echo "on" || echo "off")  |  Freq: $freq MHz  |  Fans: $fan_profile"
        echo ""
        echo "Usage: power-mode [powersave|balanced|performance|toggle|fans|status]"
        echo "  powersave   - Minimal power, limited CPU"
        echo "  balanced    - Auto management (default)"
        echo "  performance - Maximum speed"
        echo "  toggle      - Cycle between powersave and balanced"
        echo "  fans <low|medium|high> - Set fan speed independently"
        ;;
    esac
  '';

  # Combined power profile switcher (ASUS platform + CPU governor)
  # Sets both asus-profile and power-mode together for convenience
  mkPowerProfileScript = pkgs.writeShellScriptBin "power-profile" ''
    case "$1" in
      quiet|save|powersave)
        ${pkgs.asusctl}/bin/asusctl profile -P Quiet >/dev/null 2>&1
        ${powerModeScript}/bin/power-mode powersave
        ;;
      balanced|auto)
        ${pkgs.asusctl}/bin/asusctl profile -P Balanced >/dev/null 2>&1
        ${powerModeScript}/bin/power-mode balanced
        ;;
      performance|high)
        ${pkgs.asusctl}/bin/asusctl profile -P Performance >/dev/null 2>&1
        ${powerModeScript}/bin/power-mode performance
        ;;
      status|*)
        ${powerModeScript}/bin/power-mode status
        if [ "$1" != "status" ]; then
          echo ""
          echo "Usage: power-profile <quiet|balanced|performance|status>"
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

    # Ensure power-mode state file exists with correct permissions
    systemd.tmpfiles.rules = [
      "d /run/hydrix 0755 root root -"
      "f /run/hydrix/power-mode-state 0666 root root - auto"
    ];

    # Apply default power profile at boot (from hydrix.power.defaultProfile)
    systemd.services.power-profile-default = {
      description = "Apply default power profile";
      wantedBy = ["multi-user.target"];
      after = ["auto-cpufreq.service" "systemd-tmpfiles-setup.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        profile = config.hydrix.power.defaultProfile;
      in ''
        STATE_FILE="/run/hydrix/power-mode-state"

        case "${profile}" in
          powersave)
            echo "Applying default power profile: powersave"
            ${pkgs.systemd}/bin/systemctl stop auto-cpufreq.service 2>/dev/null || true
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
              echo powersave > "$cpu"
            done
            for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
              echo power > "$epp" 2>/dev/null || true
            done
            # Cap max perf to 60% for quieter operation
            echo 60 > /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || true
            echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
            # Set ASUS platform profile to Quiet
            if command -v asusctl >/dev/null 2>&1; then
              asusctl profile -P Quiet 2>/dev/null || true
            fi
            echo "powersave" > "$STATE_FILE"
            ;;
          performance)
            echo "Applying default power profile: performance"
            ${pkgs.systemd}/bin/systemctl stop auto-cpufreq.service 2>/dev/null || true
            echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || true
            echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
              echo performance > "$cpu"
            done
            for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
              echo performance > "$epp" 2>/dev/null || true
            done
            # Set ASUS platform profile to Performance for aggressive cooling
            if command -v asusctl >/dev/null 2>&1; then
              asusctl profile -P Performance 2>/dev/null || true
            fi
            echo "performance" > "$STATE_FILE"
            ;;
          balanced|*)
            # Default: let auto-cpufreq manage
            echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || true
            # Set ASUS platform profile to Balanced
            if command -v asusctl >/dev/null 2>&1; then
              asusctl profile -P Balanced 2>/dev/null || true
            fi
            echo "balanced" > "$STATE_FILE"
            ;;
        esac
      '';
    };

    # Apply battery charge limit at boot (from hydrix.power.chargeLimit)
    systemd.services.battery-charge-limit = lib.mkIf (config.hydrix.power.chargeLimit != null) {
      description = "Apply battery charge limit";
      wantedBy = ["multi-user.target"];
      after = ["sysinit.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        limit = toString config.hydrix.power.chargeLimit;
      in ''
        # Try common battery paths
        for bat in /sys/class/power_supply/BAT*; do
          if [ -f "$bat/charge_control_end_threshold" ]; then
            echo "Setting charge limit to ${limit}% for $(basename $bat)"
            echo ${limit} > "$bat/charge_control_end_threshold"
          fi
        done
      '';
    };

    # ASUS packages
    environment.systemPackages = with pkgs; [
      asusctl
      supergfxctl
      # Power management scripts
      powerModeScript
      mkPowerProfileScript
    ];
  };
}
