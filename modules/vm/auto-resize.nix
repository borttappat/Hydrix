# Automatic display resize for SPICE VMs using udev
# This replaces polling with event-driven resize detection
{ config, lib, pkgs, ... }:

let
  # Script that applies the new resolution when DRM changes are detected
  resizeScript = pkgs.writeShellScript "x-resize" ''
    #!/usr/bin/env bash
    # Auto-resize script triggered by udev on DRM changes
    # This runs as root, so we need to find user sessions and apply xrandr

    LOG_DIR="/var/log/autores"
    LOG_FILE="$LOG_DIR/autores.log"

    mkdir -p "$LOG_DIR"

    log() {
      echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
    }

    log "DRM change detected, checking for active X sessions..."

    # Find all active X sessions by checking /tmp/.X*-lock files
    for lockfile in /tmp/.X*-lock; do
      [ -f "$lockfile" ] || continue

      DISPLAY_NUM=$(basename "$lockfile" | sed 's/\.X\([0-9]*\)-lock/\1/')
      DISPLAY=":$DISPLAY_NUM"

      # Find the user running X on this display
      X_PID=$(cat "$lockfile" 2>/dev/null | tr -d ' ')
      [ -z "$X_PID" ] && continue

      # Get the user from the X process
      X_USER=$(ps -o user= -p "$X_PID" 2>/dev/null | tr -d ' ')
      [ -z "$X_USER" ] && continue

      # Get user's home directory
      USER_HOME=$(getent passwd "$X_USER" | cut -d: -f6)

      log "Found X session: DISPLAY=$DISPLAY, USER=$X_USER"

      # Set XAUTHORITY - try common locations
      if [ -f "$USER_HOME/.Xauthority" ]; then
        XAUTHORITY="$USER_HOME/.Xauthority"
      elif [ -f "/run/user/$(id -u "$X_USER")/.mutter-Xwaylandauth."* ] 2>/dev/null; then
        XAUTHORITY=$(ls /run/user/$(id -u "$X_USER")/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
      else
        XAUTHORITY="$USER_HOME/.Xauthority"
      fi

      export DISPLAY XAUTHORITY

      # Get the output name (usually Virtual-1 or Virtual-0)
      OUTPUT=$(su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY ${pkgs.xorg.xrandr}/bin/xrandr 2>/dev/null" | grep " connected" | head -1 | cut -d' ' -f1)

      if [ -n "$OUTPUT" ]; then
        log "Applying auto resolution to $OUTPUT for user $X_USER"

        # Apply the auto resolution
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY ${pkgs.xorg.xrandr}/bin/xrandr --output '$OUTPUT' --auto" 2>> "$LOG_FILE"

        # Give X a moment to apply the change
        sleep 0.3

        # Restart polybar to adjust to new resolution (run as user)
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY pkill polybar" 2>/dev/null || true
        sleep 0.2

        # Check if this is a VM (has both top and bottom bars)
        # Launch polybar in background
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY polybar top 2>/dev/null &" &
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY polybar bottom 2>/dev/null &" &

        log "Resize complete for $OUTPUT"
      else
        log "Could not determine output name for DISPLAY=$DISPLAY"
      fi
    done

    log "DRM change processing complete"
  '';
in
{
  # Udev rule to trigger resize on DRM changes
  services.udev.extraRules = ''
    # Auto-resize VM display when SPICE client changes resolution
    ACTION=="change", KERNEL=="card[0-9]*", SUBSYSTEM=="drm", RUN+="${resizeScript}"
  '';

  # Ensure log directory exists
  systemd.tmpfiles.rules = [
    "d /var/log/autores 0755 root root -"
  ];
}
