#                        __                           __
#.-----.-----.----.--.--|__.----.-----.-----.  .-----|__.--.--.
#|__ --|  -__|   _|  |  |  |  __|  -__|__ --|__|     |  |_   _|
#|_____|_____|__|  \___/|__|____|_____|_____|__|__|__|__|__.__|
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;
in {
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
    HandleLidSwitch = "suspend"; # Suspend on lid close (default)
    HandleLidSwitchExternalPower = "ignore"; # Ignore when on AC power
    HandleLidSwitchDocked = "ignore"; # Ignore when docked/external display
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
              # Save gamma settings before recovery
              GAMMA_SAVE_FILE="/tmp/xrandr-gamma-save"
              > "$GAMMA_SAVE_FILE"
              for monitor in $(${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep " connected" | cut -d' ' -f1); do
                gamma=$(${pkgs.xorg.xrandr}/bin/xrandr --verbose --query 2>/dev/null | ${pkgs.gawk}/bin/awk -v m="$monitor" '
                  BEGIN { found=0; gamma="" }
                  $1 == m { found=1 }
                  found && /Red gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=$3 }
                  found && /Green gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3 }
                  found && /Blue gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3; print gamma }
                ')
                if [ -n "$gamma" ]; then
                  echo "$monitor=$gamma" >> "$GAMMA_SAVE_FILE"
                fi
              done

              # Force DPMS on
              su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
              # Reinitialize displays
              su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true
              sleep 0.5

              # Restore gamma settings
              if [ -f "$GAMMA_SAVE_FILE" ] && [ -s "$GAMMA_SAVE_FILE" ]; then
                while IFS='=' read -r monitor gamma; do
                  if [ -n "$monitor" ] && [ -n "$gamma" ]; then
                    su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --output $monitor --gamma $gamma" 2>/dev/null || true
                  fi
                done < "$GAMMA_SAVE_FILE"
              fi
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
    wantedBy = ["sleep.target"];
    before = ["sleep.target"];
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
    wantedBy = ["suspend.target" "hibernate.target" "hybrid-sleep.target"];
    after = ["suspend.target" "hibernate.target" "hybrid-sleep.target"];
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
          # Save gamma settings before recovery
          GAMMA_SAVE_FILE="/tmp/xrandr-gamma-save"
          > "$GAMMA_SAVE_FILE"
          for monitor in $(${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep " connected" | cut -d' ' -f1); do
            gamma=$(${pkgs.xorg.xrandr}/bin/xrandr --verbose --query 2>/dev/null | ${pkgs.gawk}/bin/awk -v m="$monitor" '
              BEGIN { found=0; gamma="" }
              $1 == m { found=1 }
              found && /Red gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=$3 }
              found && /Green gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3 }
              found && /Blue gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3; print gamma }
            ')
            if [ -n "$gamma" ]; then
              echo "$monitor=$gamma" >> "$GAMMA_SAVE_FILE"
            fi
          done

          # First attempt
          su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
          su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true

          # Wait and retry (some displays need double-tap)
          sleep 1
          su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
          su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true

          # Restore gamma settings after reinitialization
          sleep 0.5
          if [ -f "$GAMMA_SAVE_FILE" ] && [ -s "$GAMMA_SAVE_FILE" ]; then
            while IFS='=' read -r monitor gamma; do
              if [ -n "$monitor" ] && [ -n "$gamma" ]; then
                su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --output $monitor --gamma $gamma" 2>/dev/null || true
              fi
            done < "$GAMMA_SAVE_FILE"
          fi

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
        # Save gamma settings before recovery
        GAMMA_SAVE_FILE="/tmp/xrandr-gamma-save"
        > "$GAMMA_SAVE_FILE"
        for monitor in $(${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep " connected" | cut -d' ' -f1); do
          gamma=$(${pkgs.xorg.xrandr}/bin/xrandr --verbose --query 2>/dev/null | ${pkgs.gawk}/bin/awk -v m="$monitor" '
            BEGIN { found=0; gamma="" }
            $1 == m { found=1 }
            found && /Red gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=$3 }
            found && /Green gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3 }
            found && /Blue gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3; print gamma }
          ')
          if [ -n "$gamma" ]; then
            echo "$monitor=$gamma" >> "$GAMMA_SAVE_FILE"
          fi
        done

        # Force DPMS on (wake display)
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xset}/bin/xset dpms force on" 2>/dev/null || true
        # Reinitialize displays
        su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --auto" 2>/dev/null || true

        # Restore gamma settings after reinitialization
        sleep 0.5
        if [ -f "$GAMMA_SAVE_FILE" ] && [ -s "$GAMMA_SAVE_FILE" ]; then
          while IFS='=' read -r monitor gamma; do
            if [ -n "$monitor" ] && [ -n "$gamma" ]; then
              su "$username" -c "DISPLAY=:0 XAUTHORITY=$xauth_file ${pkgs.xorg.xrandr}/bin/xrandr --output $monitor --gamma $gamma" 2>/dev/null || true
            fi
          done < "$GAMMA_SAVE_FILE"
        fi
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
