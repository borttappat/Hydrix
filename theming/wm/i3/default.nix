# i3 Window Manager Module - Full Graphical Environment
#
# Provides i3-gaps window manager and complete desktop infrastructure.
# Only activates when hydrix.graphical.enable = true.
#
# Used by:
# - Host systems (always)
# - Libvirt VMs with standalone mode (for virt-manager/fullscreen use)
#
# NOT used by MicroVMs - they use xpra-apps.nix (minimal: alacritty, firefox, pywal)
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;
in
{
  imports = [ ./i3.nix ./polybar.nix ./picom.nix ./rofi.nix ./scripts.nix ./file-finder.nix ];

  config = lib.mkIf (cfg.enable && config.hydrix.i3.enable) {
    services.xserver.displayManager.startx.enable = true;
    services.xserver.windowManager.i3.enable = true;
    services.xserver.windowManager.i3.package = pkgs.i3;

    environment.systemPackages = with pkgs; [
      # Window manager
      i3
      i3lock-color
      i3status

      # Compositor
      picom

      # Status bar
      polybar

      # Launcher
      rofi

      # Notifications
      dunst
      libnotify

      # Screenshot
      flameshot

      # Wallpaper
      feh

      # Display management
      arandr
      xorg.xrandr
      xorg.xmodmap

      # Audio
      pavucontrol

      # Clipboard
      xclip

      # Appearance
      lxappearance
    ];

    # ACPID for explicit lid open/close events (belt-and-suspenders with systemd)
    services.acpid = {
      enable = lib.mkDefault true;
      lidEventCommands = lib.mkDefault ''
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
    # Fallback — primary fix is xss-lock which runs display-setup after unlock
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
  };

/*
services.picom = {
enable = true;
fade = true;
fadeDelta = 5;
fadeSteps = [0.028 0.03];
shadow = true;
shadowOffsets = [(-7) (-7)];
shadowOpacity = 0.7;
shadowRadius = 12;
activeOpacity = 0.95;
inactiveOpacity = 0.85;
backend = "glx";
vSync = true;
};
*/

}
