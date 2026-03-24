# Runtime DPI-Aware Display Configuration
#
# Provides a display-setup script that:
# - Reads scaling values from ~/.config/hydrix/scaling.json (if dynamic scaling enabled)
# - Falls back to per-monitor DPI calculation otherwise
# - Launches polybar with appropriate font/height
#
# With dynamic scaling enabled, hardware is normalized so all monitors have
# effectively the same DPI. Same font sizes work everywhere.
#
# Usage:
#   display-setup           - Restart polybar with scaled configs
#
# Also regenerates dunst config from scaling.json so notifications track polybar position

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType or null;
  isVM = vmType != null && vmType != "host";

  # Check if dynamic scaling is enabled
  dynamicScalingEnabled = cfg.dynamicScaling.enable or false;

  # Check if floating bar is enabled
  floatingBar = cfg.ui.floatingBar;

  # Check if bottom bar is enabled
  bottomBar = cfg.ui.bottomBar;

  # Get base values from unified options
  ui = cfg.ui;

  # Font configuration from unified options
  fontName = cfg.font.family;
  polybarFontName = cfg.font.familyOverrides.polybar or "";

  # Base font size at 96 DPI (fallback values)
  basePolybarFont = 7;

  # Full paths for utilities
  xrandr = "${pkgs.xorg.xrandr}/bin/xrandr";
  grep = "${pkgs.gnugrep}/bin/grep";
  sed = "${pkgs.gnused}/bin/sed";
  cut = "${pkgs.coreutils}/bin/cut";
  head = "${pkgs.coreutils}/bin/head";
  killall = "${pkgs.killall}/bin/killall";
  timeout = "${pkgs.coreutils}/bin/timeout";
  sleep = "${pkgs.coreutils}/bin/sleep";
  date = "${pkgs.coreutils}/bin/date";
  jq = "${pkgs.jq}/bin/jq";
  i3msg = "${pkgs.i3}/bin/i3-msg";
  polybarPkg = pkgs.polybar.override { i3Support = true; pulseSupport = true; };
  polybar = "${polybarPkg}/bin/polybar";
  polybarMsg = "${polybarPkg}/bin/polybar-msg";
  xrdb = "${pkgs.xorg.xrdb}/bin/xrdb";
  awk = "${pkgs.gawk}/bin/awk";

  # The main display-setup script
  displaySetupScript = pkgs.writeShellScript "display-setup" ''
    #!/usr/bin/env bash
    # display-setup - Runtime polybar configuration
    #
    # With dynamic scaling: reads from scaling.json (same values for all monitors)
    # Without: calculates per-monitor DPI
    #
    # Usage:
    #   display-setup              - Auto-detect and apply optimal resolution
    #   display-setup --step -1    - Use one step higher resolution than optimal
    #   display-setup --step +1    - Use one step lower resolution than optimal

    # Step persistence file
    STEP_FILE="/tmp/display-step"
    # Monitor order config file
    MONITOR_ORDER_FILE="$HOME/.config/hydrix/monitor-order.conf"

    # Parse arguments
    STEP_ARG=""
    FORCE_RECOVER=""
    REVERSE_MONITORS_FLAG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --step)
                STEP_ARG="--step $2"
                # Persist the step value
                echo "$2" > "$STEP_FILE"
                shift 2
                ;;
            --reset-step)
                # Clear persisted step
                rm -f "$STEP_FILE"
                shift
                ;;
            --reverse-monitors)
                # Toggle monitor order
                REVERSE_MONITORS_FLAG="toggle"
                shift
                ;;
            --recover)
                # Force recovery: move all workspaces from external monitors to internal
                FORCE_RECOVER="--force"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: display-setup [--step N] [--reset-step] [--reverse-monitors] [--recover]"
                exit 1
                ;;
        esac
    done

    # Load or initialize monitor order preference
    REVERSE_MONITORS=false
    if [ -f "$MONITOR_ORDER_FILE" ]; then
        REVERSE_MONITORS=$(cat "$MONITOR_ORDER_FILE")
    fi

    # Handle --reverse-monitors flag: toggle the saved preference
    if [ "$REVERSE_MONITORS_FLAG" = "toggle" ]; then
        if [ "$REVERSE_MONITORS" = "true" ]; then
            REVERSE_MONITORS=false
        else
            REVERSE_MONITORS=true
        fi
        mkdir -p "$(dirname "$MONITOR_ORDER_FILE")"
        echo "$REVERSE_MONITORS" > "$MONITOR_ORDER_FILE"
        echo "$(${date}): Monitor order toggled to: $REVERSE_MONITORS" | tee -a "$LOG"
    fi

    # If no --step provided, use persisted value if exists
    if [[ -z "$STEP_ARG" && -f "$STEP_FILE" ]]; then
        PERSISTED_STEP=$(cat "$STEP_FILE")
        if [[ -n "$PERSISTED_STEP" ]]; then
            STEP_ARG="--step $PERSISTED_STEP"
        fi
    fi

    LOG="/tmp/display-setup.log"
    echo "$(${date}): display-setup started (step: ''${STEP_ARG:-auto})" | tee -a "$LOG"

    # Scaling state file locations (check multiple paths for VM compatibility)
    SCALING_JSON="$HOME/.config/hydrix/scaling.json"
    SCALING_JSON_VM="/mnt/hydrix-config/scaling.json"

    # Fallback base values at 96 DPI
    BASE_FONT=${toString basePolybarFont}
    BASE_BAR_HEIGHT=${toString ui.barHeight}
    BASE_CORNER_RADIUS=${toString ui.cornerRadius}
    FONT_NAME="${fontName}"
    FONT_NAME_POLYBAR="${polybarFontName}"

    # Configured internal resolution for standalone mode
    INTERNAL_RES="${if cfg.scaling.internalResolution != null then cfg.scaling.internalResolution else ""}"

    # Path to template config (generated by Nix)
    POLYBAR_TEMPLATE="$HOME/.config/polybar/config-template.ini"

    # --- Read from scaling.json if available ---
    read_scaling_json() {
        local json_path=""

        # Check primary path first, then VM mount fallback
        if [ -f "$SCALING_JSON" ]; then
            json_path="$SCALING_JSON"
        elif [ -f "$SCALING_JSON_VM" ]; then
            json_path="$SCALING_JSON_VM"
        fi

        if [ -n "$json_path" ]; then
            echo "$(${date}): Reading from $json_path" >> "$LOG"
            FONT_SIZE=$(${jq} -r '.fonts.polybar // empty' "$json_path" 2>/dev/null)
            BAR_HEIGHT=$(${jq} -r '.sizes.bar_height // empty' "$json_path" 2>/dev/null)
            CORNER_RADIUS=$(${jq} -r '.sizes.corner_radius // empty' "$json_path" 2>/dev/null)
            GAPS=$(${jq} -r '.sizes.gaps // empty' "$json_path" 2>/dev/null)
            OUTER_GAPS=$(${jq} -r '.sizes.outer_gaps // empty' "$json_path" 2>/dev/null)
            BAR_GAPS=$(${jq} -r '.sizes.bar_gaps // empty' "$json_path" 2>/dev/null)
            FONT_NAME_JSON=$(${jq} -r '.font_name // empty' "$json_path" 2>/dev/null)
            BAR_EDGE_GAPS=$(${jq} -r '.sizes.bar_edge_gaps // empty' "$json_path" 2>/dev/null)
            OVERLAY_ALPHA=$(${jq} -r '.sizes.overlay_alpha_hex // "D9"' "$json_path" 2>/dev/null)
            FONT_OFFSET=$(${jq} -r '.sizes.font_offset // empty' "$json_path" 2>/dev/null)
            FONT_NAME_POLYBAR_JSON=$(${jq} -r '.font_names.polybar // empty' "$json_path" 2>/dev/null)

            if [ -n "$FONT_SIZE" ] && [ -n "$BAR_HEIGHT" ]; then
                echo "$(${date}): Using scaling.json: font=$FONT_SIZE height=$BAR_HEIGHT gaps=$GAPS outer_gaps=$OUTER_GAPS bar_gaps=$BAR_GAPS bar_edge_gaps=$BAR_EDGE_GAPS" >> "$LOG"
                DYNAMIC_SCALING=true
                [ -n "$FONT_NAME_JSON" ] && FONT_NAME="$FONT_NAME_JSON"
                [ -z "$GAPS" ] && GAPS=8  # Fallback
                [ -z "$OUTER_GAPS" ] && OUTER_GAPS=0  # Fallback
                [ -z "$BAR_GAPS" ] && BAR_GAPS=$GAPS  # Fall back to GAPS
                [ -z "$BAR_EDGE_GAPS" ] && BAR_EDGE_GAPS=$BAR_GAPS  # Fall back to BAR_GAPS
                [ -z "$CORNER_RADIUS" ] && CORNER_RADIUS=${toString ui.cornerRadius}
                [ -n "$FONT_NAME_POLYBAR_JSON" ] && FONT_NAME_POLYBAR="$FONT_NAME_POLYBAR_JSON"
                [ -z "$FONT_OFFSET" ] && FONT_OFFSET=3
                DOUBLE_GAPS=$((GAPS * 2))
                DOUBLE_BAR_GAPS=$((BAR_GAPS * 2))
                DOUBLE_BAR_EDGE_GAPS=$((BAR_EDGE_GAPS * 2))
                return 0
            fi
        fi
        echo "$(${date}): No scaling.json or invalid data, using fallback" >> "$LOG"
        DYNAMIC_SCALING=false
        FONT_OFFSET=3
        return 1
    }

    # Get DPI for a specific monitor (fallback method)
    get_monitor_dpi() {
        local monitor="$1"
        local info=$(${xrandr} --query | ${grep} "^$monitor connected")
        local resolution=$(echo "$info" | ${grep} -oP '\d+x\d+' | ${head} -1)
        local width_px=$(echo "$resolution" | ${cut} -dx -f1)
        local width_mm=$(echo "$info" | ${grep} -oP '\d+mm' | ${head} -1 | ${sed} 's/mm//')

        if [ -n "$width_mm" ] && [ "$width_mm" -gt 0 ] && [ -n "$width_px" ]; then
            echo $(( width_px * 254 / width_mm / 10 ))
        else
            echo 96
        fi
    }

    # Scale a base value by DPI (fallback method)
    scale() {
        local base=$1 dpi=$2
        echo $(( base * dpi / 96 ))
    }

    # --- MONITOR POSITIONING & RESOLUTION ---
    # Applies resolution from scaling.json (if exists) without recalculating scaling values
    position_monitors() {
        local internal=$(${xrandr} --query | ${grep} "eDP" | ${cut} -d' ' -f1 | ${head} -1 || true)
        local externals=$(${xrandr} --query | ${grep} " connected" | ${grep} -v "eDP" | ${cut} -d' ' -f1 || true)

        # CRITICAL: Turn off disconnected monitors that still have a mode assigned
        # This is needed for i3 to release workspaces from those outputs
        # Pattern: "HDMI-1 disconnected 2560x1440+0+0" means it's disconnected but still "on"
        local stale_outputs=$(${xrandr} --query | ${grep} -E "^[A-Za-z0-9-]+ disconnected [0-9]+x[0-9]+" | ${cut} -d' ' -f1 || true)
        for stale in $stale_outputs; do
            echo "$(${date}): Turning off stale output $stale (disconnected but had mode)" | tee -a "$LOG"
            ${xrandr} --output "$stale" --off 2>/dev/null || true
        done

        if [ -n "$internal" ]; then
            if [ -n "$externals" ]; then
                # External connected: apply optimal internal resolution from scaling.json
                local optimal_res=""
                if [ -f "$SCALING_JSON" ]; then
                    optimal_res=$(${jq} -r '.monitors.optimal_internal_res // empty' "$SCALING_JSON" 2>/dev/null)
                    [ "$optimal_res" = "null" ] && optimal_res=""
                fi

                if [ -n "$optimal_res" ]; then
                    echo "$(${date}): Setting $internal to $optimal_res (DPI-matched)" | tee -a "$LOG"
                    ${xrandr} --output "$internal" --mode "$optimal_res" 2>/dev/null || true
                fi

                # Position externals side-by-side above internal
                local ext_array=($externals)
                local ext_count=''${#ext_array[@]}

                if [ "$ext_count" -eq 1 ]; then
                    # Single external: simple positioning above internal
                    echo "$(${date}): Positioning ''${ext_array[0]} above $internal" | tee -a "$LOG"
                    ${xrandr} --output "$internal" --primary \
                              --output "''${ext_array[0]}" --auto --above "$internal" 2>/dev/null || true
                else
                    # Multiple externals: position side-by-side above internal
                    local ext_order=("''${ext_array[@]}")

                    # Optionally reverse the array to flip left-right positioning
                    if [ "$REVERSE_MONITORS" = "true" ]; then
                        echo "$(${date}): Reversing monitor order" | tee -a "$LOG"
                        local reversed_array=()
                        for ((i=''${#ext_array[@]}-1; i>=0; i--)); do
                            reversed_array+=("''${ext_array[i]}")
                        done
                        ext_order=("''${reversed_array[@]}")
                    fi

                    local prev_ext=""
                    for ext in ''${ext_order[@]}; do
                        if [ -z "$prev_ext" ]; then
                            echo "$(${date}): Positioning $ext above $internal (first external)" | tee -a "$LOG"
                            ${xrandr} --output "$ext" --auto --above "$internal" 2>/dev/null || true
                        else
                            echo "$(${date}): Positioning $ext right-of $prev_ext" | tee -a "$LOG"
                            ${xrandr} --output "$ext" --auto --right-of "$prev_ext" 2>/dev/null || true
                        fi
                        prev_ext="$ext"
                    done
                    # Set internal as primary last
                    ${xrandr} --output "$internal" --primary 2>/dev/null || true
                fi
            else
                # No external: apply configured standalone resolution
                if [ -n "$INTERNAL_RES" ]; then
                    echo "$(${date}): Setting $internal to $INTERNAL_RES (standalone mode)" | tee -a "$LOG"
                    ${xrandr} --output "$internal" --mode "$INTERNAL_RES" 2>/dev/null || true
                fi
            fi
        fi
        ${sleep} 0.3
    }

    # --- WORKSPACE RECOVERY ---
    # Move workspaces from disconnected/inactive monitors to a connected output
    # Force mode: recover_workspaces --force moves ALL external workspaces to internal
    # Uses i3's own output information to ensure consistency with workspace assignments
    recover_workspaces() {
        local force_internal=false
        [ "$1" = "--force" ] && force_internal=true

        echo "$(${date}): Checking for orphaned workspaces (force=$force_internal)..." >> "$LOG"

        # Use i3's own output list - this is the authoritative source for workspace assignment
        # Retry a few times if no outputs found (i3 may be in transition state)
        local active=""
        local retries=3
        while [ $retries -gt 0 ] && [ -z "$active" ]; do
            active=$(${timeout} 2 ${i3msg} -t get_outputs 2>/dev/null | ${jq} -r '.[] | select(.active == true) | .name' 2>/dev/null || true)
            if [ -z "$active" ]; then
                echo "$(${date}): No active outputs from i3, retrying... ($retries left)" >> "$LOG"
                ${sleep} 0.5
                retries=$((retries - 1))
            fi
        done

        echo "$(${date}): i3 active outputs: $(echo $active | tr '\n' ' ')" >> "$LOG"

        # Target is always internal (eDP) for recovery
        local target=$(echo "$active" | ${grep} "eDP" | ${head} -1)
        [ -z "$target" ] && target=$(echo "$active" | ${head} -1)

        [ -z "$target" ] && { echo "$(${date}): No active output found for recovery" >> "$LOG"; return; }

        # Save current workspace to restore focus after moving
        local current_ws
        current_ws=$(${timeout} 2 ${i3msg} -t get_workspaces 2>/dev/null | ${jq} -r '.[] | select(.focused==true) | .name' || echo "")

        # Move workspaces from inactive/disconnected outputs
        # With --force, also move from any non-eDP output
        # Use timeout to prevent hanging if i3 is busy during hotplug
        ${timeout} 5 ${i3msg} -t get_workspaces 2>/dev/null | ${jq} -r '.[] | "\(.name)|\(.output)"' 2>/dev/null | while IFS='|' read ws output; do
            local should_move=false

            if ! echo "$active" | ${grep} -q "^$output$"; then
                should_move=true  # Output not active according to i3
                echo "$(${date}): Workspace $ws on inactive output $output" >> "$LOG"
            elif [ "$force_internal" = "true" ] && ! echo "$output" | ${grep} -q "eDP"; then
                should_move=true  # Force mode: move all external to internal
            fi

            if [ "$should_move" = "true" ]; then
                echo "$(${date}): Moving workspace $ws from $output to $target" >> "$LOG"
                ${timeout} 5 ${i3msg} "workspace $ws; move workspace to output $target" >> "$LOG" 2>&1 || true
            fi
        done

        # Restore original workspace focus
        if [ -n "$current_ws" ]; then
            ${timeout} 2 ${i3msg} "workspace $current_ws" >> "$LOG" 2>&1 || true
            echo "$(${date}): Restored workspace focus: $current_ws" >> "$LOG"
        fi
    }

    # --- PICOM ---
    restart_picom() {
        ${if !isVM then ''
        echo "$(${date}): Restarting picom..." >> "$LOG"
        if command -v systemctl >/dev/null; then
            systemctl --user restart picom.service 2>/dev/null || true
        else
            ${killall} picom 2>/dev/null || true
            ${pkgs.picom}/bin/picom -b 2>/dev/null || true
        fi
        '' else ''
        # Picom disabled in VMs
        true
        ''}
    }

    # --- POLYBAR ---
    restart_polybar() {
        # Clean up stale IPC files from old polybar instances to prevent hangs
        for f in /tmp/polybar_mqueue.*; do
            [ -e "$f" ] || continue
            pid="''${f##*.}"
            if ! kill -0 "$pid" 2>/dev/null; then
                rm -f "$f"
            fi
        done
        for f in /run/user/$(id -u)/polybar/ipc.*.sock; do
            [ -e "$f" ] || continue
            pid=$(echo "$f" | ${sed} -n 's/.*ipc\.\([0-9]*\)\.sock/\1/p')
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                rm -f "$f"
            fi
        done

        # Save old polybar PIDs for graceful replacement (kill after new ones start)
        local old_pids=$(${pkgs.procps}/bin/pgrep polybar 2>/dev/null || true)
        echo "$(${date}): Old polybar PIDs: $old_pids" >> "$LOG"

        ${if isVM then ''
        # VM mode: use 96 DPI fallback or scaling.json if available
        local dpi=96
        local font_size
        local bar_height
        local corner_radius

        if [ "$DYNAMIC_SCALING" = "true" ]; then
            font_size=$FONT_SIZE
            bar_height=$BAR_HEIGHT
            corner_radius=$CORNER_RADIUS
        else
            font_size=$(scale $BASE_FONT $dpi)
            bar_height=$(scale $BASE_BAR_HEIGHT $dpi)
            corner_radius=$(scale $BASE_CORNER_RADIUS $dpi)
        fi

        # Minimums
        [ "$font_size" -lt 10 ] && font_size=10
        [ "$bar_height" -lt 1 ] && bar_height=1

        local polybar_font="''${FONT_NAME_POLYBAR:-$FONT_NAME}"
        echo "$(${date}): VM mode - Font=$font_size Height=$bar_height Radius=$corner_radius FontName=$polybar_font" >> "$LOG"

        if [ -f "$POLYBAR_TEMPLATE" ]; then
            local bar_gaps=''${BAR_GAPS:-''${GAPS:-8}}
            local double_bar_gaps=$((bar_gaps * 2))
            local overlay_alpha=''${OVERLAY_ALPHA:-D9}
            local font_offset=''${FONT_OFFSET:-3}
            # Get background color from xrdb (color0), strip the # prefix
            local bg_color
            bg_color=$(${xrdb} -query 2>/dev/null | ${grep} -E '^\*\.?color0:' | head -1 | ${awk} '{print $2}' | ${sed} 's/^#//')
            bg_color=''${bg_color:-101116}
            ${sed} \
                -e "s/@@FONT_SIZE@@/$font_size/g" \
                -e "s/@@BAR_HEIGHT@@/$bar_height/g" \
                -e "s/@@CORNER_RADIUS@@/$corner_radius/g" \
                -e "s/@@FONT_NAME@@/$polybar_font/g" \
                -e "s/@@FONT_OFFSET@@/$font_offset/g" \
                -e "s/@@GAPS@@/$bar_gaps/g" \
                -e "s/@@DOUBLE_GAPS@@/$double_bar_gaps/g" \
                -e "s/@@OVERLAY_ALPHA@@/$overlay_alpha/g" \
                -e "s/@@BG_COLOR@@/$bg_color/g" \
                "$POLYBAR_TEMPLATE" > /tmp/polybar-runtime.ini

            # VM bars: spacers reserve i3 space, floating bar shows content
            ${polybar} -c /tmp/polybar-runtime.ini vm-top-spacer >> "$LOG" 2>&1 &
            ${polybar} -c /tmp/polybar-runtime.ini vm-bottom-spacer >> "$LOG" 2>&1 &
            ${polybar} -c /tmp/polybar-runtime.ini vm-bottom >> "$LOG" 2>&1 &

            # Brief pause for new bars to initialize, then kill old ones
            ${sleep} 0.1
            if [ -n "$old_pids" ]; then
                echo "$(${date}): Killing old polybars: $old_pids" >> "$LOG"
                echo "$old_pids" | xargs -r kill 2>/dev/null || true
            fi
        else
            echo "$(${date}): ERROR: Polybar template not found" >> "$LOG"
        fi
        '' else ''
        # Host mode - single unified config for all monitors (DPI normalized)
        echo "$(${date}): Host mode - getting monitors..." >> "$LOG"
        local monitors=$(${xrandr} --query | ${grep} -E " connected (primary )?[0-9]+" | ${cut} -d' ' -f1)
        echo "$(${date}): Found monitors: $monitors" >> "$LOG"

        # Use unified scaling values (same for all monitors)
        local font_size=$FONT_SIZE
        local bar_height=$BAR_HEIGHT
        local corner_radius=$CORNER_RADIUS

        # Defaults if variables are empty (fallback)
        [ -z "$font_size" ] && font_size=$BASE_FONT
        [ -z "$bar_height" ] && bar_height=$BASE_BAR_HEIGHT
        [ -z "$corner_radius" ] && corner_radius=$BASE_CORNER_RADIUS

        # Minimums
        [ "$font_size" -lt 10 ] && font_size=10
        [ "$bar_height" -lt 1 ] && bar_height=1

        local polybar_font="''${FONT_NAME_POLYBAR:-$FONT_NAME}"
        # BAR_GAPS = polybar margins, GAPS = i3 window gaps
        local bar_gaps=''${BAR_GAPS:-''${GAPS:-8}}
        local double_bar_gaps=$((bar_gaps * 2))

        echo "$(${date}): Unified config - Font=$font_size Height=$bar_height Radius=$corner_radius FontName=$polybar_font" >> "$LOG"

        # Update i3 config FIRST, before launching polybar
        local inner_gaps=''${GAPS:-25}
        local outer_gaps=''${OUTER_GAPS:-0}
        local i3_config="$HOME/.config/i3/config"
        if [ -f "$i3_config" ]; then
            ${pkgs.gnused}/bin/sed -i "s/^gaps inner .*/gaps inner $inner_gaps/" "$i3_config"
            ${pkgs.gnused}/bin/sed -i "s/^gaps outer .*/gaps outer $outer_gaps/" "$i3_config"
            echo "$(${date}): Updated i3 config: gaps inner=$inner_gaps outer=$outer_gaps" >> "$LOG"
            ${lib.optionalString floatingBar ''
            # Bar has gap on all sides, windows start immediately after bar (no extra gap)
            # i3 top gap = bar_edge_gaps (above bar, adjustable via barEdgeGapsFactor) + bar_height
            local bar_edge=''${BAR_EDGE_GAPS:-$bar_gaps}
            local top_gap=$((bar_edge + bar_height))
            ${pkgs.gnused}/bin/sed -i "s/^gaps top .*/gaps top $top_gap/" "$i3_config"
            echo "$(${date}): Updated i3 config: gaps top=$top_gap (bar_edge=$bar_edge)" >> "$LOG"
            ''}
            ${lib.optionalString (floatingBar && bottomBar) ''
            local bar_edge=''${BAR_EDGE_GAPS:-$bar_gaps}
            local bottom_gap=$((bar_edge + bar_height))
            ${pkgs.gnused}/bin/sed -i "s/^gaps bottom .*/gaps bottom $bottom_gap/" "$i3_config"
            echo "$(${date}): Updated i3 config: gaps bottom=$bottom_gap" >> "$LOG"
            ''}
            ${lib.optionalString (floatingBar && !bottomBar) ''
            ${pkgs.gnused}/bin/sed -i "s/^gaps bottom .*/gaps bottom 0/" "$i3_config"
            echo "$(${date}): Updated i3 config: gaps bottom=0 (bottom bar disabled)" >> "$LOG"
            ''}
        fi

        # Save current workspace before reload (to restore focus after)
        local current_ws
        current_ws=$(${timeout} 2 ${i3msg} -t get_workspaces 2>/dev/null | ${jq} -r '.[] | select(.focused==true) | .name' || echo "")
        echo "$(${date}): Current workspace: $current_ws" >> "$LOG"

        ${timeout} 5 ${i3msg} reload >> "$LOG" 2>&1 || true
        ${sleep} 0.3

        # Restore workspace focus
        if [ -n "$current_ws" ]; then
            ${timeout} 2 ${i3msg} "workspace $current_ws" >> "$LOG" 2>&1 || true
            echo "$(${date}): Restored workspace: $current_ws" >> "$LOG"
        fi

        # Now launch polybar after i3 has reloaded
        if [ -f "$POLYBAR_TEMPLATE" ]; then
            # Generate single config used by all monitors
            local bar_edge_gaps=''${BAR_EDGE_GAPS:-$bar_gaps}
            local double_bar_edge_gaps=$((bar_edge_gaps * 2))
            local outer=''${OUTER_GAPS:-0}
            local double_outer=$((outer * 2))
            local overlay_alpha=''${OVERLAY_ALPHA:-D9}
            local font_offset=''${FONT_OFFSET:-3}
            # Get background color from xrdb (color0), strip the # prefix
            local bg_color
            bg_color=$(${xrdb} -query 2>/dev/null | ${grep} -E '^\*\.?color0:' | head -1 | ${awk} '{print $2}' | ${sed} 's/^#//')
            bg_color=''${bg_color:-101116}
            ${sed} \
                -e "s/@@FONT_SIZE@@/$font_size/g" \
                -e "s/@@BAR_HEIGHT@@/$bar_height/g" \
                -e "s/@@CORNER_RADIUS@@/$corner_radius/g" \
                -e "s/@@FONT_NAME@@/$polybar_font/g" \
                -e "s/@@FONT_OFFSET@@/$font_offset/g" \
                -e "s/@@GAPS@@/$bar_gaps/g" \
                -e "s/@@DOUBLE_GAPS@@/$double_bar_gaps/g" \
                -e "s/@@BAR_EDGE_GAPS@@/$bar_edge_gaps/g" \
                -e "s/@@DOUBLE_BAR_EDGE_GAPS@@/$double_bar_edge_gaps/g" \
                -e "s/@@OUTER_GAPS@@/$outer/g" \
                -e "s/@@DOUBLE_OUTER_GAPS@@/$double_outer/g" \
                -e "s/@@OVERLAY_ALPHA@@/$overlay_alpha/g" \
                -e "s/@@BG_COLOR@@/$bg_color/g" \
                "$POLYBAR_TEMPLATE" > /tmp/polybar-unified.ini

            # Launch polybar on each monitor
            for monitor in $monitors; do
                echo "$(${date}): Launching polybar on $monitor (main${if bottomBar then " + bottom" else ""})" >> "$LOG"
                MONITOR=$monitor ${polybar} -c /tmp/polybar-unified.ini main >> "$LOG" 2>&1 &
                ${if bottomBar then ''
                MONITOR=$monitor ${polybar} -c /tmp/polybar-unified.ini bottom >> "$LOG" 2>&1 &
                '' else ""}
            done

            # Brief pause for new bars to initialize, then kill old ones
            ${sleep} 0.1
            if [ -n "$old_pids" ]; then
                echo "$(${date}): Killing old polybars: $old_pids" >> "$LOG"
                echo "$old_pids" | xargs -r kill 2>/dev/null || true
            fi

            # Wait for polybar to be ready (for splash screen timing)
            # This ensures the splash isn't killed before bars are visible
            echo "$(${date}): Waiting for polybar to be ready..." >> "$LOG"
            local wait_count=0
            local max_wait=20  # 2 seconds max to detect process
            while [ $wait_count -lt $max_wait ]; do
                if ${pkgs.procps}/bin/pgrep -x polybar >/dev/null 2>&1; then
                    echo "$(${date}): Polybar process detected after $((wait_count * 100))ms" >> "$LOG"
                    # Additional wait for X window creation and first render
                    ${sleep} 0.3
                    echo "$(${date}): Polybar render wait complete" >> "$LOG"
                    break
                fi
                ${sleep} 0.1
                wait_count=$((wait_count + 1))
            done
            if [ $wait_count -ge $max_wait ]; then
                echo "$(${date}): WARNING: Timeout waiting for polybar process" >> "$LOG"
            fi
        else
            echo "$(${date}): ERROR: Polybar template not found" >> "$LOG"
        fi
        ''}

        disown 2>/dev/null || true
    }

    # --- MAIN ---
    # First, recalculate scaling values for current monitor configuration
    # This ensures font sizes are correct whether external is connected or not
    if command -v hydrix-scale >/dev/null 2>&1; then
        echo "$(${date}): Recalculating scaling values... $STEP_ARG" >> "$LOG"
        hydrix-scale --apply $STEP_ARG 2>&1 | tee -a "$LOG"
    fi

    read_scaling_json  # Read recalculated scaling values
    position_monitors
    recover_workspaces $FORCE_RECOVER
    restart_polybar
    # Note: picom restart removed - causes visual flicker and picom
    # handles monitor changes automatically via X events

    # Regenerate dunst config and restart to pick up new gaps/scaling
    echo "$(${date}): Regenerating dunst config..." >> "$LOG"
    if command -v generate-dunstrc >/dev/null 2>&1; then
        generate-dunstrc
        # Restart dunst to apply new config
        ${pkgs.procps}/bin/pkill -9 dunst 2>/dev/null || true
        ${sleep} 0.2
        if systemctl --user is-enabled dunst.service &>/dev/null; then
            systemctl --user start dunst 2>/dev/null || ${pkgs.dunst}/bin/dunst &>/dev/null &
        else
            ${pkgs.dunst}/bin/dunst &>/dev/null &
        fi
        echo "$(${date}): Dunst restarted with updated config" >> "$LOG"
    fi

    # Update Firefox user.js with current scale factor
    FIREFOX_USERJS="$HOME/.config/hydrix/dynamic/firefox-user.js"
    FIREFOX_PROFILE="$HOME/.mozilla/firefox"
    if [ -f "$FIREFOX_USERJS" ] && [ -d "$FIREFOX_PROFILE" ]; then
        # Find the default profile directory
        DEFAULT_PROFILE=$(find "$FIREFOX_PROFILE" -maxdepth 1 -type d -name "*.default*" | head -1)
        if [ -n "$DEFAULT_PROFILE" ]; then
            cp "$FIREFOX_USERJS" "$DEFAULT_PROFILE/user.js"
            echo "$(${date}): Updated Firefox user.js (restart Firefox to apply)" >> "$LOG"
        fi
    fi

    # Restore wallpaper after resolution changes (fixes stretched wallpaper race condition)
    if [ -f "$HOME/.fehbg" ]; then
        echo "$(${date}): Restoring wallpaper..." >> "$LOG"
        "$HOME/.fehbg" >> "$LOG" 2>&1 || true
    fi

    # Signal vm-focus-daemon to re-apply colors (SIGUSR1 forces refresh)
    ${pkgs.procps}/bin/pkill -USR1 -f vm-focus-daemon 2>/dev/null || true

    echo "$(${date}): display-setup complete" >> "$LOG"
  '';

  # Hotplug script - writes trigger file, timer will pick it up
  hotplugScript = pkgs.writeShellScript "display-hotplug" ''
    #!/usr/bin/env bash
    # Triggered by udev - writes a trigger file for the user's watcher
    echo "$(${pkgs.coreutils}/bin/date)" > /tmp/display-hotplug.trigger
  '';

in {
  config = lib.mkIf cfg.enable {
    # Make the script available system-wide
    environment.systemPackages = [
      (pkgs.runCommand "display-setup" {} ''
        mkdir -p $out/bin
        cp ${displaySetupScript} $out/bin/display-setup
        chmod +x $out/bin/display-setup
      '')
      pkgs.killall
      pkgs.jq  # For reading scaling.json
    ];

    # Udev rule for monitor hotplug (host only)
    services.udev.extraRules = lib.mkIf (!isVM) ''
      # Trigger display-setup on monitor connect/disconnect
      ACTION=="change", SUBSYSTEM=="drm", RUN+="${hotplugScript}"
    '';

    # Systemd path unit watches for trigger file from udev
    systemd.user.paths.display-hotplug = lib.mkIf (!isVM) {
      description = "Watch for display hotplug trigger";
      wantedBy = [ "graphical-session.target" ];
      pathConfig = {
        PathChanged = "/tmp/display-hotplug.trigger";
        Unit = "display-setup.service";
      };
    };

    # Systemd user service for display-setup
    systemd.user.services.display-setup = lib.mkIf (!isVM) {
      description = "Display hotplug handler";
      serviceConfig = {
        Type = "oneshot";
        # Wait for display to stabilize, then run
        ExecStart = pkgs.writeShellScript "display-setup-wrapper" ''
          ${sleep} 3
          ${displaySetupScript}
        '';
        StandardOutput = "append:/tmp/display-setup.log";
        StandardError = "append:/tmp/display-setup.log";
        # Don't kill spawned processes (polybar) when service exits
        KillMode = "none";
      };
    };
  };

  # Export the script derivation for other modules
  options.hydrix.graphical._displaySetupScript = lib.mkOption {
    type = lib.types.package;
    default = displaySetupScript;
    internal = true;
    description = "The display-setup script package.";
  };
}
