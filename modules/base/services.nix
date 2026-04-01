#                        __                           __
#.-----.-----.----.--.--|__.----.-----.-----.  .-----|__.--.--.
#|__ --|  -__|   _|  |  |  |  __|  -__|__ --|__|     |  |_   _|
#|_____|_____|__|  \___/|__|____|_____|_____|__|__|__|__|__.__|

{ config, lib, pkgs, ... }:

let cfg = config.hydrix; in
{

programs.dconf.enable = true;

# NetworkManager configuration
systemd.services.NetworkManager-wait-online = {
    enable = false;
};

networking = {
    networkmanager = {
        enable = true;  
    };
};
    
# avoid issues with #/bin/bash scripts and alike
services.envfs.enable = true;

# ollama, LLM (disabled - testing in VM instead)
# services.ollama.enable = true;

# udisksctl
services.udisks2.enable = true; #added with udisks in packages.nix


# Lid and suspend/resume settings
services.logind.settings.Login = {
  HandleLidSwitch = "suspend";              # Suspend on lid close (default)
  HandleLidSwitchExternalPower = "ignore";  # Ignore when on AC power
  HandleLidSwitchDocked = "ignore";         # Ignore when docked/external display
};

# ACPID for explicit lid open/close events (belt-and-suspenders with systemd)
services.acpid = {
  enable = true;
  lidEventCommands = ''
    # Log lid events for debugging
    echo "[$(date)] Lid event: $1 $2 $3" >> /tmp/acpid-lid.log

    case "$3" in
      open)
        # Give hardware time to initialize
        sleep 1

        # Find X session and wake display
        for user_home in /home/*; do
          username=$(basename "$user_home")
          xauth_file="$user_home/.Xauthority"
          if [ -f "$xauth_file" ] && [ -S /tmp/.X11-unix/X0 ]; then
            # Force DPMS on
            su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
            # Reinitialize displays
            su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true
          fi
        done
        echo "[$(date)] Lid open: display recovery attempted" >> /tmp/acpid-lid.log
        ;;
      close)
        # logind handles suspend - nothing to do
        echo "[$(date)] Lid close: letting logind handle suspend" >> /tmp/acpid-lid.log
        ;;
    esac
  '';
};

# Pre-suspend service: set DPMS to known state before suspending
systemd.services.pre-suspend-display = {
  description = "Prepare display for suspend";
  wantedBy = [ "sleep.target" ];
  before = [ "sleep.target" ];
  unitConfig = {
    StopWhenUnneeded = true;
  };
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
  };
  script = ''
    echo "[$(date)] Pre-suspend: setting DPMS state" >> /tmp/suspend-debug.log

    # Find X session and set DPMS to suspend state
    for user_home in /home/*; do
      username=$(basename "$user_home")
      xauth_file="$user_home/.Xauthority"
      if [ -f "$xauth_file" ] && [ -S /tmp/.X11-unix/X0 ]; then
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force suspend" 2>/dev/null || true
      fi
    done

    echo "[$(date)] Pre-suspend: done" >> /tmp/suspend-debug.log
  '';
};

# Post-resume service: wake display after resume with retry logic
systemd.services.post-resume-display = {
  description = "Recover display after resume";
  wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
  after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
  serviceConfig = {
    Type = "oneshot";
  };
  script = ''
    echo "[$(date)] Post-resume: starting display recovery" >> /tmp/suspend-debug.log

    # Wait for hardware to stabilize
    sleep 2

    # Find X session and recover display (try twice with delay)
    for user_home in /home/*; do
      username=$(basename "$user_home")
      xauth_file="$user_home/.Xauthority"
      if [ -f "$xauth_file" ] && [ -S /tmp/.X11-unix/X0 ]; then
        # First attempt
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true

        # Wait and retry (some displays need double-tap)
        sleep 1
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true

        # Trigger user-level post-resume service (for display-setup after unlock)
        echo "$(date +%s)" > /tmp/resume-trigger
        chown "$username" /tmp/resume-trigger 2>/dev/null || true
      fi
    done

    echo "[$(date)] Post-resume: display recovery attempted" >> /tmp/suspend-debug.log
  '';
};

# Resume fix: refresh display after waking from suspend
# This is a fallback - primary fix is xss-lock in i3.nix which runs display-setup after unlock
# This system-level command helps when X session doesn't respond properly
powerManagement.resumeCommands = ''
  # Give hardware time to reinitialize
  sleep 1

  # Find the X session owner and refresh their display
  for user_home in /home/*; do
    username=$(basename "$user_home")
    xauth_file="$user_home/.Xauthority"
    if [ -f "$xauth_file" ] && [ -S /tmp/.X11-unix/X0 ]; then
      # Force DPMS on (wake display)
      su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
      # Reinitialize displays
      su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true
    fi
  done
'';

# Rsync (disabled - not needed on host)
# services.rsyncd.enable = true;

# Enable touchpad support
services.libinput.enable = lib.mkIf cfg.hardware.touchpad.enable true;

# MySQL
/*    
services.mysql = {
    enable = true;
    package = pkgs.mariadb;
};
*/


# Enabling auto-cpufreq
services.auto-cpufreq.enable = lib.mkIf cfg.power.autoCpuFreq true;

# Power mode toggle script
environment.systemPackages = [
  (pkgs.writeShellScriptBin "power-mode" ''
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
          echo "powersave" > "$STATE_FILE"
          echo "Power-save mode active. CPU limited to 60% for battery life."
          ;;
        balanced|auto)
          echo "Restoring auto management..."
          # Restore max performance to 100%
          echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/max_perf_pct > /dev/null 2>&1 || true
          # Re-enable turbo
          echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null 2>&1 || true
          sudo systemctl start auto-cpufreq.service
          echo "auto" > "$STATE_FILE"
          echo "Auto mode active. CPU managed by auto-cpufreq."
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
          echo "performance" > "$STATE_FILE"
          echo "Performance mode active. Maximum speed."
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

    case "''${1:-status}" in
      powersave|save|low) set_mode powersave ;;
      balanced|auto) set_mode balanced ;;
      performance|high) set_mode performance ;;
      toggle) toggle ;;
      status|*)
        current=$(get_current)
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "n/a")
        turbo_off=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "n/a")
        freq=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))

        echo "=== Power Mode ==="
        echo "Current mode:  $current"
        echo "Governor:      $gov"
        echo "EPP:           $epp"
        echo "Turbo:         $([ "$turbo_off" = "0" ] && echo "enabled" || echo "disabled")"
        echo "Frequency:     $freq MHz"
        echo ""
        echo "Usage: power-mode [powersave|balanced|performance|toggle|status]"
        echo "  powersave   - Minimal power, limited CPU"
        echo "  balanced    - Auto management (default)"
        echo "  performance - Maximum speed"
        echo "  toggle      - Cycle between powersave and balanced"
        ;;
    esac
  '')
];

# Ensure power-mode state file exists with correct permissions (world-writable)
# so both the boot service (root) and user script can write to it
systemd.tmpfiles.rules = [
  "d /run/hydrix 0755 root root -"
  "f /run/hydrix/power-mode-state 0666 root root - auto"
];

# Apply default power profile at boot (from hydrix.power.defaultProfile)
systemd.services.power-profile-default = {
  description = "Apply default power profile";
  wantedBy = [ "multi-user.target" ];
  after = [ "auto-cpufreq.service" "systemd-tmpfiles-setup.service" ];
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
        echo "performance" > "$STATE_FILE"
        ;;
      balanced|*)
        # Default: let auto-cpufreq manage
        echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || true
        echo "balanced" > "$STATE_FILE"
        ;;
    esac
  '';
};

# Apply battery charge limit at boot (from hydrix.power.chargeLimit)
systemd.services.battery-charge-limit = lib.mkIf (config.hydrix.power.chargeLimit != null) {
  description = "Apply battery charge limit";
  wantedBy = [ "multi-user.target" ];
  after = [ "sysinit.target" ];
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

# Intel-undervolt
#services.undervolt.enable = true;

# Enable the OpenSSH daemon.
services.openssh.enable = lib.mkIf cfg.services.ssh.enable true;

# Enabling tailscale VPN
services.tailscale.enable = lib.mkIf cfg.services.tailscale.enable true;

# Enable i2c-bus
hardware.i2c.enable = lib.mkIf cfg.hardware.i2c.enable true;

# Bluetooth (host only - VMs don't import services.nix)
hardware.bluetooth = lib.mkIf cfg.hardware.bluetooth.enable {
  enable = true;
  powerOnBoot = true;
  settings = {
    General = {
      Enable = "Source,Sink,Media,Socket";
    };
  };
};
services.blueman.enable = lib.mkIf cfg.hardware.bluetooth.enable true;

# Undervolt
   # services.undervolt = {
   #     enable = false;
   #     coreOffset = -80;
   # };


}
