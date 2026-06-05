# Waybar Configuration — Island style
#
# Top LEFT:  workspaces  workspace-desc  focus
# Top RIGHT: pomo  sync  git  mvms  vms  volume  temp  ram  cpu  fs  uptime  clock
# Bot LEFT:  power-profile  battery  battery-time  rproc  cproc
# Bot RIGHT: rproc-bottom  cproc-bottom  vm-ram  vm-cpu  vm-sync-dev  vm-sync-stg  vm-fs  wifi-sync  vm-tun  vm-up
#
# Colors: ~/.config/waybar/colors.css  (written by hypr-apply-colors from wal)
# Scripts: pkgs.writeShellScript → nix store paths
#
# Gap geometry:
#   gaps_in  = gaps/2  (two windows each contribute → visual gap = gaps)
#   gaps_out = gaps    (from screen edge / exclusive zone to window)
#   exclusive-zone = barHeight + gaps  (Hyprland sees bar bottom as usable-area boundary)
#   margin-* = gaps    (screen edge to bar visual edge)
#   Result: uniform gaps px everywhere — screen-to-bar, bar-to-window, window-to-window
#
# To add machine-specific modules (e.g. zenaudio for ASUS ZenBook):
#   Add script + module config to topBar in machines/<serial>.nix using lib.mkAfter,
#   or simply edit this file directly and add them to modules-right.
#
{ config, lib, pkgs, ... }:

let
  username   = config.hydrix.username;
  fontFamily = config.hydrix.graphical.font.family or "Iosevka";
  fontSize   = let base     = config.hydrix.graphical.font.size or 12;
                   relation = config.hydrix.graphical.font.relations.waybar or 1.0;
                   raw      = builtins.floor (base * relation);
               in toString (if raw < 11 then 11 else raw);
  pillRadius  = let ui = config.hydrix.graphical.ui;
                in toString (if ui.pillRadius != null
                             then ui.pillRadius
                             else builtins.floor (ui.cornerRadius * ui.pillRadiusScale));
  pillBorder  = toString (config.hydrix.graphical.ui.border or 2);
  gaps        = config.hydrix.graphical.ui.gaps or 10;
  # pillVMargin = gaps is the key invariant that makes all gaps uniform:
  #   screen→pill-top  = margin-top(0) + pillVMargin     = gaps
  #   pill-bottom→win  = actual_surface - pill_bottom    = pillVMargin = gaps
  #   screen→win-side  = gaps_out                        = gaps
  #   screen→pill-side = margin-left + pillHMargin       = gaps
  #   inner visual     = 2 * gaps_in ≈ gaps (exact for even gaps values)
  pillHMargin = 2;
  pillVMargin = gaps;
  # Island modules float with pillVMargin on each side — bar height scales accordingly
  barHeight   = (config.hydrix.graphical.ui.barHeight or 23) + 2 * pillVMargin;
  homeDir    = "/home/${username}";

  # Hydrix metrics timing
  hostPollInterval = toString (config.hydrix.vmMetrics.hostPollInterval or 5);
  staleThreshold   = toString (config.hydrix.vmMetrics.staleThreshold   or 15);
  configDir        = config.hydrix.paths.configDir or "${homeDir}/hydrix-config";
  barType          = config.hydrix.graphical.waybar.barType or "dualbar";

  shouldActivate = ((config.hydrix.hyprland.enable or false) || (config.hydrix.sway.enable or false))
    && (config.hydrix.graphical.enable or false);
  isVM = (config.hydrix.vmType or null) != null && (config.hydrix.vmType or null) != "host";

  # ── Scripts ───────────────────────────────────────────────────────────────
  # Use pkgs.writeShellScript → clean nix store paths in JSON, no inline escaping.

  workspaceDescScript = pkgs.writeShellScript "waybar-workspace-desc" ''
    ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty')
    [ -z "$ws" ] && exit 0
    VM_REGISTRY="/etc/hydrix/vm-registry.json"
    desc=""
    if [ -f "/tmp/ws-names/$ws" ]; then
      desc=$(cat "/tmp/ws-names/$ws")
    else
      case "$ws" in
        1)  desc="HOST"   ;;
        10) desc="ROUTER" ;;
        *)
          [ -f "$VM_REGISTRY" ] && desc=$(jq -r --argjson w "$ws" \
            'to_entries[] | select(.value.workspace == $w) | .value.label // ""' \
            "$VM_REGISTRY" 2>/dev/null | head -1)
          ;;
      esac
    fi
    [ -n "$desc" ] && echo "$desc"
  '';

  focusScript = pkgs.writeShellScript "waybar-focus" ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    [ -f "$FOCUS_FILE" ] || exit 0
    profile=$(cat "$FOCUS_FILE" | tr '[:lower:]' '[:upper:]')
    [ -n "$profile" ] && echo "FOCUS $profile"
  '';

  pomoScript = pkgs.writeShellScript "waybar-pomo" ''
    STATE_FILE="/tmp/pomodoro_state"
    [ -f "$STATE_FILE" ] || exit 0
    read -r state start_time alert < "$STATE_FILE"
    now=$(date +%s)
    if [[ "$state" == PAUSED_* ]]; then
      remaining="$start_time"
      orig="''${state#PAUSED_}"
      echo "POMO $orig $(printf '%02d:%02d' $((remaining/60)) $((remaining%60))) ⏸"
      exit 0
    fi
    [ "$state" = "WORK" ] && duration=1500 || duration=300
    remaining=$((duration - (now - start_time)))
    if [ "$remaining" -le 0 ]; then
      echo "POMO ''${state}!"
    else
      echo "POMO $state $(printf '%02d:%02d' $((remaining/60)) $((remaining%60)))"
    fi
  '';

  syncScript = pkgs.writeShellScript "waybar-sync" ''
    VM_REGISTRY="/etc/hydrix/vm-registry.json"
    [ -f "$VM_REGISTRY" ] || exit 0
    count=0
    while IFS= read -r profile; do
      vm_name="microvm-$profile"
      systemctl is-active --quiet "microvm@$vm_name.service" 2>/dev/null || continue
      cid=$(jq -r --arg p "$profile" '.[$p].cid // empty' "$VM_REGISTRY" 2>/dev/null)
      [ -z "$cid" ] && continue
      response=$(echo "list" | timeout 2 socat - "VSOCK-CONNECT:$cid:14502" 2>/dev/null)
      [ -z "$response" ] && continue
      n=$(echo "$response" | jq -r '.packages | length' 2>/dev/null) || n=0
      count=$((count + n))
    done < <(jq -r 'keys[]' "$VM_REGISTRY" 2>/dev/null)
    [ "$count" -eq 0 ] && exit 0
    echo "SYNC $count"
  '';

  gitScript = pkgs.writeShellScript "waybar-git" ''
    count=$(git -C ${configDir} status --porcelain 2>/dev/null | wc -l) || count=0
    [ "$count" -ge 10 ] && class="active" || class=""
    ${pkgs.jq}/bin/jq -cn --arg t "GIT $count" --arg c "$class" '{"text":$t,"class":$c}'
  '';

  mvmsScript = pkgs.writeShellScript "waybar-mvms" ''
    count=$(systemctl list-units --type=service --state=running 2>/dev/null \
      | grep -c "microvm@") || count=0
    [ "$count" -eq 0 ] && exit 0
    echo "MVMS $count"
  '';

  vmsScript = pkgs.writeShellScript "waybar-vms" ''
    count=$(${pkgs.libvirt}/bin/virsh --connect qemu:///system list --state-running --name 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -c .) || count=0
    [ "$count" -eq 0 ] && exit 0
    echo "VMS $count"
  '';

  # Host top-CPU process
  cprocDynamicScript = pkgs.writeShellScript "waybar-cproc-dynamic" ''
    top_line=$(${pkgs.procps}/bin/ps aux --sort=-%cpu 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2 {print $11, $3}')
    proc=$(echo "$top_line" | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.gnused}/bin/sed 's:.*/::' | ${pkgs.coreutils}/bin/cut -c1-12 | ${pkgs.coreutils}/bin/tr '[:lower:]' '[:upper:]')
    pct=$(echo "$top_line" | ${pkgs.gawk}/bin/awk '{printf "%.0f", $2}')
    [ -z "$proc" ] && echo "CPROC IDLE" || echo "CPROC $proc $pct%"
  '';

  # Host top-RAM process
  rprocDynamicScript = pkgs.writeShellScript "waybar-rproc-dynamic" ''
    top_line=$(${pkgs.procps}/bin/ps aux --sort=-%mem 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2 {print $11, $6}')
    proc=$(echo "$top_line" | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.gnused}/bin/sed 's:.*/::' | ${pkgs.coreutils}/bin/head -1 | ${pkgs.gnused}/bin/sed 's:.*/::' | ${pkgs.coreutils}/bin/cut -c1-12 | ${pkgs.coreutils}/bin/tr '[:lower:]' '[:upper:]')
    kb=$(echo "$top_line" | ${pkgs.gawk}/bin/awk '{print $2}')
    mb=$((kb / 1024))
    [ -z "$proc" ] && echo "RPROC IDLE" || echo "RPROC $proc ''${mb}M"
  '';

  # VM cache helper: emits nothing if offline/stale; otherwise sets CACHE var and continues
  _vmCacheHeader = ''
    CACHE="/tmp/hydrix-metrics-current"
    [ -f "$CACHE" ] || exit 0
    updated=$(${pkgs.gnugrep}/bin/grep '^updated=' "$CACHE" | ${pkgs.gawk}/bin/awk -F= '{print $2}')
    now=$(${pkgs.coreutils}/bin/date +%s)
    [ -z "$updated" ] || [ $((now - updated)) -gt ${staleThreshold} ] && exit 0
    vm_online=$(${pkgs.gnugrep}/bin/grep '^vm_online=' "$CACHE" | ${pkgs.gawk}/bin/awk -F= '{print $2}')
    [ "$vm_online" != "1" ] && exit 0
  '';

  cprocBottomScript = pkgs.writeShellScript "waybar-cproc-bottom" ''
    ${_vmCacheHeader}
    val=$(grep '^top=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$val" ] && exit 0
    proc=$(echo "$val" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]' | cut -c1-12)
    pct=$(echo "$val" | cut -d' ' -f2)
    echo "CPROC $proc $pct%"
  '';

  rprocBottomScript = pkgs.writeShellScript "waybar-rproc-bottom" ''
    ${_vmCacheHeader}
    val=$(grep '^topmem=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$val" ] && exit 0
    proc=$(echo "$val" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]' | cut -c1-12)
    ram=$(echo "$val" | cut -d' ' -f2)
    echo "RPROC $proc ''${ram}MB"
  '';

  vmCpuScript = pkgs.writeShellScript "waybar-vm-cpu" ''
    ${_vmCacheHeader}
    cpu=$(grep '^cpu=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$cpu" ] && exit 0
    echo "CPU $cpu%"
  '';

  vmRamScript = pkgs.writeShellScript "waybar-vm-ram" ''
    ${_vmCacheHeader}
    ram=$(grep '^ram=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$ram" ] && exit 0
    echo "RAM ''${ram}MB"
  '';

  vmFsScript = pkgs.writeShellScript "waybar-vm-fs" ''
    ${_vmCacheHeader}
    fs=$(grep '^fs=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$fs" ] && exit 0
    echo "FS $fs%"
  '';

  vmSyncDevScript = pkgs.writeShellScript "waybar-vm-sync-dev" ''
    ${_vmCacheHeader}
    dev=$(grep '^syncdev=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$dev" ] && exit 0
    echo "DEV $dev"
  '';

  vmSyncStgScript = pkgs.writeShellScript "waybar-vm-sync-stg" ''
    ${_vmCacheHeader}
    stg=$(grep '^syncstg=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$stg" ] && exit 0
    echo "STG $stg"
  '';

  vmTunScript = pkgs.writeShellScript "waybar-vm-tun" ''
    ${_vmCacheHeader}
    tun=$(grep '^tun=' "$CACHE" | awk -F= '{print $2}')
    [ -n "$tun" ] && [ "$tun" != "none" ] && echo "TUN $tun"
  '';

  vmUpScript = pkgs.writeShellScript "waybar-vm-up" ''
    ${_vmCacheHeader}
    up=$(grep '^uptime=' "$CACHE" | awk -F= '{print $2}')
    [ -n "$up" ] && echo "UP $up"
  '';

  # VM metrics poller — polls current workspace VM every hostPollInterval seconds.
  # Writes per-VM files to /tmp/hydrix-metrics-<profile> and maintains a
  # /tmp/hydrix-metrics-current symlink that all VM modules read from.
  vmPollerScript = pkgs.writeShellScript "hydrix-vm-poller" ''
    VM_REGISTRY="/etc/hydrix/vm-registry.json"
    CURRENT_LINK="/tmp/hydrix-metrics-current"

    _get_workspace() {
      # Runtime detection: Hyprland sets HYPRLAND_INSTANCE_SIGNATURE, Sway sets SWAYSOCK
      if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        ${pkgs.hyprland}/bin/hyprctl activeworkspace -j 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '.id // empty' | ${pkgs.coreutils}/bin/head -1
      else
        ${pkgs.sway}/bin/swaymsg -t get_workspaces 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .num' | ${pkgs.coreutils}/bin/head -1
      fi
    }

    while true; do
      ws=$(_get_workspace)

      if [ -z "$ws" ] || ! printf '%s' "$ws" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+$'; then
        ${pkgs.coreutils}/bin/rm -f "$CURRENT_LINK"
        ${pkgs.coreutils}/bin/sleep ${hostPollInterval}
        continue
      fi

      # Focus mode: if set, poll the focused VM type regardless of current workspace
      profile="" cid="" vm_name=""
      FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
      if [ -f "$FOCUS_FILE" ]; then
        focus_type=$(cat "$FOCUS_FILE")
        profile=$(${pkgs.jq}/bin/jq -r --arg t "$focus_type" \
          'to_entries[] | select(.key == $t) | .key' \
          "$VM_REGISTRY" 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
        cid=$(${pkgs.jq}/bin/jq -r --arg t "$focus_type" \
          'to_entries[] | select(.key == $t) | .value.cid' \
          "$VM_REGISTRY" 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
        vm_name=$(${pkgs.jq}/bin/jq -r --arg t "$focus_type" \
          'to_entries[] | select(.key == $t) | .value.vmName' \
          "$VM_REGISTRY" 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
      fi

      # Fall back to workspace-based lookup if focus mode is off or type not found
      if [ -z "$profile" ] || [ "$profile" = "null" ]; then
        profile=$(${pkgs.jq}/bin/jq -r --argjson w "$ws" \
          'to_entries[] | select(.value.workspace == $w) | .key' \
          "$VM_REGISTRY" 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
        cid=$(${pkgs.jq}/bin/jq -r --argjson w "$ws" \
          'to_entries[] | select(.value.workspace == $w) | .value.cid' \
          "$VM_REGISTRY" 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
        vm_name=$(${pkgs.jq}/bin/jq -r --argjson w "$ws" \
          'to_entries[] | select(.value.workspace == $w) | .value.vmName' \
          "$VM_REGISTRY" 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
      fi

      if [ -z "$profile" ] || [ "$profile" = "null" ]; then
        ${pkgs.coreutils}/bin/rm -f "$CURRENT_LINK"
        ${pkgs.coreutils}/bin/sleep ${hostPollInterval}
        continue
      fi

      metric_file="/tmp/hydrix-metrics-$profile"
      tmp_file="$metric_file.tmp"
      now=$(${pkgs.coreutils}/bin/date +%s)

      if ! /run/current-system/sw/bin/systemctl is-active --quiet "microvm@$vm_name" 2>/dev/null; then
        printf 'ws=%s\ncid=%s\nvm_name=%s\nvm_online=0\nupdated=%s\n' \
          "$ws" "$cid" "$vm_name" "$now" > "$tmp_file"
        ${pkgs.coreutils}/bin/mv "$tmp_file" "$metric_file"
        ${pkgs.coreutils}/bin/ln -sfn "$metric_file" "$CURRENT_LINK"
        ${pkgs.coreutils}/bin/sleep ${hostPollInterval}
        continue
      fi

      response=$(echo "all" | ${pkgs.coreutils}/bin/timeout 1 ${pkgs.socat}/bin/socat - "VSOCK-CONNECT:$cid:14501" 2>/dev/null)
      if [ -n "$response" ]; then
        { printf 'ws=%s\ncid=%s\nvm_name=%s\nvm_online=1\n' "$ws" "$cid" "$vm_name"
          printf '%s\n' "$response"
          printf 'updated=%s\n' "$now"
        } > "$tmp_file"
      else
        printf 'ws=%s\ncid=%s\nvm_name=%s\nvm_online=0\nupdated=%s\n' \
          "$ws" "$cid" "$vm_name" "$now" > "$tmp_file"
      fi
      ${pkgs.coreutils}/bin/mv "$tmp_file" "$metric_file"
      ${pkgs.coreutils}/bin/ln -sfn "$metric_file" "$CURRENT_LINK"

      ${pkgs.coreutils}/bin/sleep ${hostPollInterval}
    done
  '';

  wifiSyncScript = pkgs.writeShellScript "waybar-wifi-sync" ''
    ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty')
    [ "$ws" != "10" ] && exit 0
    result=$(echo "POLL" | timeout 1 socat - VSOCK-CONNECT:200:14506 2>/dev/null)
    [ -z "$result" ] && exit 0
    count=$(echo "$result" | jq '.networks | length' 2>/dev/null || echo "0")
    local_ssid=$(grep -oP 'ssid\s*=\s*"\K[^"]+' "${homeDir}/hydrix-config/modules/wifi.nix" 2>/dev/null | head -1 || echo "")
    router_ssid=$(echo "$result" | jq -r '.networks[0].ssid // ""' 2>/dev/null)
    [ -z "$router_ssid" ] && exit 0
    [ "$router_ssid" != "$local_ssid" ] && echo "WIFI! $count" || echo "WIFI $count"
  '';

  batteryTimeScript = pkgs.writeShellScript "waybar-battery-time" ''
    status=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
    [ "$status" != "Discharging" ] && exit 0
    mins=$(cat /sys/class/power_supply/BAT*/time_to_empty_now 2>/dev/null | head -1)
    [ -n "$mins" ] && [ "$mins" -gt 0 ] && printf '%dh%02dm\n' "$((mins/60))" "$((mins%60))"
  '';

  powerProfileScript = pkgs.writeShellScript "waybar-power-profile" ''
    profile=$(powerprofilesctl get 2>/dev/null \
      || cat /sys/firmware/acpi/platform_profile 2>/dev/null \
      || echo "?")
    case "$profile" in
      performance) echo "PWR PERF" ;;
      balanced)    echo "PWR BAL"  ;;
      power-saver|low-power) echo "PWR SAVE" ;;
      *)           echo "PWR $profile" ;;
    esac
  '';

  hostCpuScript = pkgs.writeShellScript "waybar-host-cpu" ''
    cpu=$(${pkgs.procps}/bin/vmstat 1 2 | awk 'END{printf "%.0f", 100-$15}')
    if   [ "$cpu" -ge 75 ]; then class="high"
    elif [ "$cpu" -ge 50 ]; then class="medium"
    else class=""
    fi
    ${pkgs.jq}/bin/jq -cn --arg t "CPU $cpu%" --arg c "$class" '{"text":$t,"class":$c}'
  '';

  hostMemScript = pkgs.writeShellScript "waybar-host-mem" ''
    pct=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%.0f", (t-a)*100/t}' /proc/meminfo)
    if   [ "$pct" -ge 75 ]; then class="high"
    elif [ "$pct" -ge 50 ]; then class="medium"
    else class=""
    fi
    ${pkgs.jq}/bin/jq -cn --arg t "RAM $pct%" --arg c "$class" '{"text":$t,"class":$c}'
  '';

  tempScript = pkgs.writeShellScript "waybar-temp" ''
    temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null \
      | ${pkgs.coreutils}/bin/sort -rn | head -1)
    [ -z "$temp" ] && exit 0
    temp=$((temp / 1000))
    [ "$temp" -ge 80 ] && echo "TEMP $temp°C!" || echo "TEMP $temp°C"
  '';

  diskScript = pkgs.writeShellScript "waybar-disk" ''
    pct=$(${pkgs.coreutils}/bin/df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    echo "FS $pct%"
  '';

  uptimeScript = pkgs.writeShellScript "waybar-uptime" ''
    up=$(awk '{s=int($1); h=int(s/3600); m=int((s%3600)/60); printf "%dh%02dm", h, m}' /proc/uptime)
    echo "UP $up"
  '';

  clockScript = pkgs.writeShellScript "waybar-clock" ''
    echo "DATE $(${pkgs.coreutils}/bin/date +'%H:%M %d/%m')"
  '';

  volumeScript = pkgs.writeShellScript "waybar-volume" ''
    vol=$(${pkgs.pulseaudio}/bin/pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -oP '\d+(?=%)' | head -1)
    [ -z "$vol" ] && exit 0
    if ${pkgs.pulseaudio}/bin/pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null \
         | ${pkgs.gnugrep}/bin/grep -q 'yes'; then
      echo "VOL MUTED"
    else
      echo "VOL $vol%"
    fi
  '';

  batteryScript = pkgs.writeShellScript "waybar-battery" ''
    cap=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
    status=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
    [ -z "$cap" ] && exit 0
    case "$status" in
      Charging) lbl="CHR"; class="charging" ;;
      Full)     lbl="BAT"; class="full" ;;
      *)
        lbl="BAT"
        if   [ "$cap" -le 5 ];  then class="critical"
        elif [ "$cap" -le 15 ]; then class="warning"
        else class=""
        fi ;;
    esac
    ${pkgs.jq}/bin/jq -cn --arg t "$lbl $cap%" --arg c "$class" '{"text":$t,"class":$c}'
  '';

  # ── Monobar conditional variants ─────────────────────────────────────────
  # These scripts gate output on thresholds — waybar hides the pill when silent.

  monoGitScript = pkgs.writeShellScript "waybar-mono-git" ''
    count=$(git -C ${configDir} status --porcelain 2>/dev/null | wc -l) || count=0
    [ "$count" -lt 10 ] && exit 0
    ${pkgs.jq}/bin/jq -cn --arg t "GIT $count" --arg c "active" '{"text":$t,"class":$c}'
  '';

  monoTempScript = pkgs.writeShellScript "waybar-mono-temp" ''
    temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null \
      | ${pkgs.coreutils}/bin/sort -rn | head -1)
    [ -z "$temp" ] && exit 0
    temp=$((temp / 1000))
    [ "$temp" -lt 70 ] && exit 0
    [ "$temp" -ge 80 ] && echo "TEMP $temp°C!" || echo "TEMP $temp°C"
  '';

  monoUptimeScript = pkgs.writeShellScript "waybar-mono-uptime" ''
    secs=$(${pkgs.gawk}/bin/awk '{printf "%d", $1}' /proc/uptime)
    [ "$secs" -lt 86400 ] && exit 0
    printf 'UP %dh%02dm\n' "$((secs/3600))" "$(( (secs%3600)/60 ))"
  '';

  monoVmFsScript = pkgs.writeShellScript "waybar-mono-vm-fs" ''
    ${_vmCacheHeader}
    fs=$(grep '^fs=' "$CACHE" | awk -F= '{print $2}')
    [ -z "$fs" ] && exit 0
    [ "$fs" -lt 50 ] && exit 0
    echo "FS $fs%"
  '';

  monoBatteryScript = pkgs.writeShellScript "waybar-mono-battery" ''
    cap=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
    status=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
    [ -z "$cap" ] && exit 0
    case "$status" in
      Charging) lbl="CHR"; class="charging" ;;
      Full)     lbl="BAT"; class="full" ;;
      *)
        lbl="BAT"
        if   [ "$cap" -ge 80 ]; then class="full"
        elif [ "$cap" -le 5 ];  then class="critical"
        elif [ "$cap" -le 15 ]; then class="warning"
        else class=""
        fi ;;
    esac
    ${pkgs.jq}/bin/jq -cn --arg t "$lbl $cap%" --arg c "$class" '{"text":$t,"class":$c}'
  '';

  # ── Bar layouts ────────────────────────────────────────────────────────────

  topBar = {
    "reload_style_on_change" = false;
    layer    = "top";
    position = "top";
    height   = barHeight;
    spacing  = 0;
    "exclusive-zone" = barHeight + gaps - 2 * pillVMargin;
    "margin-top"     = gaps - pillVMargin;
    "margin-left"    = gaps - pillHMargin;
    "margin-right"   = gaps - pillHMargin;

    "modules-left"   = [
      "hyprland/workspaces"
      "custom/workspace-desc"
      "custom/sep"
      #"hyprland/window"
      "custom/focus"
    ];
    "modules-center" = [];
    "modules-right"  = [
      "custom/pomo"
      "custom/sync"
      "custom/sep"
      "custom/git"
      "custom/mvms"
      "custom/vms"
      "custom/sep"
      "custom/volume"
      "custom/sep"
      "custom/temp"
      "custom/sep"
      "custom/memory"
      "custom/cpu"
      "custom/sep"
      "custom/disk"
      "custom/uptime"
      "custom/sep"
      "custom/clock"
    ];

    "hyprland/workspaces" = {
      "disable-scroll" = true;
      format = "{name}";
      "on-click" = "activate";
      "sort-by-number" = true;
    };

    "custom/workspace-desc" = { exec = "${workspaceDescScript}"; interval = 1;  format = "{}"; tooltip = false; escape = false; };
    "hyprland/window"       = { format = "{}"; "max-length" = 60; "separate-outputs" = false; tooltip = false; };
    "custom/focus"          = { exec = "${focusScript}";         interval = 1;  format = "{}"; tooltip = false; escape = false; };
    "custom/pomo"           = { exec = "${pomoScript}";          interval = 1;  format = "{}"; tooltip = false; escape = false; };
    "custom/sync"           = { exec = "${syncScript}";          interval = 30; format = "{}"; tooltip = false; escape = false; };
    "custom/git"            = { exec = "${gitScript}";           interval = 30; format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/mvms"           = { exec = "${mvmsScript}";          interval = 5;  format = "{}"; tooltip = false; escape = false; };
    "custom/vms"            = { exec = "${vmsScript}";           interval = 10; format = "{}"; tooltip = false; escape = false; };
    "custom/sep"            = { exec = "echo '|'"; interval = "once"; format = "{}"; tooltip = false; };

    "custom/volume" = { exec = "${volumeScript}"; interval = 5; format = "{}"; tooltip = false; escape = false; "on-click" = "pavucontrol"; "on-scroll-up" = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +5%"; "on-scroll-down" = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -5%"; };
    "custom/temp"   = { exec = "${tempScript}";    interval = 5;  format = "{}"; tooltip = false; escape = false; };
    "custom/memory" = { exec = "${hostMemScript}"; interval = 5;  format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/cpu"    = { exec = "${hostCpuScript}"; interval = 5;  format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/disk"   = { exec = "${diskScript}";    interval = 30; format = "{}"; tooltip = false; escape = false; };
    "custom/uptime" = { exec = "${uptimeScript}";  interval = 60; format = "{}"; tooltip = false; escape = false; };
    "custom/clock"  = { exec = "${clockScript}";   interval = 60; format = "{}"; tooltip = false; escape = false; };
  };

  bottomBar = {
    "reload_style_on_change" = false;
    layer    = "top";
    position = "bottom";
    height   = barHeight;
    spacing  = 0;
    "exclusive-zone" = barHeight + gaps - 2 * pillVMargin;
    "margin-bottom"  = gaps - pillVMargin;
    "margin-left"    = gaps - pillHMargin;
    "margin-right"   = gaps - pillHMargin;

    "modules-left"   = [
      "custom/power-profile"
      "custom/battery"
      "custom/battery-time"
      "custom/sep"
      "custom/rproc"
      "custom/cproc"
    ];
    "modules-center" = [];
    "modules-right"  = [
      "custom/rproc-bottom"
      "custom/cproc-bottom"
      "custom/sep"
      "custom/vm-ram"
      "custom/vm-cpu"
      "custom/vm-sync-dev"
      "custom/vm-sync-stg"
      "custom/vm-fs"
      "custom/sep"
      "custom/wifi-sync"
      "custom/vm-tun"
      "custom/vm-up"
    ];

    "custom/battery" = { exec = "${batteryScript}"; interval = 30; format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };

    "custom/power-profile" = { exec = "${powerProfileScript}"; interval = 10; format = "{}"; tooltip = false; escape = false; };
    "custom/battery-time"  = { exec = "${batteryTimeScript}";  interval = 60; format = "{}"; tooltip = false; escape = false; };
    "custom/sep"           = { exec = "echo '|'"; interval = "once"; format = "{}"; tooltip = false; };
    "custom/rproc"         = { exec = "${rprocDynamicScript}"; interval = 3;  format = "{}"; tooltip = false; escape = false; };
    "custom/cproc"         = { exec = "${cprocDynamicScript}"; interval = 3;  format = "{}"; tooltip = false; escape = false; };
    "custom/rproc-bottom"  = { exec = "${rprocBottomScript}";  interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/cproc-bottom"  = { exec = "${cprocBottomScript}";  interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-cpu"        = { exec = "${vmCpuScript}";        interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-ram"        = { exec = "${vmRamScript}";        interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-fs"         = { exec = "${vmFsScript}";         interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-sync-dev"   = { exec = "${vmSyncDevScript}";    interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-sync-stg"   = { exec = "${vmSyncStgScript}";    interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-tun"        = { exec = "${vmTunScript}";        interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-up"         = { exec = "${vmUpScript}";         interval = 30; format = "{}"; tooltip = false; escape = false; };
    "custom/wifi-sync"     = { exec = "${wifiSyncScript}";     interval = 10; format = "{}"; tooltip = false; escape = false; };
  };

  monoBar = {
    "reload_style_on_change" = false;
    layer    = "top";
    position = "top";
    height   = barHeight;
    spacing  = 0;
    "exclusive-zone" = barHeight + gaps - 2 * pillVMargin;
    "margin-top"     = gaps - pillVMargin;
    "margin-left"    = gaps - pillHMargin;
    "margin-right"   = gaps - pillHMargin;

    "modules-left"   = [
      "hyprland/workspaces"
      "custom/workspace-desc"
      "custom/focus"
    ];
    "modules-center" = [];
    "modules-right"  = [
      "custom/pomo"
      "custom/sync"
      "custom/sep"
      "custom/git"
      "custom/mvms"
      "custom/vms"
      "custom/sep"
      "custom/volume"
      "custom/bluetooth"
      "custom/sep"
      "custom/temp"
      "custom/memory"
      "custom/cpu"
      "custom/sep"
      "custom/disk"
      "custom/uptime"
      "custom/sep"
      "custom/power-profile"
      "custom/battery"
      "custom/battery-time"
      "custom/sep"
      "custom/vm-cpu"
      "custom/vm-ram"
      "custom/vm-fs"
      "custom/vm-sync-dev"
      "custom/vm-sync-stg"
      "custom/vm-tun"
      "custom/vm-up"
      "custom/sep"
      "custom/wifi-sync"
      "custom/sep"
      "custom/clock"
    ];

    "hyprland/workspaces" = {
      "disable-scroll" = true;
      format = "{name}";
      "on-click" = "activate";
      "sort-by-number" = true;
    };

    "custom/workspace-desc" = { exec = "${workspaceDescScript}"; interval = 1;  format = "{}"; tooltip = false; escape = false; };
    "custom/focus"          = { exec = "${focusScript}";         interval = 1;  format = "{}"; tooltip = false; escape = false; };
    "custom/pomo"           = { exec = "${pomoScript}";          interval = 1;  format = "{}"; tooltip = false; escape = false; };
    "custom/sync"           = { exec = "${syncScript}";          interval = 30; format = "{}"; tooltip = false; escape = false; };
    "custom/git"            = { exec = "${monoGitScript}";       interval = 30; format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/mvms"           = { exec = "${mvmsScript}";          interval = 5;  format = "{}"; tooltip = false; escape = false; };
    "custom/vms"            = { exec = "${vmsScript}";           interval = 10; format = "{}"; tooltip = false; escape = false; };
    "custom/sep"            = { exec = "echo '|'"; interval = "once"; format = "{}"; tooltip = false; };
    "custom/volume"    = { exec = "${volumeScript}";    interval = 5;  format = "{}"; tooltip = false; escape = false; "on-click" = "pavucontrol"; "on-scroll-up" = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +5%"; "on-scroll-down" = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -5%"; };
    "custom/bluetooth" = { exec = "${bluetoothScript}"; interval = 10; format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/temp"      = { exec = "${monoTempScript}";  interval = 5;  format = "{}"; tooltip = false; escape = false; };
    "custom/memory"    = { exec = "${hostMemScript}";   interval = 5;  format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/cpu"       = { exec = "${hostCpuScript}";   interval = 5;  format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/disk"      = { exec = "${diskScript}";      interval = 30; format = "{}"; tooltip = false; escape = false; };
    "custom/uptime"    = { exec = "${monoUptimeScript}";interval = 60; format = "{}"; tooltip = false; escape = false; };
    "custom/clock"     = { exec = "${clockScript}";     interval = 60; format = "{}"; tooltip = false; escape = false; };
    "custom/power-profile" = { exec = "${powerProfileScript}"; interval = 10; format = "{}"; tooltip = false; escape = false; };
    "custom/battery"       = { exec = "${monoBatteryScript}";  interval = 30; format = "{}"; tooltip = false; escape = false; "return-type" = "json"; };
    "custom/battery-time"  = { exec = "${batteryTimeScript}";  interval = 60; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-cpu"      = { exec = "${vmCpuScript}";     interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-ram"      = { exec = "${vmRamScript}";     interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-fs"       = { exec = "${monoVmFsScript}";  interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-sync-dev" = { exec = "${vmSyncDevScript}"; interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-sync-stg" = { exec = "${vmSyncStgScript}"; interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-tun"      = { exec = "${vmTunScript}";     interval = lib.toInt hostPollInterval; format = "{}"; tooltip = false; escape = false; };
    "custom/vm-up"       = { exec = "${vmUpScript}";      interval = 30;                        format = "{}"; tooltip = false; escape = false; };
    "custom/wifi-sync"   = { exec = "${wifiSyncScript}";  interval = 10;                        format = "{}"; tooltip = false; escape = false; };
  };

  configJson = builtins.toJSON (
    if barType == "monobar" then [ monoBar ]
    else [ topBar bottomBar ]
  );

  defaultColorsCSS = ''
    @define-color background #0c0c0c;
    @define-color foreground #d8dee9;
    @define-color accent     #7aa2f7;
    @define-color alert      #bf616a;
    @define-color color6     #5e81ac;
    @define-color color8     #4c566a;
  '';

  styleCSS = ''
    @import url("file://${homeDir}/.config/waybar/colors.css");

    * {
      font-family: ${fontFamily}, monospace;
      font-size: ${fontSize}px;
      border: none;
      border-radius: 0;
      min-height: 0;
      padding: 0;
      margin: 0;
    }

    /* Transparent bar — modules provide all visual weight */
    window#waybar {
      background: transparent;
    }

    /* Hide window title pill when no window is focused */
    window#waybar.empty #window {
      background: transparent;
      border-color: transparent;
      color: transparent;
      padding: 0;
      margin: 0;
    }

    /* ── Separator — spacing only, no visible glyph ─────────────────── */
    #custom-sep {
      background: transparent;
      border: none;
      color: transparent;
      font-size: 10px;
      padding: 0 2px;
      margin: 5px 4px;
      border-radius: ${pillRadius}px;
    }

    /* ── Island pill — default style for all modules ─────────────────── *
     *                                                                     *
     *  Color semantics:                                                   *
     *   @accent     — active time state: clock (anchor), pomo (timer)    *
     *   @alert      — needs action: focus mode active, staged packages    *
     *   @color8     — VM-sourced data: dim border distinguishes from host *
     *   @foreground — all neutral informational modules (default below)   *
     * ──────────────────────────────────────────────────────────────────── */
    #workspaces,
    #custom-clock,
    #custom-cpu,
    #custom-memory,
    #custom-temp,
    #custom-disk,
    #custom-volume,
    #custom-uptime,
    #custom-workspace-desc,
    #window,
    #custom-focus,
    #custom-pomo,
    #custom-sync,
    #custom-git,
    #custom-mvms,
    #custom-vms,
    #custom-power-profile,
    #custom-battery-time,
    #custom-rproc,
    #custom-cproc,
    #custom-rproc-bottom,
    #custom-cproc-bottom,
    #custom-vm-cpu,
    #custom-vm-ram,
    #custom-vm-fs,
    #custom-vm-sync-dev,
    #custom-vm-sync-stg,
    #custom-vm-tun,
    #custom-vm-up,
    #custom-wifi-sync {
      background: @background;
      color: @foreground;
      border: ${pillBorder}px solid alpha(@foreground, 0.25);
      border-radius: ${pillRadius}px;
      padding: 2px 14px;
      margin: ${toString pillVMargin}px ${toString pillHMargin}px;
    }

    /* Battery — standard pill; fills on low/charging states */
    #custom-battery {
      background: @background;
      color: @foreground;
      border: ${pillBorder}px solid alpha(@foreground, 0.25);
      border-radius: ${pillRadius}px;
      padding: 2px 14px;
      margin: ${toString pillVMargin}px ${toString pillHMargin}px;
    }

    #custom-battery.warning  { background: @color8; color: @background; border-color: @color8; }
    #custom-battery.critical { background: @alert;  color: @background; border-color: @alert;  }
    #custom-battery.charging { background: @accent; color: @background; border-color: @accent; }
    #custom-battery.full     { background: @accent; color: @background; border-color: @accent; }

    /* @accent — clock (time anchor) and pomo (active timer) */
    #custom-clock { color: @accent; border-color: alpha(@accent, 0.45); }
    #custom-pomo  { color: @accent; border-color: alpha(@accent, 0.45); }

    /* @alert — requires attention or action */
    #custom-focus { background: @accent; color: @background; border-color: @accent; }
    #custom-sync  { color: @alert; border-color: alpha(@alert, 0.45); }

    /* GIT active — DATE colors when ≥10 uncommitted */
    #custom-git.active { color: @accent; border-color: alpha(@accent, 0.45); }

    /* CPU / RAM — foreground at normal, accent at ≥50%, alert fill at ≥75% */
    #custom-cpu.medium,
    #custom-memory.medium { color: @accent; border-color: alpha(@accent, 0.45); }
    #custom-cpu.high,
    #custom-memory.high   { background: @alert; color: @background; border-color: @alert; }

    /* @color6 border — VM-sourced metrics (distinguishes VM data from host) */
    #custom-rproc-bottom,
    #custom-cproc-bottom,
    #custom-vm-cpu,
    #custom-vm-ram,
    #custom-vm-fs,
    #custom-vm-sync-dev,
    #custom-vm-sync-stg,
    #custom-vm-tun,
    #custom-vm-up,
    #custom-wifi-sync { border-color: alpha(@color6, 0.6); }

    /* Hover: invert any pill */
    #custom-clock:hover,
    #custom-cpu:hover,
    #custom-memory:hover,
    #custom-temp:hover,
    #custom-disk:hover,
    #custom-volume:hover,
    #custom-uptime:hover,
    #custom-workspace-desc:hover,
    #window:hover,
    #custom-focus:hover,
    #custom-pomo:hover,
    #custom-sync:hover,
    #custom-git:hover,
    #custom-mvms:hover,
    #custom-vms:hover,
    #custom-power-profile:hover,
    #custom-battery:hover,
    #custom-battery-time:hover,
    #custom-rproc:hover,
    #custom-cproc:hover,
    #custom-rproc-bottom:hover,
    #custom-cproc-bottom:hover,
    #custom-vm-cpu:hover,
    #custom-vm-ram:hover,
    #custom-vm-fs:hover,
    #custom-vm-sync-dev:hover,
    #custom-vm-sync-stg:hover,
    #custom-vm-tun:hover,
    #custom-vm-up:hover,
    #custom-wifi-sync:hover {
      background: alpha(@foreground, 0.9);
      color: @background;
      transition: 0.3s;
    }

    /* ── Workspaces ──────────────────────────────────────────────────── */
    #workspaces { padding: 0; }
    #custom-workspace-desc { margin-right: 14px; }

    #workspaces button {
      all: initial;
      font-family: ${fontFamily}, monospace;
      font-size: ${fontSize}px;
      padding: 2px 12px;
      color: @foreground;
      background: transparent;
      border-right: 1px solid alpha(@foreground, 0.2);
    }

    #workspaces button.active  { background: @accent; color: @background; border-color: @accent; }
    #workspaces button.empty   { color: alpha(@foreground, 0.35); }
    #workspaces button:hover   { background: alpha(@foreground, 0.9); color: @background; transition: 0.3s; }

    #workspaces button:first-child             { border-radius: ${pillRadius}px 0 0 ${pillRadius}px; }
    #workspaces button:last-child              { border-radius: 0 ${pillRadius}px ${pillRadius}px 0; border-right: none; }
    #workspaces button:first-child:last-child  { border-radius: ${pillRadius}px; }

    /* Tooltip */
    tooltip {
      border-radius: ${pillRadius}px;
      background: @background;
      border: ${pillBorder}px solid alpha(@foreground, 0.4);
      color: @foreground;
    }
  '';

  # Script that seeds waybar config files on first session — same content as the
  # home.activation hook but runs as a user service before waybar starts, ensuring
  # the files exist even when home-manager activation races with session startup.
  waybarInitScript = pkgs.writeShellScript "waybar-init" ''
    _dir="$HOME/.config/waybar"
    mkdir -p "$_dir"
    # Write only if absent — home.activation.waybarFiles owns structural updates on rebuild.
    [ -f "$_dir/config" ]     || printf '%s' ${lib.escapeShellArg configJson} > "$_dir/config"
    [ -f "$_dir/style.css" ]  || printf '%s' ${lib.escapeShellArg styleCSS} > "$_dir/style.css"
    [ -f "$_dir/colors.css" ] || printf '%s' ${lib.escapeShellArg defaultColorsCSS} > "$_dir/colors.css"
  '';

in {
  options.hydrix.graphical.waybar = {
    barType = lib.mkOption {
      type    = lib.types.enum [ "dualbar" "monobar" ];
      default = "dualbar";
      description = ''
        Waybar layout profile.
        dualbar — top + bottom bars, all modules always visible.
        monobar  — single top bar; conditional modules hide below threshold.
      '';
    };
  };

  config = lib.mkIf shouldActivate {
  home-manager.users.${username} = { lib, ... }: {
    # All three waybar files are written as mutable regular files — not nix store symlinks.
    # This allows live editing (waybar reloads CSS on SIGUSR2, config on restart).
    # Delete a file to have the next rebuild regenerate it from Nix.
    home.activation.waybarFiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
      _dir="$HOME/.config/waybar"
      mkdir -p "$_dir"

      # config — remove any stale nix store symlink, always write (structural changes must apply)
      [ -L "$_dir/config" ] && rm -f "$_dir/config"
      printf '%s' ${lib.escapeShellArg configJson} > "$_dir/config"

      # style.css — always regenerate (structural changes must apply)
      [ -L "$_dir/style.css" ] && rm -f "$_dir/style.css"
      printf '%s' ${lib.escapeShellArg styleCSS} > "$_dir/style.css"

      # colors.css — only write default if absent (hypr-apply-colors owns this file)
      if [ ! -f "$_dir/colors.css" ]; then
        printf '%s' ${lib.escapeShellArg defaultColorsCSS} > "$_dir/colors.css"
      fi
    '';

    # Seeds waybar config files before waybar starts — guards against the race where
    # home-manager activation (system service) hasn't written configs yet on first boot.
    systemd.user.services.waybar-init = {
      Unit = {
        Description = "Seed waybar config files for first session";
        Before = [ "waybar.service" ];
      };
      Service = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart       = "${waybarInitScript}";
      };
      Install.WantedBy = [ "waybar.service" ];
    };

    # Waybar — managed by systemd so lifecycle is serialised (no pkill races).
    # Started by hyprland-session.target; restarted by waybar-monitor-watch on monitor events.
    systemd.user.services.waybar = lib.mkIf shouldActivate {
      Unit = {
        Description = "Waybar status bar";
        After       = [ "hyprland-session.target" "waybar-init.service" ];
        PartOf      = [ "hyprland-session.target" ];
      };
      Service = {
        Type       = "simple";
        ExecStart  = "${pkgs.waybar}/bin/waybar";
        Restart    = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };

    # VM metrics poller: polls current workspace VM and writes /tmp/hydrix-metrics-current
    # so that all VM bottom-bar modules (vm-cpu, vm-ram, rproc-bottom, etc.) have data.
    systemd.user.services.hydrix-vm-poller = lib.mkIf (!isVM) {
      Unit = {
        Description = "Hydrix VM metrics poller";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${vmPollerScript}";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
  }; # config
}
