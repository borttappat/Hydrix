# Polybar Status Bar Configuration
#
# Home Manager module for Polybar.
# Colors are automatically applied by Stylix via xrdb/Xresources.
#
# Supports two styles via hydrix.graphical.ui.polybarStyle:
#   - "unibar": Classic solid bar with separator between modules
#   - "modular": Floating modules with transparent background and dynamic underlines
#
# NOTE: This module generates a TEMPLATE config with placeholders:
#   @@FONT_SIZE@@, @@BAR_HEIGHT@@, @@FONT_NAME@@, @@GAPS@@, @@CORNER_RADIUS@@
# The display-setup script substitutes these at runtime based on detected DPI.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";
  floatingBar = config.hydrix.graphical.ui.floatingBar;
  polybarStyle = config.hydrix.graphical.ui.polybarStyle;
  isModular = polybarStyle == "modular";
  workspaceLabels = config.hydrix.graphical.ui.workspaceLabels;
  workspaceDescriptions = config.hydrix.graphical.ui.workspaceDescriptions;
  hasWorkspaceDescriptions = workspaceDescriptions != {};

  # Generate ws-icon-N = name;label lines for workspace mapping (i3 module format)
  # Format: ws-icon-0 = 1;I (index = name;display)
  workspaceIconLines = lib.concatStringsSep "\n" (
    lib.imap0 (i: pair: "ws-icon-${toString i} = ${pair.name};${pair.value}")
      (lib.mapAttrsToList (name: value: { inherit name value; }) workspaceLabels)
  );

  # Generate case statement entries for workspace descriptions
  workspaceDescCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (ws: desc: "    ${ws}) desc=\"${desc}\" ;;") workspaceDescriptions
  );

  # Full paths for commands used in polybar scripts
  awk = "${pkgs.gawk}/bin/awk";
  grep = "${pkgs.gnugrep}/bin/grep";
  sed = "${pkgs.gnused}/bin/sed";
  hostname = "${pkgs.inetutils}/bin/hostname";
  ifconfig = "${pkgs.inetutils}/bin/ifconfig";
  uptimeCmd = "${pkgs.coreutils}/bin/uptime";
  tr = "${pkgs.coreutils}/bin/tr";
  wc = "${pkgs.coreutils}/bin/wc";
  cat = "${pkgs.coreutils}/bin/cat";
  cut = "${pkgs.coreutils}/bin/cut";
  head = "${pkgs.coreutils}/bin/head";
  tail = "${pkgs.coreutils}/bin/tail";
  amixer = "${pkgs.alsa-utils}/bin/amixer";
  git = "${pkgs.git}/bin/git";
  virsh = "${pkgs.libvirt}/bin/virsh";
  xrdb = "${pkgs.xorg.xrdb}/bin/xrdb";
  df = "${pkgs.coreutils}/bin/df";
  free = "${pkgs.procps}/bin/free";
  ps = "${pkgs.procps}/bin/ps";
  i3msg = "${pkgs.i3}/bin/i3-msg";
  jq = "${pkgs.jq}/bin/jq";
  socat = "${pkgs.socat}/bin/socat";
  timeout = "${pkgs.coreutils}/bin/timeout";
  notifySend = "${pkgs.libnotify}/bin/notify-send";

  # ============================================================
  # VM QUERY HELPER
  # Maps workspace to VM CID and queries via vsock
  # ============================================================

  # Workspace to VM CID mapping (registry-driven)
  getVmCidScript = pkgs.writeShellScript "polybar-get-vm-cid" ''
    ws=$(${i3msg} -t get_workspaces 2>/dev/null | ${jq} -r '.[] | select(.focused==true) | .name' | ${head} -1)
    VM_REGISTRY="/etc/hydrix/vm-registry.json"
    if [[ -f "$VM_REGISTRY" && -n "$ws" ]]; then
      ${jq} -r --argjson w "$ws" \
        'to_entries[] | select(.value.workspace == $w) | .value.cid' \
        "$VM_REGISTRY" 2>/dev/null | ${head} -1
    fi
  '';

  # Query VM metric via vsock (using xpra's metrics port or socat)
  # Usage: vm-query <cid> <command>
  # Returns command output or empty string if VM not reachable
  vmQueryScript = pkgs.writeShellScript "polybar-vm-query" ''
    CID="$1"
    CMD="$2"

    if [ -z "$CID" ] || [ -z "$CMD" ]; then
      echo ""
      exit 0
    fi

    # Try to query via xpra control (runs command in VM's xpra session)
    # Note: xpra control start doesn't return output, so we use a vsock metrics approach
    # For now, use socat to connect to a metrics port (14501) if available
    result=$(echo "$CMD" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$CID:14501 2>/dev/null)

    if [ -n "$result" ]; then
      echo "$result"
    else
      echo ""
    fi
  '';

  # ============================================================
  # DYNAMIC THRESHOLD SCRIPTS
  # Output polybar format tags: %{u#COLOR}%{+u}VALUE%{-u}
  # ============================================================

  # Helper function embedded in each script
  # Uses xrdb colors: color4 for normal, color1 for alert, color3 for prefix
  getColorHelper = ''
    get_color() {
      local color_name="$1"
      local fallback="$2"
      local color=$(${xrdb} -query 2>/dev/null | ${grep} "^\*$color_name:" | ${awk} '{print $2}')
      if [ -z "$color" ]; then
        echo "$fallback"
      else
        echo "$color"
      fi
    }
    color_normal=$(get_color "color4" "#5e81ac")
    color_alert=$(get_color "color1" "#bf616a")
    color_prefix=$(get_color "color3" "#ebcb8b")
  '';

  # GIT: alert when > 4 changes (tracks user's hydrix-config)
  gitDynamicScript = pkgs.writeShellScript "polybar-git-dynamic" ''
    count=$(${git} -C ${config.hydrix.paths.configDir} status --porcelain 2>/dev/null | ${wc} -l) || count=0
    ${getColorHelper}
    if [ "$count" -gt 4 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}GIT %{F-}%{u$uc}%{+u}$count%{-u}"
  '';

  # VMs: alert when > 4 running
  vmsDynamicScript = pkgs.writeShellScript "polybar-vms-dynamic" ''
    count=$(${virsh} --connect qemu:///system list --state-running --name 2>/dev/null | ${grep} -c .) || count=0
    ${getColorHelper}
    if [ "$count" -gt 4 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}VMS %{F-}%{u$uc}%{+u}$count%{-u}"
  '';

  # MicroVMs: alert when > 4 running
  mvmsDynamicScript = pkgs.writeShellScript "polybar-mvms-dynamic" ''
    count=$(systemctl list-units --type=service --state=running 2>/dev/null | ${grep} -c "microvm@") || count=0
    ${getColorHelper}
    if [ "$count" -gt 4 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}MVMS %{F-}%{u$uc}%{+u}$count%{-u}"
  '';

  # SYNC: Count staged packages from running VMs (via vsock)
  # Shows total staged packages across all running VMs
  syncDynamicScript = pkgs.writeShellScript "polybar-sync-dynamic" ''
    # Query vm-sync for staged package count (new vsock-based approach)
    # vm-sync list output format:
    #   microvm-dev (dev):
    #     cpond
    # Count lines that start with 4+ spaces and contain a package name
    count=0
    output=$(vm-sync list 2>/dev/null)
    if [ -n "$output" ]; then
      # Count indented package lines (4 spaces + alphanumeric)
      count=$(echo "$output" | ${grep} -cE "^    [a-zA-Z]" 2>/dev/null) || count=0
    fi
    ${getColorHelper}
    if [ "$count" -gt 0 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}SYNC %{F-}%{u$uc}%{+u}$count%{-u}"
  '';

  # FOCUS MODE: show focused VM type (empty when inactive)
  focusDynamicScript = pkgs.writeShellScript "polybar-focus-dynamic" ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    if [ ! -f "$FOCUS_FILE" ]; then
      echo ""
      exit 0
    fi
    focus_type=$(${cat} "$FOCUS_FILE" 2>/dev/null)
    if [ -z "$focus_type" ]; then
      echo ""
      exit 0
    fi
    TYPE_UPPER=$(echo "$focus_type" | ${tr} '[:lower:]' '[:upper:]')
    ${getColorHelper}
    echo "%{F$color_alert}FOCUS %{F-}%{u$color_alert}%{+u}$TYPE_UPPER%{-u}"
  '';

  focusStaticScript = pkgs.writeShellScript "polybar-focus-static" ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    if [ ! -f "$FOCUS_FILE" ]; then
      echo ""
      exit 0
    fi
    focus_type=$(${cat} "$FOCUS_FILE" 2>/dev/null)
    if [ -z "$focus_type" ]; then
      echo ""
      exit 0
    fi
    echo "$focus_type" | ${tr} '[:lower:]' '[:upper:]'
  '';

  # VOLUME: alert when > 75%
  volumeDynamicScript = pkgs.writeShellScript "polybar-volume-dynamic" ''
    vol=$(${amixer} sget Master 2>/dev/null | ${awk} -F'[][]' '/Left:/ { gsub(/%/,""); print $2 }' || echo 0)
    ${getColorHelper}
    if [ "$vol" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}VOL %{F-}%{u$uc}%{+u}''${vol}%{-u}"
  '';

  # BLU: Color temperature (blugon blue light filter)
  # Shows current temperature in Kelvin, alert when below 4000K (very warm)
  # Blugon config options
  bluelightCfg = config.hydrix.graphical.bluelight;
  blugonEnabled = bluelightCfg.enable;
  blugonPath = "${pkgs.blugon}/bin/blugon";

  tempDynamicScript = pkgs.writeShellScript "polybar-temp-dynamic" ''
    CURRENT_FILE="$HOME/.config/blugon/current"
    BLUGON_MARKER="$HOME/.cache/hydrix/blugon-active"

    # Check if blugon is active (marker file)
    if [ ! -f "$BLUGON_MARKER" ]; then
      ${getColorHelper}
      echo "%{F$color_prefix}BLU %{F-}%{u$color_normal}%{+u}OFF%{-u}"
      exit 0
    fi

    # Read current temperature
    if [ -f "$CURRENT_FILE" ]; then
      temp=$(${cat} "$CURRENT_FILE" 2>/dev/null)
    else
      temp=""
    fi

    # If blugon not configured or file missing, show disabled
    if [ -z "$temp" ]; then
      ${getColorHelper}
      echo "%{F$color_prefix}BLU %{F-}%{u$color_normal}%{+u}---%{-u}"
      exit 0
    fi

    ${getColorHelper}

    # Alert when very warm (< 4000K) - eye strain protection active
    if [ "$temp" -lt 4000 ] 2>/dev/null; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi

    # Format: show K suffix
    echo "%{F$color_prefix}BLU %{F-}%{u$uc}%{+u}''${temp}K%{-u}"
  '';

  # Static temperature module (for unibar)
  tempStaticScript = pkgs.writeShellScript "polybar-temp-static" ''
    CURRENT_FILE="$HOME/.config/blugon/current"

    if [ -f "$CURRENT_FILE" ]; then
      temp=$(${cat} "$CURRENT_FILE" 2>/dev/null)
      if [ -n "$temp" ]; then
        echo "''${temp}K"
      else
        echo "---"
      fi
    else
      echo "---"
    fi
  '';

  # Scripts for adjusting temperature via polybar clicks
  tempUpScript = pkgs.writeShellScript "polybar-temp-up" ''
    # Cooler (more blue) = higher temp
    blugon-set + 2>/dev/null || ${blugonPath} --setcurrent="+${toString bluelightCfg.step}" 2>/dev/null
  '';

  tempDownScript = pkgs.writeShellScript "polybar-temp-down" ''
    # Warmer (more red) = lower temp
    blugon-set - 2>/dev/null || ${blugonPath} --setcurrent="-${toString bluelightCfg.step}" 2>/dev/null
  '';

  tempResetScript = pkgs.writeShellScript "polybar-temp-reset" ''
    blugon-set reset 2>/dev/null || echo "${toString bluelightCfg.defaultTemp}" > "$HOME/.config/blugon/current" && ${blugonPath} --readcurrent --once
  '';

  # RAM: alert when > 75%
  ramDynamicScript = pkgs.writeShellScript "polybar-ram-dynamic" ''
    ram=$(${free} | ${awk} '/Mem:/ { printf "%.0f", $3/$2 * 100 }')
    ${getColorHelper}
    if [ "$ram" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}RAM %{F-}%{u$uc}%{+u}''${ram}%{-u}"
  '';

  # CPU: alert when > 75% (samples twice for real-time usage)
  cpuDynamicScript = pkgs.writeShellScript "polybar-cpu-dynamic" ''
    # Sample /proc/stat twice with 0.5s delay for real-time CPU usage
    read -r _ user1 nice1 sys1 idle1 iowait1 irq1 softirq1 _ < /proc/stat
    sleep 0.5
    read -r _ user2 nice2 sys2 idle2 iowait2 irq2 softirq2 _ < /proc/stat

    # Calculate deltas
    total1=$((user1 + nice1 + sys1 + idle1 + iowait1 + irq1 + softirq1))
    total2=$((user2 + nice2 + sys2 + idle2 + iowait2 + irq2 + softirq2))
    idle_delta=$((idle2 - idle1))
    total_delta=$((total2 - total1))

    if [ "$total_delta" -gt 0 ]; then
      cpu=$((100 - (idle_delta * 100 / total_delta)))
    else
      cpu=0
    fi

    ${getColorHelper}
    if [ "$cpu" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}CPU %{F-}%{u$uc}%{+u}''${cpu}%{-u}"
  '';

  # FILESYSTEM: alert when > 75%
  fsDynamicScript = pkgs.writeShellScript "polybar-fs-dynamic" ''
    fs=$(${df} / | ${awk} 'NR==2 { gsub(/%/,""); print $5 }')
    ${getColorHelper}
    if [ "$fs" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}FS %{F-}%{u$uc}%{+u}''${fs}%{-u}"
  '';

  # UPTIME: alert when > 24 hours (uppercase format: 2H 3M)
  uptimeDynamicScript = pkgs.writeShellScript "polybar-uptime-dynamic" ''
    uptime_sec=$(${cat} /proc/uptime | ${awk} '{print int($1)}')
    uptime_hours=$((uptime_sec / 3600))

    if [ "$uptime_hours" -ge 24 ]; then
      days=$((uptime_hours / 24))
      hours=$((uptime_hours % 24))
      display="''${days}D ''${hours}H"
    else
      mins=$(((uptime_sec % 3600) / 60))
      display="''${uptime_hours}H ''${mins}M"
    fi

    ${getColorHelper}
    if [ "$uptime_hours" -gt 24 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}UP %{F-}%{u$uc}%{+u}''${display}%{-u}"
  '';

  # DATE: no threshold, always normal color
  dateDynamicScript = pkgs.writeShellScript "polybar-date-dynamic" ''
    date_str=$(date '+%d/%m %H:%M')
    ${getColorHelper}
    echo "%{F$color_prefix}DATE %{F-}%{u$color_normal}%{+u}''${date_str}%{-u}"
  '';

  # POMO: Pomodoro timer with blinking underline when expired
  # State file format: STATE START_TIME ALERT (e.g., "WORK 1699999999 0")
  pomoDynamicScript = pkgs.writeShellScript "polybar-pomo-dynamic" ''
    STATE_FILE="/tmp/pomodoro_state"
    WORK_DURATION=1500   # 25 minutes
    BREAK_DURATION=300   # 5 minutes

    ${getColorHelper}

    if [ ! -f "$STATE_FILE" ]; then
      echo "%{F$color_prefix}POMO %{F-}%{u$color_normal}%{+u}OFF%{-u}"
      exit 0
    fi

    read -r state start_time alert < "$STATE_FILE"
    now=$(date +%s)

    # Handle paused state
    if [[ "$state" == PAUSED_* ]]; then
      original_state="''${state#PAUSED_}"
      remaining="$start_time"  # When paused, start_time holds remaining seconds
      mins=$((remaining / 60))
      secs=$((remaining % 60))
      time_str=$(printf "%02d:%02d" "$mins" "$secs")
      echo "%{F$color_prefix}POMO %{F-}%{u$color_normal}%{+u}$original_state $time_str ⏸%{-u}"
      exit 0
    fi

    # Calculate remaining time
    elapsed=$((now - start_time))
    if [ "$state" = "WORK" ]; then
      duration=$WORK_DURATION
    else
      duration=$BREAK_DURATION
    fi
    remaining=$((duration - elapsed))

    if [ "$remaining" -le 0 ]; then
      # Timer expired - set alert state, notify once, and blink
      if [ "$alert" != "1" ]; then
        echo "$state $start_time 1" > "$STATE_FILE"
        # Send notification once when timer expires
        if [ "$state" = "WORK" ]; then
          ${notifySend} -u normal -t 0 "Worktime over --->"
        else
          ${notifySend} -u normal -t 0 "Pause over --->"
        fi
      fi

      # Blink effect: alternate colors based on current second
      if [ $((now % 2)) -eq 0 ]; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi

      if [ "$state" = "WORK" ]; then
        echo "%{F$color_prefix}POMO %{F-}%{u$uc}%{+u}BREAK?%{-u}"
      else
        echo "%{F$color_prefix}POMO %{F-}%{u$uc}%{+u}WORK?%{-u}"
      fi
    else
      # Timer running normally
      mins=$((remaining / 60))
      secs=$((remaining % 60))
      time_str=$(printf "%02d:%02d" "$mins" "$secs")
      echo "%{F$color_prefix}POMO %{F-}%{u$color_normal}%{+u}$state $time_str%{-u}"
    fi
  '';

  # POMO static (for unibar): simple display without dynamic underlines
  pomoStaticScript = pkgs.writeShellScript "polybar-pomo-static" ''
    STATE_FILE="/tmp/pomodoro_state"
    WORK_DURATION=1500
    BREAK_DURATION=300

    if [ ! -f "$STATE_FILE" ]; then
      echo "OFF"
      exit 0
    fi

    read -r state start_time alert < "$STATE_FILE"
    now=$(date +%s)

    if [[ "$state" == PAUSED_* ]]; then
      original_state="''${state#PAUSED_}"
      remaining="$start_time"
      mins=$((remaining / 60))
      secs=$((remaining % 60))
      printf "%s %02d:%02d ⏸" "$original_state" "$mins" "$secs"
      exit 0
    fi

    elapsed=$((now - start_time))
    if [ "$state" = "WORK" ]; then
      duration=$WORK_DURATION
    else
      duration=$BREAK_DURATION
    fi
    remaining=$((duration - elapsed))

    if [ "$remaining" -le 0 ]; then
      # Timer expired - set alert state and notify once
      if [ "$alert" != "1" ]; then
        echo "$state $start_time 1" > "$STATE_FILE"
        if [ "$state" = "WORK" ]; then
          ${notifySend} -u normal -t 0 "Worktime over --->"
        else
          ${notifySend} -u normal -t 0 "Pause over --->"
        fi
      fi
      if [ "$state" = "WORK" ]; then
        echo "BREAK?"
      else
        echo "WORK?"
      fi
    else
      mins=$((remaining / 60))
      secs=$((remaining % 60))
      printf "%s %02d:%02d" "$state" "$mins" "$secs"
    fi
  '';

  # BATTERY: alert when < 20%
  batteryDynamicScript = pkgs.writeShellScript "polybar-battery-dynamic" ''
    bat=$(${cat} /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "N/A")
    status=$(${cat} /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
    ${getColorHelper}
    if [ "$status" = "Charging" ]; then
      prefix="CHR"
    else
      prefix="BAT"
    fi
    if [ "$bat" != "N/A" ] && [ "$bat" -lt 20 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}$prefix %{F-}%{u$uc}%{+u}''${bat}%{-u}"
  '';

  # BATTERY TIME: estimated time remaining based on current power draw
  # Shows time to empty (discharging) or time to full (charging)
  batteryTimeDynamicScript = pkgs.writeShellScript "polybar-battery-time-dynamic" ''
    energy_now=$(${cat} /sys/class/power_supply/BAT0/energy_now 2>/dev/null)
    energy_full=$(${cat} /sys/class/power_supply/BAT0/energy_full 2>/dev/null)
    power_now=$(${cat} /sys/class/power_supply/BAT0/power_now 2>/dev/null)
    status=$(${cat} /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")

    ${getColorHelper}

    # Handle missing or invalid values
    if [ -z "$energy_now" ] || [ -z "$power_now" ] || [ "$power_now" = "0" ]; then
      echo "%{F$color_prefix}ETA %{F-}%{u$color_normal}%{+u}--:--{-u}"
      exit 0
    fi

    # Calculate time in minutes based on status
    if [ "$status" = "Charging" ]; then
      # Time to full
      energy_remaining=$((energy_full - energy_now))
      time_mins=$((energy_remaining * 60 / power_now))
      prefix="ETA"
    elif [ "$status" = "Discharging" ]; then
      # Time to empty
      time_mins=$((energy_now * 60 / power_now))
      prefix="TTL"
    else
      # Full or unknown
      echo "%{F$color_prefix}ETA %{F-}%{u$color_normal}%{+u}FULL%{-u}"
      exit 0
    fi

    # Convert to hours:minutes
    hours=$((time_mins / 60))
    mins=$((time_mins % 60))

    # Alert color if less than 30 mins remaining while discharging
    if [ "$status" = "Discharging" ] && [ "$time_mins" -lt 30 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi

    printf "%%{F%s}%s %%{F-}%%{u%s}%%{+u}%d:%02d%%{-u}" "$color_prefix" "$prefix" "$uc" "$hours" "$mins"
  '';

  # WORKSPACE DESC: Shows current workspace description with underline
  workspaceDescScript = pkgs.writeShellScript "polybar-workspace-desc" ''
    # Get current workspace number
    ws=$(${pkgs.i3}/bin/i3-msg -t get_workspaces 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .name' | head -1)

    # Look up description
    case "$ws" in
${workspaceDescCases}
    *) desc="" ;;
    esac

    if [ -n "$desc" ]; then
      ${getColorHelper}
      echo "%{F$color_prefix}WS %{F-}%{u$color_normal}%{+u}$desc%{-u}"
    fi
  '';

  # ============================================================
  # HOST BOTTOM BAR SCRIPTS
  # Query host and VM metrics for the bottom status bar
  # ============================================================

  # PWR: Power profile indicator (powersave/balanced/performance)
  # Shows current mode with color coding and click to toggle
  powerProfileDynamicScript = pkgs.writeShellScript "polybar-power-profile-dynamic" ''
    STATE_FILE="/run/hydrix/power-mode-state"
    ${getColorHelper}

    # Get current mode from state file or detect from system
    if [[ -f "$STATE_FILE" ]]; then
      mode=$(${cat} "$STATE_FILE")
    else
      # Detect from system state
      gov=$(${cat} /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
      max_perf=$(${cat} /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || echo "100")
      if [[ "$gov" == "performance" ]]; then
        mode="performance"
      elif [[ "$gov" == "powersave" ]] && [[ "$max_perf" -le 70 ]]; then
        mode="powersave"
      else
        mode="balanced"
      fi
    fi

    # Display with appropriate styling
    case "$mode" in
      powersave)
        # Green underline for power saving
        color_mode=$(get_color "color2" "#a3be8c")
        echo "%{F$color_prefix}PWR %{F-}%{u$color_mode}%{+u}SAVE%{-u}"
        ;;
      performance)
        # Red/alert underline for high power
        echo "%{F$color_prefix}PWR %{F-}%{u$color_alert}%{+u}PERF%{-u}"
        ;;
      balanced|auto|*)
        # Normal underline for balanced
        echo "%{F$color_prefix}PWR %{F-}%{u$color_normal}%{+u}AUTO%{-u}"
        ;;
    esac
  '';

  # Script for toggling power mode via polybar click
  powerToggleScript = pkgs.writeShellScript "polybar-power-toggle" ''
    STATE_FILE="/run/hydrix/power-mode-state"
    current=""
    if [[ -f "$STATE_FILE" ]]; then
      current=$(${cat} "$STATE_FILE")
    fi
    case "$current" in
      powersave) power-mode balanced ;;
      balanced|auto) power-mode performance ;;
      performance) power-mode powersave ;;
      *) power-mode powersave ;;
    esac
  '';

  powerPerformanceScript = pkgs.writeShellScript "polybar-power-performance" ''
    power-mode performance
  '';

  # CPROC: Most CPU-intensive process on host (renamed from HCPU)
  hostCpuDynamicScript = pkgs.writeShellScript "polybar-host-cpu-dynamic" ''
    ${getColorHelper}

    # Get top CPU process (skip header, get first real process)
    # Extract full command, take only the basename, cut before first space, uppercase
    top_line=$(${ps} aux --sort=-%cpu 2>/dev/null | ${awk} 'NR==2 {print $11, $3}')
    proc_name=$(echo "$top_line" | ${awk} '{print $1}' | ${sed} 's:.*/::' | ${cut} -d' ' -f1 | ${tr} '[:lower:]' '[:upper:]' | ${cut} -c1-28)
    proc_cpu=$(echo "$top_line" | ${awk} '{printf "%.0f", $2}')

    if [ -z "$proc_name" ]; then
      proc_name="IDLE"
      proc_cpu="0"
    fi

    # Alert if process using > 50% CPU
    if [ "$proc_cpu" -gt 50 ] 2>/dev/null; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi

    echo "%{F$color_prefix}CPROC %{F-}%{u$uc}%{+u}$proc_name $proc_cpu%{-u}"
  '';

  # RPROC: Most RAM-intensive process on host (renamed from HRAM)
  hostRamDynamicScript = pkgs.writeShellScript "polybar-host-ram-dynamic" ''
    ${getColorHelper}

    # Get top RAM process (RSS in KB, column $6)
    # Extract full command, take only the basename, cut before first space, uppercase
    top_line=$(${ps} aux --sort=-%mem 2>/dev/null | ${awk} 'NR==2 {print $11, $6}')
    proc_name=$(echo "$top_line" | ${awk} '{print $1}' | ${sed} 's:.*/::' | ${cut} -d' ' -f1 | ${tr} '[:lower:]' '[:upper:]' | ${cut} -c1-28)
    proc_ram_kb=$(echo "$top_line" | ${awk} '{print $2}')

    if [ -z "$proc_name" ]; then
      proc_name="IDLE"
      proc_ram_kb="0"
    fi

    # Convert to MB
    proc_ram=$((proc_ram_kb / 1024))

    # Alert if process using > 2GB RAM
    if [ "$proc_ram" -gt 2048 ] 2>/dev/null; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi

    echo "%{F$color_prefix}RPROC %{F-}%{u$uc}%{+u}$proc_name $proc_ram%{-u}"
  '';

  # Get current workspace's VM CID (empty if not a VM workspace)
  # Uses active-vms.json to determine which VM to query when multiple are available
  getVmInfoScript = pkgs.writeShellScript "polybar-get-vm-info" ''
    ACTIVE_VMS_FILE="$HOME/.cache/hydrix/active-vms.json"

    ws=$(${i3msg} -t get_workspaces 2>/dev/null | ${jq} -r '.[] | select(.focused==true) | .name' | ${head} -1)

    # Map workspace to VM type via registry
    VM_REGISTRY="/etc/hydrix/vm-registry.json"
    vm_type=""
    if [[ -f "$VM_REGISTRY" && -n "$ws" ]]; then
      vm_type=$(${jq} -r --argjson w "$ws" \
        'to_entries[] | select(.value.workspace == $w) | .key' \
        "$VM_REGISTRY" 2>/dev/null | ${head} -1)
    fi
    [[ -z "$vm_type" ]] && echo "" && exit 0

    # Try to get active VM from cache
    vm_name=""
    if [ -f "$ACTIVE_VMS_FILE" ]; then
      vm_name=$(${jq} -r ".\"$vm_type\" // empty" "$ACTIVE_VMS_FILE" 2>/dev/null)
    fi

    # Fall back to default microVM if no active VM set
    if [ -z "$vm_name" ]; then
      vm_name=$(${jq} -r --arg t "$vm_type" '.[$t].vmName // empty' "$VM_REGISTRY" 2>/dev/null)
    fi

    # Get CID from VM name
    # Fast path: default VM names with known CIDs
    case "$vm_name" in
      microvm-pentest) cid="102" ;;
      microvm-browsing) cid="101" ;;
      microvm-comms) cid="104" ;;
      microvm-lurking) cid="105" ;;
      microvm-dev) cid="103" ;;
      *)
        # Dynamic resolve: read CID from the microVM's qemu launch script
        run_script="/var/lib/microvms/$vm_name/current/bin/microvm-run"
        if [ -f "$run_script" ]; then
          cid=$(${grep} -oP 'guest-cid=\K[0-9]+' "$run_script" 2>/dev/null)
        else
          cid=""
        fi
        ;;
    esac

    if [ -n "$cid" ]; then
      echo "$cid $vm_type $vm_name"
    else
      echo ""
    fi
  '';

  # Check if a microVM is running
  isVmRunningScript = pkgs.writeShellScript "polybar-is-vm-running" ''
    VM_NAME="$1"
    if systemctl is-active --quiet "microvm@$VM_NAME" 2>/dev/null; then
      echo "1"
    else
      echo "0"
    fi
  '';

  # CPROC: Most CPU-intensive process in current workspace's VM (renamed from GCPU)
  guestCpuBottomScript = pkgs.writeShellScript "polybar-guest-cpu-bottom" ''
    ${getColorHelper}

    # Get VM info for current workspace
    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      # Not a VM workspace
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_type=$(echo "$vm_info" | ${awk} '{print $2}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    # Check if VM is running
    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}CPROC %{F-}%{u$color_normal}%{+u}---%{-u}"
      exit 0
    fi

    # Query VM for top CPU process via vsock metrics port
    result=$(echo "top" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      # Uppercase and cut before first space, show more chars
      proc_name=$(echo "$result" | ${cut} -d' ' -f1 | ${tr} '[:lower:]' '[:upper:]' | ${cut} -c1-28)
      proc_cpu=$(echo "$result" | ${cut} -d' ' -f2)
      if [ "$proc_cpu" -gt 50 ] 2>/dev/null; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}CPROC %{F-}%{u$uc}%{+u}$proc_name $proc_cpu%{-u}"
    else
      echo "%{F$color_prefix}CPROC %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # RPROC: Most RAM-intensive process in current workspace's VM (renamed from GRAM)
  guestRamBottomScript = pkgs.writeShellScript "polybar-guest-ram-bottom" ''
    ${getColorHelper}

    # Get VM info for current workspace
    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      # Not a VM workspace
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_type=$(echo "$vm_info" | ${awk} '{print $2}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    # Check if VM is running
    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}RPROC %{F-}%{u$color_normal}%{+u}---%{-u}"
      exit 0
    fi

    # Query VM for top RAM process via vsock metrics port
    result=$(echo "topmem" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      # Uppercase and cut before first space, show more chars
      proc_name=$(echo "$result" | ${cut} -d' ' -f1 | ${tr} '[:lower:]' '[:upper:]' | ${cut} -c1-28)
      proc_ram=$(echo "$result" | ${cut} -d' ' -f2)
      # Alert if process using > 2GB RAM
      if [ "$proc_ram" -gt 2048 ] 2>/dev/null; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}RPROC %{F-}%{u$uc}%{+u}$proc_name $proc_ram%{-u}"
    else
      echo "%{F$color_prefix}RPROC %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # VM CPU usage
  vmCpuBottomScript = pkgs.writeShellScript "polybar-vm-cpu-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}CPU %{F-}%{u$color_normal}%{+u}○%{-u}"
      exit 0
    fi

    result=$(echo "cpu" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      cpu="$result"
      if [ "$cpu" -gt 75 ] 2>/dev/null; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}CPU %{F-}%{u$uc}%{+u}''${cpu}%{-u}"
    else
      echo "%{F$color_prefix}CPU %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # VM RAM usage
  vmRamBottomScript = pkgs.writeShellScript "polybar-vm-ram-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}RAM %{F-}%{u$color_normal}%{+u}○%{-u}"
      exit 0
    fi

    result=$(echo "ram" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      ram="$result"
      if [ "$ram" -gt 75 ] 2>/dev/null; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}RAM %{F-}%{u$uc}%{+u}''${ram}%{-u}"
    else
      echo "%{F$color_prefix}RAM %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # VM Filesystem usage
  vmFsBottomScript = pkgs.writeShellScript "polybar-vm-fs-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}FS %{F-}%{u$color_normal}%{+u}○%{-u}"
      exit 0
    fi

    result=$(echo "fs" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      fs="$result"
      if [ "$fs" -gt 75 ] 2>/dev/null; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}FS %{F-}%{u$uc}%{+u}''${fs}%{-u}"
    else
      echo "%{F$color_prefix}FS %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # VM Uptime
  vmUpBottomScript = pkgs.writeShellScript "polybar-vm-up-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}UP %{F-}%{u$color_normal}%{+u}○%{-u}"
      exit 0
    fi

    result=$(echo "uptime" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      echo "%{F$color_prefix}UP %{F-}%{u$color_normal}%{+u}$result%{-u}"
    else
      echo "%{F$color_prefix}UP %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # DEV: Unstaged/dev package count in current workspace's VM
  vmSyncDevBottomScript = pkgs.writeShellScript "polybar-vm-sync-dev-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}DEV %{F-}%{u$color_normal}%{+u}---%{-u}"
      exit 0
    fi

    result=$(echo "sync" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      dev=$(echo "$result" | ${cut} -d' ' -f1)
      # Alert if dev packages exist (work in progress)
      if [ "$dev" -gt 0 ] 2>/dev/null; then
        uc="$color_normal"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}DEV %{F-}%{u$uc}%{+u}$dev%{-u}"
    else
      echo "%{F$color_prefix}DEV %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # STG: Staged package count in current workspace's VM
  vmSyncStgBottomScript = pkgs.writeShellScript "polybar-vm-sync-stg-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo "%{F$color_prefix}STG %{F-}%{u$color_normal}%{+u}---%{-u}"
      exit 0
    fi

    result=$(echo "sync" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ]; then
      stg=$(echo "$result" | ${cut} -d' ' -f2)
      # Alert if staged packages exist (needs host pull)
      if [ "$stg" -gt 0 ] 2>/dev/null; then
        uc="$color_alert"
      else
        uc="$color_normal"
      fi
      echo "%{F$color_prefix}STG %{F-}%{u$uc}%{+u}$stg%{-u}"
    else
      echo "%{F$color_prefix}STG %{F-}%{u$color_normal}%{+u}...%{-u}"
    fi
  '';

  # VM TUN: Active VPN/tun interfaces
  vmTunBottomScript = pkgs.writeShellScript "polybar-vm-tun-bottom" ''
    ${getColorHelper}

    vm_info=$(${getVmInfoScript})
    if [ -z "$vm_info" ]; then
      echo ""
      exit 0
    fi

    cid=$(echo "$vm_info" | ${awk} '{print $1}')
    vm_name=$(echo "$vm_info" | ${awk} '{print $3}')

    if ! systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
      echo ""
      exit 0
    fi

    result=$(echo "tun" | ${timeout} 1 ${socat} - VSOCK-CONNECT:$cid:14501 2>/dev/null)

    if [ -n "$result" ] && [ "$result" != "none" ]; then
      echo "%{F$color_prefix}TUN %{F-}%{u$color_normal}%{+u}$result%{-u}"
    else
      echo ""
    fi
  '';

  # ============================================================
  # VM-SPECIFIC DYNAMIC SCRIPTS
  # These run inside VMs and track VM-local resources
  # ============================================================

  # VM-SYNC: Track vm-dev/vm-sync workflow state (inside VM)
  # Shows local dev packages and staged packages
  # Uses new local directories (~/dev/ and ~/staging/) instead of ~/persist/
  vmSyncDynamicScript = pkgs.writeShellScript "polybar-vm-sync-dynamic" ''
    ${getColorHelper}

    # Count packages in development (new local path)
    dev_count=0
    if [ -d "$HOME/dev/packages" ]; then
      dev_count=$(${pkgs.findutils}/bin/find "$HOME/dev/packages" -maxdepth 2 -name "flake.nix" 2>/dev/null | ${wc} -l) || dev_count=0
    fi

    # Count staged packages (ready for host pull via vsock)
    stg_count=0
    if [ -d "$HOME/staging" ]; then
      stg_count=$(${pkgs.findutils}/bin/find "$HOME/staging" -maxdepth 2 -name "package.nix" 2>/dev/null | ${wc} -l) || stg_count=0
    fi

    # Alert color if staged packages exist (host needs to pull)
    if [ "$stg_count" -gt 0 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi

    echo "%{F$color_prefix}SYNC %{F-}%{u$uc}%{+u}DEV $dev_count → STG $stg_count%{-u}"
  '';

  # VM-VPN: Check for active VPN tunnels
  vmVpnDynamicScript = pkgs.writeShellScript "polybar-vm-vpn-dynamic" ''
    ${getColorHelper}

    # Check for tun/wg interfaces
    vpn_iface=$(${pkgs.iproute2}/bin/ip link show 2>/dev/null | ${grep} -oE '(tun|wg|tap)[0-9]+' | head -1)

    if [ -n "$vpn_iface" ]; then
      # Try to get VPN name from openvpn status or just show interface
      vpn_name="$vpn_iface"

      # Check for openvpn process and try to get config name
      ovpn_conf=$(${pkgs.procps}/bin/ps aux 2>/dev/null | ${grep} "[o]penvpn" | ${grep} -oE '[^ ]+\.ovpn|--config [^ ]+' | ${sed} 's/.*\///' | ${sed} 's/\.ovpn$//' | head -1)
      if [ -n "$ovpn_conf" ]; then
        vpn_name="$ovpn_conf"
      fi

      # Truncate long names
      if [ ''${#vpn_name} -gt 12 ]; then
        vpn_name="''${vpn_name:0:10}.."
      fi

      echo "%{F$color_prefix}VPN %{F-}%{u$color_normal}%{+u}$vpn_name%{-u}"
    else
      echo "%{F$color_prefix}VPN %{F-}%{u$color_normal}%{+u}○%{-u}"
    fi
  '';

  # VM-TOP: Most CPU-intensive process
  vmTopDynamicScript = pkgs.writeShellScript "polybar-vm-top-dynamic" ''
    ${getColorHelper}

    # Get top CPU process (skip header, get first real process)
    top_line=$(${pkgs.procps}/bin/ps aux --sort=-%cpu 2>/dev/null | ${awk} 'NR==2 {print $11, $3}')
    proc_name=$(echo "$top_line" | ${awk} '{print $1}' | ${sed} 's:.*/::' | ${pkgs.coreutils}/bin/cut -c1-12)
    proc_cpu=$(echo "$top_line" | ${awk} '{printf "%.0f", $2}')

    if [ -z "$proc_name" ]; then
      proc_name="idle"
      proc_cpu="0"
    fi

    # Alert if process using > 50% CPU
    if [ "$proc_cpu" -gt 50 ] 2>/dev/null; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi

    echo "%{F$color_prefix}TOP %{F-}%{u$uc}%{+u}$proc_name ''${proc_cpu}%%{-u}"
  '';

  # VM-CPU: CPU usage (same as host but for VM's /proc/stat)
  vmCpuDynamicScript = pkgs.writeShellScript "polybar-vm-cpu-dynamic" ''
    # Sample /proc/stat twice with 0.5s delay for real-time CPU usage
    read -r _ user1 nice1 sys1 idle1 iowait1 irq1 softirq1 _ < /proc/stat
    sleep 0.5
    read -r _ user2 nice2 sys2 idle2 iowait2 irq2 softirq2 _ < /proc/stat

    total1=$((user1 + nice1 + sys1 + idle1 + iowait1 + irq1 + softirq1))
    total2=$((user2 + nice2 + sys2 + idle2 + iowait2 + irq2 + softirq2))
    idle_delta=$((idle2 - idle1))
    total_delta=$((total2 - total1))

    if [ "$total_delta" -gt 0 ]; then
      cpu=$((100 - (idle_delta * 100 / total_delta)))
    else
      cpu=0
    fi

    ${getColorHelper}
    if [ "$cpu" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}CPU %{F-}%{u$uc}%{+u}''${cpu}%{-u}"
  '';

  # VM-RAM: Memory usage (same as host but for VM's /proc/meminfo)
  vmRamDynamicScript = pkgs.writeShellScript "polybar-vm-ram-dynamic" ''
    ram=$(${free} | ${awk} '/Mem:/ { printf "%.0f", $3/$2 * 100 }')
    ${getColorHelper}
    if [ "$ram" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}RAM %{F-}%{u$uc}%{+u}''${ram}%{-u}"
  '';

  # VM-FS: Filesystem usage for /home (most relevant in VMs)
  vmFsDynamicScript = pkgs.writeShellScript "polybar-vm-fs-dynamic" ''
    # Check /home first (persistent storage), fallback to /
    fs=$(${df} /home 2>/dev/null | ${awk} 'NR==2 { gsub(/%/,""); print $5 }')
    if [ -z "$fs" ]; then
      fs=$(${df} / | ${awk} 'NR==2 { gsub(/%/,""); print $5 }')
    fi
    ${getColorHelper}
    if [ "$fs" -gt 75 ]; then
      uc="$color_alert"
    else
      uc="$color_normal"
    fi
    echo "%{F$color_prefix}FS %{F-}%{u$uc}%{+u}''${fs}%{-u}"
  '';

  # ============================================================
  # POLYBAR TEMPLATES
  # ============================================================

  # UNIBAR: Classic solid bar with separators
  unibarTemplate = ''
    ; Polybar Template Config - UNIBAR STYLE
    ; Classic solid bar with separator between modules
    ; Placeholders: @@FONT_SIZE@@, @@BAR_HEIGHT@@, @@FONT_NAME@@
    ; Generated by Nix, substituted at runtime by display-setup

    [colors]
    color0 = #00000000
    color1 = ''${xrdb:color0}
    color2 = ''${xrdb:color4}
    color3 = ''${xrdb:color3}
    color4 = ''${xrdb:color3}
    color5 = ''${xrdb:color8}
    color6 = ''${xrdb:color5}
    color7 = ''${xrdb:color6}
    color8 = ''${xrdb:color7}
    alert = #e53935
    disabled = #707880
    ; Colors for bottom bar compatibility
    transparent = #00000000
    module-bg = #@@OVERLAY_ALPHA@@@@BG_COLOR@@
    foreground = ''${xrdb:color7}
    prefix = ''${xrdb:color3}
    underline = ''${xrdb:color4}

    [bar/main]
    monitor = ''${env:MONITOR:}
    bottom = false
    ${if floatingBar then ''
    ; Floating bar: BAR_EDGE_GAPS on all sides (adjustable via barEdgeGapsFactor)
    width = 100%:-@@DOUBLE_BAR_EDGE_GAPS@@
    offset-x = @@BAR_EDGE_GAPS@@
    offset-y = @@BAR_EDGE_GAPS@@
    '' else ''
    ; Docked bar
    width = 100%
    offset-x = 0
    offset-y = 0
    ''}
    height = @@BAR_HEIGHT@@
    fixed-center = true
    radius = ${if floatingBar then "@@CORNER_RADIUS@@" else "0.0"}

    wm-restack = i3
    override-redirect = ${if floatingBar then "true" else "false"}
    enable-ipc = true

    background = ''${colors.color1}
    foreground = ''${colors.color8}

    line-size = 2
    line-color = #f00

    border-size = 0
    border-color = #00000000

    padding-left = 1.5
    padding-right = 1.75

    module-margin-left = 2
    module-margin-right = 2

    font-0 = @@FONT_NAME@@:style=Bold:size=@@FONT_SIZE@@;0
    font-1 = @@FONT_NAME@@:style=Regular:size=@@FONT_SIZE@@;0

    separator = //
    separator-foreground = ''${colors.color2}

    modules-left = xworkspaces${if hasWorkspaceDescriptions then " spacer workspace-desc" else ""} focus
    modules-center =
    modules-right = pomo git-changes vm-count vm-sync battery essid nwup nwdown ip volume temp memory cpu filesystem uptime date

    cursor-click = pointer
    cursor-scroll = ns-resize
    screenchange-reload = true
  '';

  # MODULAR: Floating modules with transparent background
  modularTemplate = ''
    ; Polybar Template Config - MODULAR STYLE
    ; Floating modules with transparent background and dynamic underlines
    ; Placeholders: @@FONT_SIZE@@, @@BAR_HEIGHT@@, @@FONT_NAME@@, @@GAPS@@, @@CORNER_RADIUS@@
    ; Generated by Nix, substituted at runtime by display-setup

    [colors]
    transparent = #00000000
    ; Module background with ~70% opacity (B3 alpha) matching rofi/dunst
    ; Uses a dark base that works with most colorschemes
    module-bg = #@@OVERLAY_ALPHA@@@@BG_COLOR@@
    module-bg-solid = ''${xrdb:color0}
    foreground = ''${xrdb:color7}
    prefix = ''${xrdb:color3}
    underline = ''${xrdb:color4}
    disabled = ''${xrdb:color8}

    [bar/main]
    monitor = ''${env:MONITOR:}
    bottom = false
    ; Floating bar: BAR_EDGE_GAPS on all sides (adjustable via barEdgeGapsFactor)
    width = 100%:-@@DOUBLE_BAR_EDGE_GAPS@@
    offset-x = @@BAR_EDGE_GAPS@@
    offset-y = @@BAR_EDGE_GAPS@@
    height = @@BAR_HEIGHT@@
    radius = @@CORNER_RADIUS@@
    fixed-center = true

    background = ''${colors.transparent}
    foreground = ''${colors.foreground}

    font-0 = @@FONT_NAME@@:style=Bold:size=@@FONT_SIZE@@;3

    line-size = 2
    module-margin = 1
    padding-left = 0
    padding-right = 0

    modules-left = xworkspaces${if hasWorkspaceDescriptions then " spacer workspace-desc" else ""} focus-dynamic
    modules-center =
    modules-right = pomo-dynamic spacer sync-dynamic git-dynamic mvms-dynamic vms-dynamic spacer volume-dynamic temp-dynamic spacer ram-dynamic cpu-dynamic spacer fs-dynamic uptime-dynamic date-dynamic

    wm-restack = i3
    override-redirect = true
    enable-ipc = true

    cursor-click = pointer
    cursor-scroll = ns-resize
    screenchange-reload = true
  '';

  # Common modules for both styles
  commonModules = ''
    [bar/top]
    inherit = bar/main
    ; Inherits override-redirect from bar/main based on floatingBar option

    ; === VM BARS ===
    ; VMs use simple docked bars (override-redirect=false for i3 integration)

    [bar/vm-top]
    inherit = bar/main
    override-redirect = false
    wm-restack = i3
    modules-left = xworkspaces-vm
    modules-center =
    modules-right = vm-hostname ip volume memory cpu filesystem uptime

    ; === HOST BOTTOM BAR ===
    ; Shows host TOP on left, VM metrics on right (based on current workspace)
    ; Only shows VM metrics when on VM workspaces (2-5)
    [bar/bottom]
    monitor = ''${env:MONITOR:}
    bottom = true
    ${if floatingBar then ''
    ; Floating bar: BAR_EDGE_GAPS on all sides (adjustable via barEdgeGapsFactor)
    width = 100%:-@@DOUBLE_BAR_EDGE_GAPS@@
    offset-x = @@BAR_EDGE_GAPS@@
    offset-y = @@BAR_EDGE_GAPS@@
    radius = @@CORNER_RADIUS@@
    '' else ''
    ; Docked bar
    width = 100%
    offset-x = 0
    offset-y = 0
    radius = 0
    ''}
    height = @@BAR_HEIGHT@@
    fixed-center = true

    background = ''${colors.transparent}
    foreground = ''${colors.foreground}

    font-0 = @@FONT_NAME@@:style=Bold:size=@@FONT_SIZE@@;3

    line-size = 2
    module-margin = 1
    padding-left = 0
    padding-right = 0

    ; Power profile and battery on left, Guest metrics on right
    ; Order: PWR BAT TTL gap RPROC CPROC | RAM CPU gap DEV STG FS gap TUN gap UP
    modules-left = power-profile-dynamic battery-dynamic battery-time-dynamic spacer rproc-dynamic cproc-dynamic
    modules-center =
    modules-right = rproc-bottom cproc-bottom vm-ram-bottom vm-cpu-bottom spacer vm-sync-dev-bottom vm-sync-stg-bottom vm-fs-bottom spacer vm-tun-bottom vm-up-bottom

    override-redirect = ${if floatingBar then "true" else "false"}
    wm-restack = i3
    enable-ipc = true

    cursor-click = pointer
    cursor-scroll = ns-resize

    ; === WORKSPACES ===
    [module/xworkspaces]
    type = internal/i3
    index-sort = true
    enable-click = true
    enable-scroll = true

    ; Small gap between workspace labels
    label-separator = " "
    ${if isModular then "label-separator-background = \${colors.transparent}" else ""}

    ; Workspace name to display label mapping (Roman numerals)
    ${workspaceIconLines}

    label-focused = %icon%
    ${if isModular then ''
    label-focused-background = ''${colors.module-bg}
    label-focused-underline = ''${colors.underline}
    '' else ''
    label-focused-underline = ''${colors.color2}
    ''}
    label-focused-padding = 1
    label-unfocused = %icon%
    ${if isModular then "label-unfocused-background = \${colors.module-bg}" else ""}
    label-unfocused-padding = 1
    label-visible = %icon%
    ${if isModular then "label-visible-background = \${colors.module-bg}" else ""}
    label-visible-padding = 1
    label-urgent = %icon%
    ${if isModular then "label-urgent-background = \${colors.module-bg}" else ""}
    label-urgent-padding = 1

    [module/xworkspaces-vm]
    type = internal/i3
    index-sort = true
    enable-click = true
    enable-scroll = true
    label-focused = %index%
    label-focused-underline = ''${colors.color2}
    label-focused-padding = 1
    label-unfocused = %index%
    label-unfocused-padding = 1
    label-visible = %index%
    label-visible-padding = 1
    label-urgent = %index%
    label-urgent-padding = 1

    ; === HOSTNAME ===
    [module/hostname]
    type = custom/script
    exec = ${hostname}
    interval = 600
    label = %output%
    label-underline = ''${colors.color2}
    format-prefix = "HOST "
    format-prefix-foreground = ''${colors.color3}
    format-prefix-underline = ''${colors.color2}

    [module/vm-hostname]
    type = custom/script
    exec = ${hostname} | ${sed} 's/-vm$//' | ${tr} '[:lower:]' '[:upper:]'
    interval = 600
    label = %output%
    label-underline = ''${colors.color2}
    format-prefix = "VM "
    format-prefix-foreground = ''${colors.color3}
    format-prefix-underline = ''${colors.color2}

    ; === STATIC MODULES (unibar style) ===
    [module/uptime]
    type = custom/script
    exec = ${uptimeCmd} | ${awk} -F, '{sub(".*up ",x,$1);print $1}'
    interval = 100
    label = %output%
    label-underline = ''${colors.color2}
    format-prefix = "UP "
    format-prefix-foreground = ''${colors.color3}
    format-prefix-underline = ''${colors.color2}

    [module/ip]
    type = custom/script
    exec = ${ifconfig} 2>/dev/null | ${grep} -A 1 tun0 | ${grep} inet | ${awk} '{print $2}' || echo ""
    interval = 1
    format = <label>
    format-underline = ''${colors.color2}
    format-prefix = "IP "
    format-prefix-foreground = ''${colors.color3}

    [module/filesystem]
    type = internal/fs
    mount-0 = /
    interval = 30
    fixed-value = false
    spacing = 2
    format-mounted = <label-mounted>
    format-mounted-underline = ''${colors.color2}
    format-mounted-prefix = "FS "
    format-mounted-prefix-foreground = ''${colors.color3}
    format-mounted-prefix-underline = ''${colors.color2}
    label-mounted = %used% / %total%
    label-mounted-underline = ''${colors.color2}

    [module/battery]
    type = internal/battery
    full-at = 99
    low-at = 10
    battery = BAT0
    adapter = ADP1
    poll-interval = 5

    format-discharging = <label-discharging>
    format-discharging-underline = ''${colors.color2}
    format-discharging-prefix = "BAT "
    format-discharging-prefix-foreground = ''${colors.color3}
    format-discharging-prefix-underline = ''${colors.color2}

    format-full = <label-full>
    format-full-underline = ''${colors.color2}
    format-full-prefix = "BAT "
    format-full-prefix-foreground = ''${colors.color3}
    format-full-prefix-underline = ''${colors.color2}

    format-charging = <label-charging>
    format-charging-underline = ''${colors.color2}
    format-charging-prefix = "CHR "
    format-charging-prefix-foreground = ''${colors.color3}
    format-charging-prefix-underline = ''${colors.color2}

    format-low = <label-low>
    format-low-underline = ''${colors.color4}
    format-low-prefix = "BAT LOW "
    format-low-prefix-foreground = ''${colors.color3}
    format-low-prefix-underline = ''${colors.color4}

    [module/essid]
    type = internal/network
    interface = wlo1
    label-connected = %essid%
    label-disconnected = Disconnected
    format-connected-prefix = "NW "
    format-connected-prefix-foreground = ''${colors.color3}
    format-connected-prefix-underline = ''${colors.color2}
    label-connected-underline = ''${colors.color2}
    format-disconnected-prefix = "NW "
    format-disconnected-prefix-foreground = ''${colors.color3}
    format-disconnected-prefix-underline = ''${colors.color2}
    label-disconnected-underline = ''${colors.color2}
    ${if isModular then ''
    format-connected-background = ''${colors.module-bg}
    format-connected-padding = 1
    format-disconnected-background = ''${colors.module-bg}
    format-disconnected-padding = 1
    '' else ""}

    [module/nwup]
    type = internal/network
    interface = wlo1
    label-connected = %upspeed:7%
    label-connected-underline = ''${colors.color2}
    format-connected = <label-connected>
    format-connected-prefix = "UL "
    format-connected-prefix-foreground = ''${colors.color3}
    format-connected-prefix-underline = ''${colors.color2}

    [module/nwdown]
    type = internal/network
    interface = wlo1
    label-connected = %downspeed:7%
    label-connected-underline = ''${colors.color2}
    format-connected = <label-connected>
    format-connected-prefix = "DL "
    format-connected-prefix-foreground = ''${colors.color3}
    format-connected-prefix-underline = ''${colors.color2}

    [module/cpu]
    type = internal/cpu
    interval = 0.5
    format-prefix = "CPU "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %percentage:2%%

    [module/memory]
    type = internal/memory
    interval = 0.5
    format-prefix = "RAM "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %percentage_used%%

    [module/date]
    type = internal/date
    interval = 5
    date = %d/%m/%Y
    time = %H:%M
    format-prefix = "DATE "
    format-prefix-foreground = ''${colors.${if isModular then "prefix" else "color3"}}
    ${if isModular then ''
    format-background = ''${colors.module-bg}
    format-padding = 1
    format-underline = ''${colors.underline}
    '' else ''
    format-underline = ''${colors.color2}
    ''}
    label = %date% %time%

    [module/volume]
    type = custom/script
    exec = ${amixer} sget Master 2>/dev/null | ${awk} -F'[][]' '/Left:/ { print $2 }' || echo 'N/A'
    interval = 0.1
    format = <label>
    format-underline = ''${colors.color2}
    format-prefix = "VOL "
    format-prefix-foreground = ''${colors.color3}

    [module/temp]
    type = custom/script
    exec = ${tempStaticScript}
    interval = 5
    format-prefix = "BLU "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %output%
    click-left = ${tempDownScript}
    click-right = ${tempUpScript}
    click-middle = ${tempResetScript}

    [module/git-changes]
    type = custom/script
    exec = ${git} -C ${config.hydrix.paths.configDir} status --porcelain | ${wc} -l
    interval = 5
    format-prefix = "GIT "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %output%

    [module/vm-count]
    type = custom/script
    exec = ${virsh} --connect qemu:///system list --state-running --name | ${grep} -c . || echo 0
    interval = 10
    format-prefix = "VMS "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %output%

    [module/vm-sync]
    type = custom/script
    exec = vm-sync list 2>/dev/null | ${grep} -c "\[CHANGED\]" || echo 0
    interval = 60
    format-prefix = "SYNC "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %output%

    [module/pomo]
    type = custom/script
    exec = ${pomoStaticScript}
    interval = 1
    format-prefix = "POMO "
    format-prefix-foreground = ''${colors.color3}
    format-underline = ''${colors.color2}
    label = %output%
    click-left = pomo

    ; === DYNAMIC MODULES (modular style with threshold-based underlines) ===
    ; Note: Prefix is included in script output, not format-prefix
    [module/git-dynamic]
    type = custom/script
    exec = ${gitDynamicScript}
    interval = 5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vms-dynamic]
    type = custom/script
    exec = ${vmsDynamicScript}
    interval = 10
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/mvms-dynamic]
    type = custom/script
    exec = ${mvmsDynamicScript}
    interval = 10
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%
    click-left = exec microvm-rofi

    [module/spacer]
    type = custom/text
    content = "  "

    [module/focus]
    type = custom/script
    exec = ${focusStaticScript}
    interval = 2
    format-prefix = "FOCUS "
    format-prefix-foreground = ''${colors.color1}
    format-underline = ''${colors.color1}
    label = %output%

    [module/focus-dynamic]
    type = custom/script
    exec = ${focusDynamicScript}
    interval = 2
    ${if isModular then ''
    format-background = ''${colors.module-bg}
    format-padding = 1
    '' else ""}
    label = %output%

    ${if hasWorkspaceDescriptions then ''
    [module/workspace-desc]
    type = custom/script
    exec = ${workspaceDescScript}
    interval = 0.5
    ${if isModular then ''
    format-background = ''${colors.module-bg}
    format-padding = 1
    '' else ""}
    label = %output%
    '' else ""}

    [module/sync-dynamic]
    type = custom/script
    exec = ${syncDynamicScript}
    interval = 60
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/volume-dynamic]
    type = custom/script
    exec = ${volumeDynamicScript}
    interval = 1
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/ram-dynamic]
    type = custom/script
    exec = ${ramDynamicScript}
    interval = 2
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/cpu-dynamic]
    type = custom/script
    exec = ${cpuDynamicScript}
    interval = 2
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/fs-dynamic]
    type = custom/script
    exec = ${fsDynamicScript}
    interval = 30
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/uptime-dynamic]
    type = custom/script
    exec = ${uptimeDynamicScript}
    interval = 60
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/battery-dynamic]
    type = custom/script
    exec = ${batteryDynamicScript}
    interval = 30
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/date-dynamic]
    type = custom/script
    exec = ${dateDynamicScript}
    interval = 5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/pomo-dynamic]
    type = custom/script
    exec = ${pomoDynamicScript}
    interval = 1
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%
    click-left = pomo

    [module/temp-dynamic]
    type = custom/script
    exec = ${tempDynamicScript}
    interval = 5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%
    click-left = ${tempDownScript}
    click-right = ${tempUpScript}
    click-middle = ${tempResetScript}

    [module/battery-time-dynamic]
    type = custom/script
    exec = ${batteryTimeDynamicScript}
    interval = 30
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    ; === VM-SPECIFIC MODULES ===
    ; These modules run inside VMs and track VM-local resources

    [module/vm-sync-dynamic]
    type = custom/script
    exec = ${vmSyncDynamicScript}
    interval = 10
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-vpn-dynamic]
    type = custom/script
    exec = ${vmVpnDynamicScript}
    interval = 5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-top-dynamic]
    type = custom/script
    exec = ${vmTopDynamicScript}
    interval = 3
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-cpu-dynamic]
    type = custom/script
    exec = ${vmCpuDynamicScript}
    interval = 2
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-ram-dynamic]
    type = custom/script
    exec = ${vmRamDynamicScript}
    interval = 2
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-fs-dynamic]
    type = custom/script
    exec = ${vmFsDynamicScript}
    interval = 30
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    ; === HOST BOTTOM BAR MODULES ===
    ; These modules run on HOST and query VMs via vsock

    [module/power-profile-dynamic]
    type = custom/script
    exec = ${powerProfileDynamicScript}
    interval = 2
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%
    ; Left click: cycle powersave -> balanced -> performance -> powersave
    click-left = ${powerToggleScript}

    [module/cproc-dynamic]
    type = custom/script
    exec = ${hostCpuDynamicScript}
    interval = 3
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/rproc-dynamic]
    type = custom/script
    exec = ${hostRamDynamicScript}
    interval = 3
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/cproc-bottom]
    type = custom/script
    exec = ${guestCpuBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/rproc-bottom]
    type = custom/script
    exec = ${guestRamBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-cpu-bottom]
    type = custom/script
    exec = ${vmCpuBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-ram-bottom]
    type = custom/script
    exec = ${vmRamBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-fs-bottom]
    type = custom/script
    exec = ${vmFsBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-up-bottom]
    type = custom/script
    exec = ${vmUpBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-sync-dev-bottom]
    type = custom/script
    exec = ${vmSyncDevBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-sync-stg-bottom]
    type = custom/script
    exec = ${vmSyncStgBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [module/vm-tun-bottom]
    type = custom/script
    exec = ${vmTunBottomScript}
    interval = 0.5
    format-background = ''${colors.module-bg}
    format-padding = 1
    label = %output%

    [global/wm]
    margin-top = 5
    margin-bottom = 5
  '';

  # Generate polybar config content as a template
  polybarTemplate = pkgs.writeText "polybar-config-template.ini" ''
    ${if isModular then modularTemplate else unibarTemplate}
    ${commonModules}
  '';

in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      # Install polybar package but DON'T use services.polybar
      # display-setup handles startup with runtime DPI scaling
      home.packages = [
        (pkgs.polybar.override { i3Support = true; pulseSupport = true; })
      ];

      # Deploy the template config
      home.file.".config/polybar/config-template.ini".source = polybarTemplate;

      # NOTE: services.polybar is NOT used - display-setup handles startup
      # The polybarTemplate above contains the full config as an INI template
    };
  };
}
