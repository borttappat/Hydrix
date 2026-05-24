# i3 Lock and Display Scripts
#
# Scripts specific to the i3/X11 stack:
#   lock                  — i3lock-color with wal colors + blurred wallpaper
#   lock-instant          — solid-color instant lock (lid close / suspend)
#   generate-lockscreen   — pre-generate blurred lockscreen cache
#   display-recover       — emergency display recovery after suspend/lid
#   monitor-rescan        — aggressive xrandr rescan for undetected monitors
#
# Also provides:
#   post-resume-display   — systemd service: wait for i3lock exit, run display-setup
#   post-resume-trigger   — systemd path unit: fires on /tmp/resume-trigger change
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";

  generateLockscreenScript = pkgs.writeShellScriptBin "generate-lockscreen" ''
    #!/usr/bin/env bash
    # Pre-generate blurred lockscreen background with text overlay
    # Runs in background so walrgb returns immediately

    WALLPAPER="$1"
    LOCK_CACHE="$HOME/.cache/lockscreen.png"
    LOCK_LOG="/tmp/lockscreen-gen.log"

    # Configuration (baked at build time)
    FONT="${cfg.lockscreen.font}"
    FONT_SIZE=${toString cfg.lockscreen.fontSize}
    LOCK_TEXT="${cfg.lockscreen.text}"

    # Source wal colors for theming
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      color1="#bf616a"
    fi

    echo "[$(date)] Starting lockscreen generation from: $WALLPAPER" >> "$LOCK_LOG"

    if [ ! -f "$WALLPAPER" ]; then
      echo "[$(date)] Error: Wallpaper not found: $WALLPAPER" >> "$LOCK_LOG"
      exit 1
    fi

    # Detect virtual desktop dimensions and primary monitor position for correct text placement
    VIRT_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
    VIRT_SIZE="''${VIRT_SIZE:-1920x1200}"
    PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected primary " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    [ -z "$PRIMARY_GEOM" ] && PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    MON_X=0; MON_Y=0
    if [ -n "$PRIMARY_GEOM" ]; then
      MON_X=$(echo "$PRIMARY_GEOM" | cut -d+ -f2)
      MON_Y=$(echo "$PRIMARY_GEOM" | cut -d+ -f3)
    fi
    TEXT_X=$((MON_X + 50))
    TEXT_Y=$((MON_Y + 50))

    # Create temp files
    blur_img="/tmp/lockscreen_blur_$$.png"

    ${
      if cfg.lockscreen.blur
      then ''
        # Scale wallpaper to virtual desktop size, then pixelate
        ${pkgs.imagemagick}/bin/magick "$WALLPAPER" -resize "$VIRT_SIZE^" -gravity Center -extent "$VIRT_SIZE" -scale 20% -scale 500% "$blur_img" 2>>"$LOCK_LOG"
      ''
      else ''
        ${pkgs.imagemagick}/bin/magick "$WALLPAPER" -resize "$VIRT_SIZE^" -gravity Center -extent "$VIRT_SIZE" "$blur_img" 2>>"$LOCK_LOG"
      ''
    }

    # Add text overlay on primary monitor (fall back to CozetteVector if font fails - bitmap fonts don't work)
    if ! ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
        -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
        -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" "$LOCK_CACHE" 2>>"$LOCK_LOG"; then
      FONT="CozetteVector"
      ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
          -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
          -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" "$LOCK_CACHE" 2>>"$LOCK_LOG"
    fi

    # Cleanup
    rm -f "$blur_img"

    echo "[$(date)] Lockscreen generated: $LOCK_CACHE" >> "$LOCK_LOG"
  '';

  lockScript = pkgs.writeShellScriptBin "lock" ''
    # Kill any existing instances
    ${pkgs.killall}/bin/killall -q i3lock

    # Source wal colors for theming
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      # Fallback colors if wal not initialized
      color0="#0c0c0c"
      color1="#bf616a"
      color3="#ebcb8b"
      color6="#8fbcbb"
      color7="#d8dee9"
    fi

    # Move cursor to bottom-right corner (out of the way)
    ${pkgs.xdotool}/bin/xdotool mousemove 9999 9999

    # Configuration (baked at build time from hydrix.graphical.lockscreen options)
    FONT="${cfg.lockscreen.font}"
    CLOCK_SIZE=${toString cfg.lockscreen.clockSize}
    WRONG_TEXT="${cfg.lockscreen.wrongText}"
    VERIFY_TEXT="${cfg.lockscreen.verifyText}"

    # Detect primary monitor position for correct text/element placement on multi-monitor setups
    PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected primary " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    [ -z "$PRIMARY_GEOM" ] && PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    MON_W=1920; MON_H=1200; MON_X=0; MON_Y=0
    if [ -n "$PRIMARY_GEOM" ]; then
      MON_W=$(echo "$PRIMARY_GEOM" | cut -dx -f1)
      MON_H=$(echo "$PRIMARY_GEOM" | cut -dx -f2 | cut -d+ -f1)
      MON_X=$(echo "$PRIMARY_GEOM" | cut -d+ -f2)
      MON_Y=$(echo "$PRIMARY_GEOM" | cut -d+ -f3)
    fi
    # Positions proportional to primary monitor (ratios derived from 1920x1200 originals)
    IND_X=$((MON_X + MON_W * 171 / 1000))
    IND_Y=$((MON_Y + MON_H * 225 / 1000))
    TIME_X=$((MON_X + MON_W * 128 / 1000))
    DATE_X=$((MON_X + MON_W * 115 / 1000))
    DATE_Y=$((MON_Y + MON_H * 158 / 1000))
    VERIF_X=$((MON_X + MON_W * 162 / 1000))
    WRONG_X=$((MON_X + MON_W * 479 / 1000))
    TEXT_X=$((MON_X + 50))
    TEXT_Y=$((MON_Y + 50))

    # Always take a live screenshot, blur it, and apply colors
    LOCK_TEXT="${cfg.lockscreen.text}"
    FONT_SIZE=${toString cfg.lockscreen.fontSize}
    img=/tmp/i3lock_screen.png
    blur_img=/tmp/i3lock_blur.png

    ${pkgs.scrot}/bin/scrot -o "$img" 2>/dev/null || true

    if [ -f "$img" ]; then
      ${
      if cfg.lockscreen.blur
      then ''
        ${pkgs.imagemagick}/bin/magick "$img" -scale 20% -scale 500% "$blur_img" 2>/dev/null || cp "$img" "$blur_img"
      ''
      else ''
        cp "$img" "$blur_img"
      ''
    }

      if ! ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
          -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
          -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" /tmp/i3lock_text.png 2>/dev/null; then
        FONT="CozetteVector"
        ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
            -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
            -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" /tmp/i3lock_text.png 2>/dev/null || true
      fi

      if [ -f /tmp/i3lock_text.png ]; then
        LOCK_IMG=/tmp/i3lock_text.png
      elif [ -f "$blur_img" ]; then
        LOCK_IMG="$blur_img"
      else
        LOCK_IMG="/tmp/i3lock_solid.png"
        SCREEN_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
        ${pkgs.imagemagick}/bin/magick -size "''${SCREEN_SIZE:-1920x1200}" "xc:$color0" "$LOCK_IMG" 2>/dev/null || true
      fi
    else
      LOCK_IMG="/tmp/i3lock_solid.png"
      SCREEN_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
      ${pkgs.imagemagick}/bin/magick -size "''${SCREEN_SIZE:-1920x1200}" "xc:$color0" "$LOCK_IMG" 2>/dev/null || true
    fi

    # Run i3lock-color with wal colors and custom text
    ${pkgs.i3lock-color}/bin/i3lock \
        -i "$LOCK_IMG" \
        --clock \
        --time-str="%H:%M:%S" \
        --date-str="%A, %Y-%m-%d" \
        --layout-font="$FONT" \
        --layout-size=26 \
        --time-font="$FONT" \
        --date-font="$FONT" \
        --time-size=$CLOCK_SIZE \
        --date-size=1 \
        --time-color="''${color3:1}" \
        --date-color="''${color7:1}" \
        --inside-color="''${color0:1}00" \
        --ring-color="''${color0:1}00" \
        --ringwrong-color="''${color0:1}00" \
        --line-color="''${color0:1}ff" \
        --separator-color="''${color0:1}00" \
        --keyhl-color="''${color3:1}ff" \
        --bshl-color="''${color0:1}ff" \
        --time-pos="$TIME_X:$IND_Y" \
        --date-pos="$DATE_X:$DATE_Y" \
        --indicator \
        --radius=50 \
        --ringver-color="''${color6:1}00" \
        --verif-text="$VERIFY_TEXT" \
        --verif-font="$FONT" \
        --verif-size=91 \
        --verif-color="$color3" \
        --verif-pos="$VERIF_X:$IND_Y" \
        --wrong-text="$WRONG_TEXT" \
        --wrong-pos="$WRONG_X:$IND_Y" \
        --wrong-font="$FONT" \
        --wrong-size=91 \
        --wrong-color="$color3" \
        --noinput-text="Err: no input" \
        --ind-pos="$IND_X:$IND_Y" \
        --bar-indicator \
        --bar-step=5 \
        --bar-max-height=5 \
        --bar-color="''${color0:1}00"

    # Cleanup temporary files (not the cache)
    rm -f /tmp/i3lock_screen.png /tmp/i3lock_blur.png /tmp/i3lock_text.png /tmp/i3lock_solid.png

    # After unlock: wake display (DPMS) to prevent black screen on resume
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true
  '';

  lockInstantScript = pkgs.writeShellScriptBin "lock-instant" ''
    # If i3lock is already running (manual lock), don't restart it
    if ${pkgs.procps}/bin/pgrep -x i3lock >/dev/null 2>&1; then
      exit 0
    fi

    # Source wal colors for theming
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      # Fallback colors if wal not initialized
      color0="#0c0c0c"
      color1="#bf616a"
      color3="#ebcb8b"
      color6="#8fbcbb"
      color7="#d8dee9"
    fi

    # Move cursor to bottom-right corner (out of the way)
    ${pkgs.xdotool}/bin/xdotool mousemove 9999 9999

    # Configuration (baked at build time from hydrix.graphical.lockscreen options)
    FONT="${cfg.lockscreen.font}"
    CLOCK_SIZE=${toString cfg.lockscreen.clockSize}
    WRONG_TEXT="${cfg.lockscreen.wrongText}"
    VERIFY_TEXT="${cfg.lockscreen.verifyText}"

    # Get screen dimensions dynamically (no hardcoded values)
    SCREEN_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep "dimensions:" | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+' | head -1)
    SCREEN_W=$(echo "$SCREEN_SIZE" | cut -dx -f1)
    SCREEN_H=$(echo "$SCREEN_SIZE" | cut -dx -f2)

    # Detect primary monitor position for correct element placement on multi-monitor setups
    PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected primary " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    [ -z "$PRIMARY_GEOM" ] && PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    MON_X=0; MON_Y=0
    if [ -n "$PRIMARY_GEOM" ]; then
      PRIM_W=$(echo "$PRIMARY_GEOM" | cut -dx -f1)
      PRIM_H=$(echo "$PRIMARY_GEOM" | cut -dx -f2 | cut -d+ -f1)
      MON_X=$(echo "$PRIMARY_GEOM" | cut -d+ -f2)
      MON_Y=$(echo "$PRIMARY_GEOM" | cut -d+ -f3)
    fi
    # Positions relative to primary monitor (indicator at ~60% across, ~45% down)
    IND_X=$((MON_X + PRIM_W * 60 / 100))
    IND_Y=$((MON_Y + PRIM_H * 45 / 100))
    TIME_X=$((MON_X + PRIM_W * 50 / 100))
    DATE_X=$((MON_X + PRIM_W * 50 / 100))
    DATE_Y=$((MON_Y + PRIM_H * 40 / 100))
    VERIF_X=$((MON_X + PRIM_W * 55 / 100))
    WRONG_X=$((MON_X + PRIM_W * 55 / 100))

    # Use solid background color matching actual screen resolution
    LOCK_IMG="/tmp/i3lock_solid.png"
    ${pkgs.imagemagick}/bin/magick -size "''${SCREEN_W}x''${SCREEN_H}" "xc:$color0" "$LOCK_IMG" 2>/dev/null || true

    # Run i3lock-color with solid background and built-in clock/indicator
    ${pkgs.i3lock-color}/bin/i3lock \
        -i "$LOCK_IMG" \
        --clock \
        --time-str="%H:%M:%S" \
        --date-str="%A, %Y-%m-%d" \
        --layout-font="$FONT" \
        --layout-size=26 \
        --time-font="$FONT" \
        --date-font="$FONT" \
        --time-size=$CLOCK_SIZE \
        --date-size=1 \
        --time-color="''${color3:1}" \
        --date-color="''${color7:1}" \
        --inside-color="''${color0:1}00" \
        --ring-color="''${color0:1}00" \
        --ringwrong-color="''${color0:1}00" \
        --line-color="''${color0:1}ff" \
        --separator-color="''${color0:1}00" \
        --keyhl-color="''${color3:1}ff" \
        --bshl-color="''${color0:1}ff" \
        --time-pos="$TIME_X:$IND_Y" \
        --date-pos="$DATE_X:$DATE_Y" \
        --indicator \
        --radius=50 \
        --ringver-color="''${color6:1}00" \
        --verif-text="$VERIFY_TEXT" \
        --verif-font="$FONT" \
        --verif-size=91 \
        --verif-color="$color3" \
        --verif-pos="$VERIF_X:$IND_Y" \
        --wrong-text="$WRONG_TEXT" \
        --wrong-pos="$WRONG_X:$IND_Y" \
        --wrong-font="$FONT" \
        --wrong-size=91 \
        --wrong-color="$color3" \
        --noinput-text="Err: no input" \
        --ind-pos="$IND_X:$IND_Y" \
        --bar-indicator \
        --bar-step=5 \
        --bar-max-height=5 \
        --bar-color="''${color0:1}00"

    # Cleanup temporary files
    rm -f "$LOCK_IMG"

    # After unlock: wake display (DPMS) to prevent black screen on resume
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true
  '';

  displayRecoverScript = pkgs.writeShellScriptBin "display-recover" ''
    #!/usr/bin/env bash
    # Emergency display recovery - forces DPMS, xrandr, picom, and i3 reload
    echo "Starting display recovery..."
    echo "[$(date)] Manual display recovery triggered" >> /tmp/suspend-debug.log

    # Save current gamma settings before reinitializing
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
    echo "  Forcing DPMS on..."
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true

    # Wait briefly
    sleep 0.5

    # Reinitialize displays
    echo "  Running xrandr --auto..."
    ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true
    sleep 0.5
    ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true

    # Restore gamma settings after reinitialization
    sleep 0.5
    if [ -f "$GAMMA_SAVE_FILE" ] && [ -s "$GAMMA_SAVE_FILE" ]; then
      while IFS='=' read -r monitor gamma; do
        if [ -n "$monitor" ] && [ -n "$gamma" ]; then
          ${pkgs.xorg.xrandr}/bin/xrandr --output "$monitor" --gamma "$gamma" 2>/dev/null || true
          echo "[$(date)] Restored gamma for $monitor: $gamma" >> /tmp/suspend-debug.log
        fi
      done < "$GAMMA_SAVE_FILE"
    fi

    # Restart picom (compositor)
    echo "  Restarting picom..."
    ${pkgs.procps}/bin/pkill -9 picom 2>/dev/null || true
    sleep 0.3
    ${pkgs.picom}/bin/picom --daemon 2>/dev/null || true

    # Reload i3
    echo "  Reloading i3..."
    ${pkgs.i3}/bin/i3-msg reload 2>/dev/null || true

    # Run display-setup if available (refreshes polybar, gaps)
    # Use --no-move to preserve workspace-to-monitor assignments
    if command -v display-setup >/dev/null 2>&1; then
      echo "  Running display-setup..."
      display-setup --no-move >/dev/null 2>&1 || true
    fi

    echo "Display recovery complete!"
    echo "[$(date)] Manual display recovery completed" >> /tmp/suspend-debug.log
  '';

  monitorRescanScript = pkgs.writeShellScriptBin "monitor-rescan" ''
    #!/usr/bin/env bash
    # Aggressive monitor rescan - for when hotplug doesn't detect a monitor
    LOG="/tmp/monitor-rescan.log"
    echo "=== Monitor Rescan - $(date) ===" | tee "$LOG"

    echo "Current state:" | tee -a "$LOG"
    ${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep -E "connected|disconnected" | tee -a "$LOG"

    echo "" | tee -a "$LOG"
    echo "Checking /sys/class/drm status files..." | tee -a "$LOG"
    for f in /sys/class/drm/card0-*/status; do
      name=$(basename $(dirname "$f"))
      status=$(cat "$f" 2>/dev/null || echo "N/A")
      echo "  $name: $status" | tee -a "$LOG"
    done

    echo "" | tee -a "$LOG"
    echo "Step 1: Force DPMS on" | tee -a "$LOG"
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true

    echo "Step 2: Probe outputs with xrandr --auto (3x with delays)" | tee -a "$LOG"
    for i in 1 2 3; do
      ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true
      sleep 1
    done

    echo "Step 3: Check for newly detected monitors" | tee -a "$LOG"
    NEW_STATE=$(${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep -E "connected|disconnected")
    echo "$NEW_STATE" | tee -a "$LOG"

    # Count external monitors
    EXT_COUNT=$(echo "$NEW_STATE" | grep " connected" | grep -v "eDP" | wc -l)

    if [ "$EXT_COUNT" -gt 0 ]; then
      echo "" | tee -a "$LOG"
      echo "Found $EXT_COUNT external monitor(s)! Running display-setup..." | tee -a "$LOG"
      display-setup 2>&1 | tee -a "$LOG"
      echo "Monitor rescan complete - external monitor(s) configured" | tee -a "$LOG"
    else
      echo "" | tee -a "$LOG"
      echo "No external monitors detected." | tee -a "$LOG"
      echo "If a monitor is physically connected but not showing:" | tee -a "$LOG"
      echo "  1. Check cable connection (try replugging)" | tee -a "$LOG"
      echo "  2. Try Ctrl+Alt+F2 then Ctrl+Alt+F1 (VT switch)" | tee -a "$LOG"
      echo "  3. Run 'xrandr --listmonitors' to see X's view" | tee -a "$LOG"
    fi
  '';
in {
  config = lib.mkIf (!isVM && config.hydrix.i3.enable) {
    environment.systemPackages = [
      lockScript
      lockInstantScript
      generateLockscreenScript
      displayRecoverScript
      monitorRescanScript
    ];

    home-manager.users.${username} = {...}: {
      # Post-resume display recovery (waits for i3lock to exit, then runs display-setup)
      systemd.user.services.post-resume-display = {
        Unit.Description = "Recover display after resume and unlock";
        Service = {
          Type = "oneshot";
          ExecStart = let
            script = pkgs.writeShellScript "post-resume-unlock" ''
              LOG="/tmp/suspend-debug.log"
              echo "[$(date)] User post-resume: waiting for unlock" >> "$LOG"

              # Wait for i3lock to exit (max 5 minutes)
              TIMEOUT=300
              COUNT=0
              while ${pkgs.procps}/bin/pgrep -x i3lock >/dev/null 2>&1; do
                sleep 1
                COUNT=$((COUNT + 1))
                if [ "$COUNT" -ge "$TIMEOUT" ]; then
                  echo "[$(date)] User post-resume: timeout waiting for unlock" >> "$LOG"
                  exit 0
                fi
              done

              echo "[$(date)] User post-resume: i3lock exited, running display-setup" >> "$LOG"

              if command -v display-setup >/dev/null 2>&1; then
                display-setup >/dev/null 2>&1 || true
              fi

              echo "[$(date)] User post-resume: complete" >> "$LOG"
            '';
          in "${script}";
          Environment = [
            "HOME=/home/${username}"
            "DISPLAY=:0"
          ];
        };
      };

      # Fires post-resume-display.service when /tmp/resume-trigger changes
      systemd.user.paths.post-resume-trigger = {
        Unit = {
          Description = "Watch for resume events (X11 only)";
          ConditionEnvironment = "!WAYLAND_DISPLAY";
        };
        Path = {
          PathChanged = "/tmp/resume-trigger";
          Unit = "post-resume-display.service";
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    };
  };
}
