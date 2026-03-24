# X Session Configuration Module
#
# Replaces:
# - configs/xorg/.xinitrc
# - scripts/autostart.sh (most of it - polybar startup moved to i3.nix)
# - scripts/vm-auto-resize.sh (converted to systemd user service)
#
# This module configures the X session startup sequence using Home Manager's
# xsession module, which integrates properly with i3.
#
# The startup sequence is:
# 1. profileExtra - runs before window manager (resolution, SPICE, xcape)
# 2. i3 starts
# 3. i3 startup commands run (polybar, dunst, etc.)

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType or "unknown";
  isVM = vmType != null && vmType != "host";
  defaultGaps = config.hydrix.graphical.ui.gaps;

  # Compositor animation mode
  animationMode = cfg.ui.compositor.animations;
  # Modern mode uses systemd service, don't start manually
  useSystemdPicom = animationMode == "modern";

  # Splash screen script (only used when splash.enable = true)
  splashScript = pkgs.writeShellScript "splash-cover" ''
    #!/usr/bin/env bash
    PID_FILE="/tmp/splash-cover.pid"
    FEH_PID_FILE="/tmp/splash-cover-feh.pid"
    LOG="/tmp/splash-cover.log"

    log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

    # Kill mode - restore original wallpaper
    if [ "$1" = "--kill" ]; then
        rm -f "$PID_FILE" "$FEH_PID_FILE" /tmp/splash-cover.png
        # Restore user's wallpaper (set by pywal/fehbg)
        if [ -f "$HOME/.fehbg" ]; then
            "$HOME/.fehbg" 2>/dev/null || true
        fi
        log "Splash killed, wallpaper restored"
        exit 0
    fi

    log "=== Splash starting ==="
    echo $$ > "$PID_FILE"

    # Colors from pywal or fallback
    if [ -f ~/.cache/wal/colors.json ]; then
        BG=$(${pkgs.jq}/bin/jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
        FG=$(${pkgs.jq}/bin/jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
        ACCENT=$(${pkgs.jq}/bin/jq -r '.colors.color4' ~/.cache/wal/colors.json)
    else
        BG="#0B0E1B"; FG="#91ded4"; ACCENT="#1C7787"
    fi

    # Resolution - use PRIMARY monitor's resolution (or largest if no primary)
    # Primary line looks like: "eDP-1 connected primary 1920x1200+0+1440"
    # Non-primary: "DP-1 connected 3440x1440+0+0"
    PRIMARY_LINE=$(${pkgs.xorg.xrandr}/bin/xrandr --query | grep " connected primary ")
    if [ -z "$PRIMARY_LINE" ]; then
        # No primary, use first connected with geometry
        PRIMARY_LINE=$(${pkgs.xorg.xrandr}/bin/xrandr --query | grep -E " connected [0-9]+x[0-9]+" | head -1)
    fi
    # Extract WxH from "connected [primary] WxH+X+Y"
    RES=$(echo "$PRIMARY_LINE" | grep -oP '\d+x\d+(?=\+)')
    WIDTH=$(echo "$RES" | cut -dx -f1)
    HEIGHT=$(echo "$RES" | cut -dx -f2)
    [ -z "$WIDTH" ] && WIDTH=1920
    [ -z "$HEIGHT" ] && HEIGHT=1080
    log "Primary monitor resolution: ''${WIDTH}x''${HEIGHT}"

    # Font sizes
    MAIN_SIZE=$((HEIGHT / 10))
    SUB_SIZE=$((HEIGHT / 30))
    FONT="${if cfg.splash.font != null then cfg.splash.font else "CozetteVector"}"

    # Generate splash with antialiasing
    ${pkgs.imagemagick}/bin/magick -size "''${WIDTH}x''${HEIGHT}" "xc:$BG" \
        -gravity center \
        -font "$FONT" -pointsize "$MAIN_SIZE" -fill "$FG" \
        -antialias \
        -annotate +0-50 "${cfg.splash.title}" \
        -font "$FONT" -pointsize "$SUB_SIZE" -fill "$ACCENT" \
        -antialias \
        -annotate +0+80 "${cfg.splash.text}" \
        -depth 8 \
        /tmp/splash-cover.png 2>>$LOG || { log "Failed to generate splash"; exit 1; }

    # Display as background (below polybar, not fullscreen override)
    # Use --no-fehbg to avoid overwriting user's fehbg
    ${pkgs.feh}/bin/feh --bg-center --no-fehbg /tmp/splash-cover.png
    log "Splash background set"

    # Safety timeout - restore wallpaper if display-setup hangs
    ( sleep ${toString cfg.splash.maxTimeout}; log "Safety timeout"; $0 --kill ) &

    # Keep script alive until killed (so safety timeout can run)
    while [ -f "$PID_FILE" ]; do sleep 1; done
    rm -f /tmp/splash-cover.png
  '';

  # VM auto-resize script - monitors SPICE resolution changes
  vmAutoResizeScript = pkgs.writeShellScript "vm-auto-resize" ''
    LOGFILE="/tmp/vm-auto-resize.log"
    exec >> "$LOGFILE" 2>&1

    LAST_RES=""
    OUTPUT="Virtual-1"

    echo "$(date '+%H:%M:%S') VM auto-resize monitor started"

    while true; do
      # Get current preferred resolution (marked with +)
      PREFERRED=$(${pkgs.xorg.xrandr}/bin/xrandr 2>/dev/null | grep -A1 "^$OUTPUT connected" | tail -1 | awk '{print $1}')

      # Get current active resolution (marked with *)
      CURRENT=$(${pkgs.xorg.xrandr}/bin/xrandr 2>/dev/null | grep -E "^\s+[0-9]+x[0-9]+.*\*" | head -1 | awk '{print $1}')

      # If preferred exists and differs from current, apply it
      if [ -n "$PREFERRED" ] && [ "$PREFERRED" != "$CURRENT" ] && [ "$PREFERRED" != "$LAST_RES" ]; then
        echo "$(date '+%H:%M:%S') Resolution change: $CURRENT -> $PREFERRED"
        ${pkgs.xorg.xrandr}/bin/xrandr --output "$OUTPUT" --mode "$PREFERRED" 2>/dev/null || \
        ${pkgs.xorg.xrandr}/bin/xrandr --output "$OUTPUT" --auto 2>/dev/null || true
        LAST_RES="$PREFERRED"

        # Reload polybar to adjust to new resolution
        sleep 0.5
        ${pkgs.procps}/bin/pkill polybar 2>/dev/null || true
        sleep 0.2
        ${pkgs.polybar}/bin/polybar vm-top 2>/dev/null &
        ${pkgs.polybar}/bin/polybar vm-bottom 2>/dev/null &
        disown
        echo "$(date '+%H:%M:%S') Restarted polybar (vm-top + vm-bottom)"
      fi

      sleep 0.5
    done
  '';

  # Supervisor script - restarts vm-auto-resize if it dies
  vmAutoResizeSupervisor = pkgs.writeShellScript "vm-auto-resize-supervisor" ''
    LOGFILE="/tmp/vm-auto-resize-supervisor.log"
    exec >> "$LOGFILE" 2>&1
    echo "$(date '+%H:%M:%S') Supervisor started"

    while true; do
      # Check if vm-auto-resize is running
      if ! ${pkgs.procps}/bin/pgrep -f "vm-auto-resize" >/dev/null 2>&1; then
        echo "$(date '+%H:%M:%S') vm-auto-resize not running, starting..."
        ${vmAutoResizeScript} &
        disown
      fi
      sleep 5
    done
  '';

  # Monitor detection script for workspace assignments
  detectMonitorsScript = pkgs.writeShellScript "detect-monitors" ''
    # Detect monitors for workspace output assignments
    INTERNAL_OUTPUT=""
    EXTERNAL_OUTPUT=""

    for i in 1 2 3 4 5 6; do
      INTERNAL_OUTPUT=$(${pkgs.xorg.xrandr}/bin/xrandr --query | grep "eDP" | grep " connected" | cut -d' ' -f1)
      EXTERNAL_OUTPUT=$(${pkgs.xorg.xrandr}/bin/xrandr --query | grep " connected" | grep -v "eDP" | grep -E "(DP-|HDMI-)" | cut -d' ' -f1 | head -n1)
      if [ -n "$EXTERNAL_OUTPUT" ]; then
        break
      fi
      sleep 0.5
    done

    # If no external monitor, use internal for all workspaces
    if [ -z "$EXTERNAL_OUTPUT" ]; then
      EXTERNAL_OUTPUT="$INTERNAL_OUTPUT"
    fi
    # If no internal (desktop?), use external for all
    if [ -z "$INTERNAL_OUTPUT" ]; then
      INTERNAL_OUTPUT="$EXTERNAL_OUTPUT"
    fi

    echo "INTERNAL_OUTPUT=$INTERNAL_OUTPUT"
    echo "EXTERNAL_OUTPUT=$EXTERNAL_OUTPUT"
  '';

in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, config, ... }: {
      # X session configuration
      xsession = {
        enable = true;

        # Profile script - runs BEFORE window manager starts
        # This handles resolution setup, SPICE agent, xcape, etc.
        profileExtra = ''
          # Clean old serverauth files
          find "$HOME" -maxdepth 1 -name ".serverauth.*" -type f -mtime +2 -delete 2>/dev/null

          # Read GDK scale from scaling.json for GTK apps (Firefox, virt-manager)
          SCALING_JSON="$HOME/.config/hydrix/scaling.json"
          if [ -f "$SCALING_JSON" ]; then
            GDK_SCALE_VALUE=$(${pkgs.jq}/bin/jq -r '.scale_factor // 1' "$SCALING_JSON" 2>/dev/null)
            if [ -n "$GDK_SCALE_VALUE" ] && [ "$GDK_SCALE_VALUE" != "null" ]; then
              export GDK_DPI_SCALE="$GDK_SCALE_VALUE"
            fi
          fi

          ${if isVM then ''
            # ===== VM-specific setup =====

            # Start SPICE agent for clipboard and resolution
            ${pkgs.spice-vdagent}/bin/spice-vdagent -x &

            # Wait for SPICE to initialize and set resolution
            sleep 2

            # Apply current preferred resolution
            VM_DISPLAY=$(${pkgs.xorg.xrandr}/bin/xrandr | grep -E "(Virtual-1|qxl-0)" | grep " connected" | cut -d' ' -f1 | head -n1)
            if [ -n "$VM_DISPLAY" ]; then
              ${pkgs.xorg.xrandr}/bin/xrandr --output "$VM_DISPLAY" --auto 2>/dev/null || true
            fi

            # Polybars are started by display-setup in initExtra
            # Start auto-resize supervisor (restarts vm-auto-resize if it dies)
            ${vmAutoResizeSupervisor} &
            disown

          '' else ''
            # ===== Host-specific setup =====

            # Set virt-manager grab key to Super_L
            ${pkgs.dconf}/bin/dconf write /org/virt-manager/virt-manager/console/grab-keys "'65515'" 2>/dev/null || true

            # xcape: Make Super_L release VM keyboard grab when tapped alone
            ${pkgs.procps}/bin/pkill -x xcape 2>/dev/null || true
            ${pkgs.xcape}/bin/xcape -e 'Super_L=Control_L|Alt_L' &
          ''}

          # Restore pywal colors for terminals (for experimentation)
          if command -v wal &>/dev/null && [ -f ~/.cache/wal/sequences ]; then
            cat ~/.cache/wal/sequences
          fi
        '';

        # Init script - runs AFTER profile but before WM
        initExtra = ''
          # Initialize gaps.json with defaults if not present
          GAP_FILE="$HOME/.config/hydrix/gaps.json"
          if [ ! -f "$GAP_FILE" ]; then
            mkdir -p "$(dirname "$GAP_FILE")"
            echo '{"inner": ${toString defaultGaps}, "outer": 0}' > "$GAP_FILE"
          fi

          # Unclutter - hide mouse when idle
          ${pkgs.unclutter}/bin/unclutter -grab &

          # Merge Xresources
          ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.Xresources 2>/dev/null || true

          # Merge pywal colors if available
          if [ -f ~/.cache/wal/colors.Xresources ]; then
            ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.cache/wal/colors.Xresources
          fi

          # Apply xmodmap if exists
          if [ -f ~/.Xmodmap ]; then
            sleep 2 && ${pkgs.xorg.xmodmap}/bin/xmodmap ~/.Xmodmap &
          fi

          ${if !isVM && !useSystemdPicom then ''
          # Start picom compositor (host only - VMs use SPICE compositing)
          # Start manually here for reliability with startx sessions
          # (systemd user service can stop when graphical-session.target ends)
          # Note: Modern animation mode uses systemd service instead
          ${pkgs.procps}/bin/pkill -x picom 2>/dev/null || true
          sleep 0.2
          ${pkgs.picom}/bin/picom -b &
          '' else ""}

          ${if !isVM then ''
          # Pre-attach to any running VMs for instant first app launch
          # Run in background after a delay to give VMs time to fully boot
          (sleep 3 && xpra-preattach) &
          '' else ""}

          ${lib.optionalString cfg.splash.enable ''
          # Start splash BEFORE visual setup (login only - hotplug doesn't run xsession)
          splash-cover &
          ''}

          # Start polybar and dunst with DPI-aware configuration
          # This runs after xrdb has merged colors, so polybar can read them
          sleep 1
          (
            display-setup  # This is synchronous - completes when setup is done
            ${lib.optionalString cfg.splash.enable ''
            # Kill splash immediately after setup completes (not a fixed timeout)
            splash-cover --kill
            ''}
          ) &
        '';
      };

      # Deploy Xmodmap for key remapping
      home.file.".Xmodmap" = lib.mkIf (!isVM && cfg.keyboard.xmodmap != "") {
        text = cfg.keyboard.xmodmap;
      };

      # Xresources is managed by Stylix - don't create our own .Xresources
      # Cursor settings are configured via pointerCursor below
      # Font rendering is handled by fontconfig

      # Cursor theme (this integrates with Stylix rather than using .Xresources)
      home.pointerCursor = {
        name = "Vanilla-DMZ";
        package = pkgs.vanilla-dmz;
        size = 24;
        x11.enable = true;
        gtk.enable = true;
      };

      # Create .xinitrc that runs .xsession (startx looks for .xinitrc, not .xsession)
      home.file.".xinitrc" = {
        executable = true;
        text = ''
          #!/bin/sh
          # startx wrapper - runs the home-manager xsession
          exec ~/.xsession
        '';
      };
    };

    # Ensure required packages are available system-wide for scripts
    environment.systemPackages = with pkgs; [
      xorg.xrandr
      xorg.xrdb
      xorg.xmodmap
      procps
      unclutter
      jq  # For reading scaling.json in profileExtra
    ] ++ lib.optionals (!isVM) [
      xcape
      dconf
    ] ++ lib.optionals isVM [
      spice-vdagent
    ] ++ lib.optionals cfg.splash.enable [
      (pkgs.runCommand "splash-cover" {} ''
        mkdir -p $out/bin
        cp ${splashScript} $out/bin/splash-cover
        chmod +x $out/bin/splash-cover
      '')
      imagemagick
      xdotool
    ];

    # Enable SPICE agent service for VMs
    services.spice-vdagentd.enable = lib.mkIf isVM true;
  };
}
