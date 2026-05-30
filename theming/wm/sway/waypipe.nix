# waypipe host-side module
#
# Provides:
#   waypipe-connect   — connect to a VM's waypipe server (run once per VM)
#   hypr-ws-app       — workspace-aware app launcher (replaces ws-app for Hyprland)
#   vm-push-display-mode — detect WM and push xpra/waypipe mode to VMs
#
# Usage:
#   waypipe-connect microvm-browsing     # start forwarding (keep running)
#   hypr-ws-app alacritty               # launch in VM assigned to current workspace
#   hypr-ws-app firefox https://foo.com # same with args
#
# Architecture:
#   VM:   waypipe --vsock --socket s14507 server  (listens on vsock:14507)
#   HOST: waypipe --vsock --socket CID:14507 client  (connects host→VM, forwards to Hyprland)
#   No socat needed — waypipe speaks vsock natively.
#
{ config, pkgs, lib, ... }:

let
  VM_REGISTRY = "/etc/hydrix/vm-registry.json";
  username = config.hydrix.username;

  # ── waypipe-connect ────────────────────────────────────────────────────────
  waypipeConnect = pkgs.writeShellScriptBin "waypipe-connect" ''
    set -euo pipefail
    VM="''${1:-}"

    if [[ -z "$VM" ]]; then
      echo "Usage: waypipe-connect <vm-name>" >&2
      echo "Example: waypipe-connect microvm-browsing" >&2
      exit 1
    fi

    CID=""
    if [[ -f "${VM_REGISTRY}" ]]; then
      CID=$(${pkgs.jq}/bin/jq -r \
        --arg v "$VM" \
        'to_entries[] | select(.value.vmName == $v) | .value.cid' \
        "${VM_REGISTRY}" 2>/dev/null | head -1)
    fi

    if [[ -z "$CID" ]]; then
      echo "Cannot resolve CID for $VM — is it in ${VM_REGISTRY}?" >&2
      exit 1
    fi

    # Per-VM port: CID 106 → 14606, CID 103 → 14603, etc.
    PORT=$((14600 + CID - 100))

    # Mutual exclusion: kill any other waypipe-connect for this VM.
    # Multiple instances fight via pkill — each kills the other's waypipe.
    OTHER=$(pgrep -f "waypipe-connect ''${VM}$" 2>/dev/null \
      | grep -v "^$$\$" || true)
    if [[ -n "$OTHER" ]]; then
      echo "Stopping existing waypipe-connect for $VM (PID $OTHER)..."
      echo "$OTHER" | xargs kill 2>/dev/null || true
      sleep 1
    fi

    # Kill any stale waypipe process on this port (orphan from previous session).
    pkill -f "waypipe.*''${PORT}" 2>/dev/null || true
    sleep 0.3

    echo "Connecting waypipe for $VM (CID $CID, port $PORT)..."

    WAYPIPE_PID=""
    cleanup() {
      [[ -n "''${WAYPIPE_PID:-}" ]] && kill "''${WAYPIPE_PID}" 2>/dev/null || true
      exit 0
    }
    trap cleanup INT TERM

    echo "VM apps will appear as sway windows. Ctrl+C to disconnect."

    # Workspace number for notifications — static for the lifetime of this script.
    VM_WS=$(${pkgs.jq}/bin/jq -r \
      --arg v "$VM" \
      'to_entries[] | select(.value.vmName == $v) | .value.workspace' \
      "${VM_REGISTRY}" 2>/dev/null | head -1)

    # Loop: maintain the host-side waypipe listener.
    # Correct ordering: start listening FIRST, then tell VM to connect.
    while true; do
      # 1. Start host waypipe listener in the background.
      ${pkgs.waypipe}/bin/waypipe --vsock --socket "$PORT" --compress none client &
      WAYPIPE_PID=$!

      # 2. Poll until host vsock socket is actually open — no blind sleep.
      _host_ready=0
      for _j in $(seq 1 50); do
        if ${pkgs.iproute2}/bin/ss -H -A vsock --listening 2>/dev/null \
             | grep -qw "$PORT"; then
          _host_ready=1
          break
        fi
        sleep 0.1
      done
      if [[ "$_host_ready" -eq 0 ]]; then
        echo "Host vsock listener on port $PORT did not open (5s); retrying..." >&2
        kill "$WAYPIPE_PID" 2>/dev/null || true
        WAYPIPE_PID=""
        sleep 1
        continue
      fi

      # 3. Force VM to reconnect to this now-confirmed listener (unconditional restart).
      for _i in $(seq 1 30); do
        RESP=$(printf 'waypipe-reconnect\n' \
          | ${pkgs.socat}/bin/socat -T3 - VSOCK-CONNECT:"$CID":14509 2>/dev/null || true)
        [[ "$RESP" == "waypipe" ]] && break
        sleep 2
      done

      # 4. Poll STATUS until tunnel is confirmed live (VM reports stable connection).
      _tunnel_ok=0
      for _k in $(seq 1 15); do
        ST=$(printf 'STATUS\n' \
          | ${pkgs.socat}/bin/socat -T3 - VSOCK-CONNECT:"$CID":14509 2>/dev/null || true)
        if [[ "$ST" == "waypipe" ]]; then
          _tunnel_ok=1
          break
        fi
        sleep 1
      done

      if [[ "$_tunnel_ok" -eq 1 ]]; then
        echo "Tunnel live: $VM (CID $CID, port $PORT)"
        ${pkgs.libnotify}/bin/notify-send -u normal "waypipe" \
          "$VM connected — WS''${VM_WS:-?} ready" 2>/dev/null || true
      else
        echo "Tunnel did not confirm within 15s: $VM" >&2
      fi

      # 5. Wait for waypipe to exit (VM disconnected or error).
      wait "$WAYPIPE_PID" 2>/dev/null || true
      WAYPIPE_PID=""

      echo "waypipe disconnected from $VM, reconnecting..."
      sleep 1
    done
  '';

  # ── hypr-ws-app ────────────────────────────────────────────────────────────
  hyprWsApp = pkgs.writeShellScriptBin "hypr-ws-app" ''
    set -euo pipefail

    log()    { echo "[hypr-ws-app] $*" >&2; }
    notify() { ${pkgs.libnotify}/bin/notify-send -u normal "hypr-ws-app" "$*"; }
    err()    { ${pkgs.libnotify}/bin/notify-send -u critical "hypr-ws-app" "$*"; exit 1; }

    [[ $# -lt 1 ]] && err "Usage: hypr-ws-app <command> [args...]"

    # Current Hyprland workspace number
    WS=$(${pkgs.hyprland}/bin/hyprctl activeworkspace -j \
      | ${pkgs.jq}/bin/jq '.id')

    # WS1 = host, WS10 = router console
    if [[ "$WS" -eq 1 ]]; then
      log "WS1 (host) → running locally"
      exec "$@"
    fi

    if [[ "$WS" -eq 10 ]]; then
      log "WS10 (router) → opening console"
      if systemctl is-active --quiet "microvm@microvm-router.service" 2>/dev/null; then
        exec alacritty -e sudo socat -,rawer \
          unix-connect:/var/lib/microvms/microvm-router/console.sock
      else
        notify "Router VM not running"
        exec "$@"
      fi
    fi

    # Look up VM for this workspace from registry
    if [[ ! -f "${VM_REGISTRY}" ]]; then
      log "No vm-registry — running locally"
      exec "$@"
    fi

    # Focus mode: if set, route to the focused VM type regardless of workspace
    VM_INFO=""
    FOCUS_TYPE=""
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    if [[ -f "$FOCUS_FILE" ]]; then
      FOCUS_TYPE=$(cat "$FOCUS_FILE")
      VM_INFO=$(${pkgs.jq}/bin/jq -rc \
        --arg t "$FOCUS_TYPE" \
        'to_entries[] | select(.key == $t) | {cid: .value.cid, name: .value.vmName}' \
        "${VM_REGISTRY}" 2>/dev/null | head -1)
      [[ -n "$VM_INFO" ]] && log "Focus mode ($FOCUS_TYPE) overrides WS$WS"
    fi

    if [[ -z "$VM_INFO" ]]; then
      # Check active-vms.json — if a task or alternate VM was marked active for
      # this workspace (e.g. microvm-pentest-task1 started after microvm-pentest),
      # prefer it over the first registry entry.
      ACTIVE_VMS_FILE="$HOME/.cache/hydrix/active-vms.json"
      if [[ -f "$ACTIVE_VMS_FILE" ]]; then
        WS_VMS=$(${pkgs.jq}/bin/jq -rc --argjson w "$WS" \
          '[to_entries[] | select(.value.workspace == $w) | .value.vmName]' \
          "${VM_REGISTRY}" 2>/dev/null || echo '[]')
        ACTIVE_VM=$(${pkgs.jq}/bin/jq -r --argjson vms "$WS_VMS" \
          'to_entries[] | select((.value | type == "string") and (.value as $v | $vms | index($v) != null)) | .value' \
          "$ACTIVE_VMS_FILE" 2>/dev/null | head -1 || true)
        if [[ -n "$ACTIVE_VM" ]] \
            && systemctl is-active --quiet "microvm@''${ACTIVE_VM}.service" 2>/dev/null; then
          VM_INFO=$(${pkgs.jq}/bin/jq -rc --arg v "$ACTIVE_VM" \
            'to_entries[] | select(.value.vmName == $v) | {cid: .value.cid, name: .value.vmName}' \
            "${VM_REGISTRY}" 2>/dev/null | head -1)
          [[ -n "$VM_INFO" ]] && log "active-vms: routing WS$WS to $ACTIVE_VM"
        fi
      fi
      # Fall back to first registry entry for this workspace
      if [[ -z "$VM_INFO" ]]; then
        VM_INFO=$(${pkgs.jq}/bin/jq -rc \
          --argjson w "$WS" \
          'to_entries[] | select(.value.workspace == $w) | {cid: .value.cid, name: .value.vmName}' \
          "${VM_REGISTRY}" 2>/dev/null | head -1)
      fi
    fi

    if [[ -z "$VM_INFO" ]]; then
      log "No VM mapped to WS$WS — running locally"
      exec "$@"
    fi

    CID=$(echo "$VM_INFO" | ${pkgs.jq}/bin/jq -r '.cid')
    VM_NAME=$(echo "$VM_INFO" | ${pkgs.jq}/bin/jq -r '.name')

    # Guard: if the VM is not running, fall back to host terminal + notify
    if ! systemctl is-active --quiet "microvm@''${VM_NAME}.service" 2>/dev/null; then
      notify "$VM_NAME is not running — use 'microvm start $VM_NAME' to start it"
      exec "$@"
    fi

    # Poll STATUS — waypipe-connect is expected to be running (started by microvm start).
    # Do not auto-start it here; that is microvm start's responsibility.
    log "Waiting for waypipe to become ready in $VM_NAME..."
    READY=0
    for i in $(seq 1 20); do
      VM_STATUS=$(printf 'STATUS\n' \
        | ${pkgs.socat}/bin/socat -T3 - VSOCK-CONNECT:"$CID":14509 2>/dev/null || true)
      if [[ "$VM_STATUS" == "waypipe" ]]; then
        READY=1
        break
      fi
      sleep 0.5
    done
    if [[ "$READY" -eq 0 ]]; then
      err "waypipe not ready in $VM_NAME — is waypipe-connect running? (microvm start $VM_NAME)"
    fi

    log "WS$WS → $VM_NAME (CID $CID): $*"

    # Check if focus mode is routing to a different VM than this workspace's native VM.
    # If so, the windowrulev2 rule will send the new window to the VM's home workspace;
    # poll clients for the new window and move it back to the current workspace.
    NATIVE_VM=$(${pkgs.jq}/bin/jq -rc \
      --argjson w "$WS" \
      'to_entries[] | select(.value.workspace == $w) | .value.vmName' \
      "${VM_REGISTRY}" 2>/dev/null | head -1)

    if [[ -n "''${FOCUS_TYPE:-}" ]] && [[ "$VM_NAME" != "''${NATIVE_VM:-}" ]]; then
      TARGET_WS=$WS
      TITLE_PREFIX="[''${FOCUS_TYPE}]"
      log "Focus mode: will relocate $TITLE_PREFIX window to WS$TARGET_WS"
      # Snapshot existing windows with this prefix so we only act on the new one
      EXISTING=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
        | ${pkgs.jq}/bin/jq -c --arg p "$TITLE_PREFIX" \
          '[.[] | select(.title | startswith($p)) | .address]' \
          2>/dev/null || echo '[]')
      (
        for i in $(seq 1 40); do
          sleep 0.25
          ADDR=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r \
              --arg p "$TITLE_PREFIX" \
              --argjson ex "$EXISTING" \
              '[.[] | select(.title | startswith($p)) | select(.address as $a | ($ex | index($a) | not))] | first | .address // empty' \
              2>/dev/null | head -1)
          if [[ -n "$ADDR" ]]; then
            ${pkgs.hyprland}/bin/hyprctl dispatch movetoworkspacesilent "$TARGET_WS,address:$ADDR" >/dev/null 2>&1 || true
            ${pkgs.hyprland}/bin/hyprctl dispatch focuswindow "address:$ADDR" >/dev/null 2>&1 || true
            break
          fi
        done
      ) &
    fi

    # Send command to VM's waypipe-launch service (vsock:14508).
    # For Firefox: inject HYDRIX_FF_SCALE so firefox-dpi in the VM uses the
    # host monitor's scale (compositor fractional scale, not X11 DPI).
    LAUNCH_CMD="$*"
    if [[ "''${1:-}" == "firefox" ]]; then
      HOST_SCALE=$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '[.[] | select(.focused)][0].scale // .[0].scale // 1.0' \
        2>/dev/null || echo "1.0")
      LAUNCH_CMD="env HYDRIX_FF_SCALE=$HOST_SCALE $*"
    fi
    printf '%s\n' "$LAUNCH_CMD" \
      | ${pkgs.socat}/bin/socat -T 10 - VSOCK-CONNECT:"$CID":14508
  '';

  # ── sway-ws-app ────────────────────────────────────────────────────────────
  # Workspace-aware app launcher for Sway (mirrors hypr-ws-app for Hyprland).
  # Usage: sway-ws-app alacritty
  #        sway-ws-app firefox https://foo.com
  swayWsApp = pkgs.writeShellScriptBin "sway-ws-app" ''
    set -euo pipefail

    log()    { echo "[sway-ws-app] $*" >&2; }
    notify() { ${pkgs.libnotify}/bin/notify-send -u normal "sway-ws-app" "$*"; }
    err()    { ${pkgs.libnotify}/bin/notify-send -u critical "sway-ws-app" "$*"; exit 1; }

    [[ $# -lt 1 ]] && err "Usage: sway-ws-app <command> [args...]"

    # Current Sway workspace number
    WS=$(${pkgs.sway}/bin/swaymsg -t get_workspaces \
      | ${pkgs.jq}/bin/jq '.[] | select(.focused).num')

    # WS1 = host, WS10 = router console
    if [[ "$WS" -eq 1 ]]; then
      log "WS1 (host) → running locally"
      exec "$@"
    fi

    if [[ "$WS" -eq 10 ]]; then
      log "WS10 (router) → opening console"
      if systemctl is-active --quiet "microvm@microvm-router.service" 2>/dev/null; then
        exec alacritty -e sudo socat -,rawer \
          unix-connect:/var/lib/microvms/microvm-router/console.sock
      else
        notify "Router VM not running"
        exec "$@"
      fi
    fi

    # Look up VM for this workspace from registry
    if [[ ! -f "${VM_REGISTRY}" ]]; then
      log "No vm-registry — running locally"
      exec "$@"
    fi

    # Focus mode: if set, route to the focused VM type regardless of workspace
    VM_INFO=""
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    if [[ -f "$FOCUS_FILE" ]]; then
      FOCUS_TYPE=$(cat "$FOCUS_FILE")
      VM_INFO=$(${pkgs.jq}/bin/jq -rc \
        --arg t "$FOCUS_TYPE" \
        'to_entries[] | select(.key == $t) | {cid: .value.cid, name: .value.vmName}' \
        "${VM_REGISTRY}" 2>/dev/null | head -1)
      [[ -n "$VM_INFO" ]] && log "Focus mode ($FOCUS_TYPE) overrides WS$WS"
    fi

    if [[ -z "$VM_INFO" ]]; then
      VM_INFO=$(${pkgs.jq}/bin/jq -rc \
        --argjson w "$WS" \
        'to_entries[] | select(.value.workspace == $w) | {cid: .value.cid, name: .value.vmName}' \
        "${VM_REGISTRY}" 2>/dev/null | head -1)
    fi

    if [[ -z "$VM_INFO" ]]; then
      log "No VM mapped to WS$WS — running locally"
      exec "$@"
    fi

    CID=$(echo "$VM_INFO" | ${pkgs.jq}/bin/jq -r '.cid')
    VM_NAME=$(echo "$VM_INFO" | ${pkgs.jq}/bin/jq -r '.name')

    # Guard: if the VM is not running, fall back to host terminal + notify
    if ! systemctl is-active --quiet "microvm@''${VM_NAME}.service" 2>/dev/null; then
      notify "$VM_NAME is not running — use 'microvm start $VM_NAME' to start it"
      exec "$@"
    fi

    # Poll STATUS — waypipe-connect is expected to be running (started by microvm start).
    # Do not auto-start it here; that is microvm start's responsibility.
    log "Waiting for waypipe to become ready in $VM_NAME..."
    READY=0
    for i in $(seq 1 20); do
      VM_STATUS=$(printf 'STATUS\n' \
        | ${pkgs.socat}/bin/socat -T3 - VSOCK-CONNECT:"$CID":14509 2>/dev/null || true)
      if [[ "$VM_STATUS" == "waypipe" ]]; then
        READY=1
        break
      fi
      sleep 0.5
    done
    if [[ "$READY" -eq 0 ]]; then
      err "waypipe not ready in $VM_NAME — is waypipe-connect running? (microvm start $VM_NAME)"
    fi

    log "WS$WS → $VM_NAME (CID $CID): $*"

    # Check if focus mode is routing to a different VM than this workspace's native VM.
    # If so, the for_window rule will send the new window to the VM's home workspace;
    # poll get_tree for the new window and move it back to the current workspace.
    NATIVE_VM=$(${pkgs.jq}/bin/jq -rc \
      --argjson w "$WS" \
      'to_entries[] | select(.value.workspace == $w) | .value.vmName' \
      "${VM_REGISTRY}" 2>/dev/null | head -1)

    if [[ -n "''${FOCUS_TYPE:-}" ]] && [[ "$VM_NAME" != "$NATIVE_VM" ]]; then
      TARGET_WS=$WS
      TITLE_PREFIX="[''${FOCUS_TYPE}]"
      log "Focus mode: will relocate $TITLE_PREFIX window to WS$TARGET_WS"
      # Snapshot existing windows with this prefix so we only act on the new one
      EXISTING_IDS=$(${pkgs.sway}/bin/swaymsg -t get_tree \
        | ${pkgs.jq}/bin/jq -c --arg p "$TITLE_PREFIX" \
          '[.. | objects | select(.name? and (.name | startswith($p))) | .id]' \
          2>/dev/null || echo '[]')
      (
        for i in $(seq 1 40); do
          sleep 0.25
          con_id=$(${pkgs.sway}/bin/swaymsg -t get_tree \
            | ${pkgs.jq}/bin/jq -r \
              --arg p "$TITLE_PREFIX" \
              --argjson ex "$EXISTING_IDS" \
              '.. | objects | select(.name? and (.name | startswith($p)) and (.id as $id | $ex | index($id) | not)) | .id' \
              2>/dev/null | head -1)
          if [[ -n "$con_id" ]]; then
            ${pkgs.sway}/bin/swaymsg "[con_id=$con_id] move to workspace $TARGET_WS"
            ${pkgs.sway}/bin/swaymsg "[con_id=$con_id] focus"
            break
          fi
        done
      ) &
    fi

    # Send command to VM's waypipe-launch service (vsock:14508).
    # For Firefox: inject HYDRIX_FF_SCALE from the focused Sway output.
    LAUNCH_CMD="$*"
    if [[ "''${1:-}" == "firefox" ]]; then
      HOST_SCALE=$(${pkgs.sway}/bin/swaymsg -t get_outputs 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '[.[] | select(.focused)][0].scale // .[0].scale // 1.0' \
        2>/dev/null || echo "1.0")
      LAUNCH_CMD="env HYDRIX_FF_SCALE=$HOST_SCALE $*"
    fi
    printf '%s\n' "$LAUNCH_CMD" \
      | ${pkgs.socat}/bin/socat -T 10 - VSOCK-CONNECT:"$CID":14508
  '';

  # ── vm-select ────────────────────────────────────────────────────────────
  # Wofi picker to switch the active VM on the current workspace.
  # Works on any workspace with multiple VMs (pentest+tasks, or any future
  # workspace that declares more than one VM in the registry).
  # Updates ~/.cache/hydrix/active-vms.json so hypr-ws-app routes to the
  # chosen VM. Also ensures waypipe-connect is running for the selected VM.
  #
  # Usage: vm-select
  #   Bind to e.g. $mod+shift+p in hyprland.nix
  #
  vmSelect = pkgs.writeShellScriptBin "vm-select" ''
    set -euo pipefail

    readonly VM_REGISTRY="${VM_REGISTRY}"
    readonly ACTIVE_VMS_FILE="$HOME/.cache/hydrix/active-vms.json"

    notify() { ${pkgs.libnotify}/bin/notify-send -u normal "vm-select" "$*"; }

    # ── Theming (mirrors wofi-launcher) ───────────────────────────────────
    get_wal_color() {
      local key="$1" fallback="$2" color=""
      local wal_json="$HOME/.cache/wal/colors.json"
      [[ -f "$wal_json" ]] \
        && color=$(${pkgs.jq}/bin/jq -r "$key // empty" "$wal_json" 2>/dev/null)
      echo "''${color:-$fallback}"
    }

    build_theme() {
      local bg fg accent corner_radius font_size
      bg=$(get_wal_color '.colors.color0' '#0e0f17')
      fg=$(get_wal_color '.colors.color7' '#e4d1ef')
      accent=$(get_wal_color '.colors.color4' '#f09ea2')
      local scaling_json="$HOME/.config/hydrix/scaling.json"
      if [[ -f "$scaling_json" ]]; then
        corner_radius=$(${pkgs.jq}/bin/jq -r '.sizes.corner_radius // 8' "$scaling_json")
        font_size=$(${pkgs.jq}/bin/jq -r '.fonts.wofi // 12' "$scaling_json")
      else
        corner_radius=8; font_size=12
      fi
      cat <<EOF
* { font-size: ''${font_size}px; color: ''${fg}; }
#window { background-color: ''${bg}; border-radius: ''${corner_radius}px; border: 0px solid transparent; }
#outer-box { padding: 8px; }
#input { background-color: transparent; border: none; border-bottom: 1px solid ''${accent}; border-radius: 0; padding: 4px 8px; margin-bottom: 4px; color: ''${fg}; }
#inner-box { padding: 4px; }
#entry { padding: 8px 12px; background-color: transparent; border-radius: ''${corner_radius}px; }
#entry:selected { background-color: ''${accent}; color: ''${bg}; }
#entry-text { background-color: transparent; color: inherit; }
EOF
    }

    # ── Get current workspace ──────────────────────────────────────────────
    WS=$(${pkgs.hyprland}/bin/hyprctl activeworkspace -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.id' || echo "1")

    if [[ ! -f "$VM_REGISTRY" ]]; then
      notify "No VM registry found"
      exit 0
    fi

    # ── All VM names declared for this workspace ───────────────────────────
    WS_VMS=$(${pkgs.jq}/bin/jq -r --argjson w "$WS" \
      'to_entries[] | select(.value.workspace == $w) | .value.vmName' \
      "$VM_REGISTRY" 2>/dev/null)

    if [[ -z "$WS_VMS" ]]; then
      notify "No VMs declared for workspace $WS"
      exit 0
    fi

    # ── Filter to running ones ─────────────────────────────────────────────
    RUNNING=""
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      systemctl is-active --quiet "microvm@''${vm}.service" 2>/dev/null \
        && RUNNING+="$vm"$'\n' || true
    done <<< "$WS_VMS"
    RUNNING=$(echo "$RUNNING" | ${pkgs.gnugrep}/bin/grep -v '^$' || true)

    if [[ -z "$RUNNING" ]]; then
      notify "No VMs running on workspace $WS"
      exit 0
    fi

    # ── Get the base type key for active-vms.json ──────────────────────────
    # The base type is the shortest registry key for this workspace
    # (e.g. "pentest" rather than "pentest-task1").
    WS_TYPE=$(${pkgs.jq}/bin/jq -r --argjson w "$WS" \
      '[to_entries[] | select(.value.workspace == $w) | .key] | sort_by(length) | first // empty' \
      "$VM_REGISTRY" 2>/dev/null || true)

    # ── Get current active VM ──────────────────────────────────────────────
    mkdir -p "$(dirname "$ACTIVE_VMS_FILE")"
    [[ ! -f "$ACTIVE_VMS_FILE" ]] && echo '{}' > "$ACTIVE_VMS_FILE"
    CURRENT=$(${pkgs.jq}/bin/jq -r \
      --argjson vms "$(echo "$RUNNING" | ${pkgs.jq}/bin/jq -Rn '[inputs]')" \
      'to_entries[] | select((.value | type == "string") and (.value as $v | $vms | index($v) != null)) | .value' \
      "$ACTIVE_VMS_FILE" 2>/dev/null | head -1 || true)

    # ── Build display list (★ for active) ─────────────────────────────────
    DISPLAY_LIST=""
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      if [[ "$vm" == "$CURRENT" ]]; then
        DISPLAY_LIST+="★ $vm"$'\n'
      else
        DISPLAY_LIST+="  $vm"$'\n'
      fi
    done <<< "$RUNNING"

    # ── Show wofi picker ───────────────────────────────────────────────────
    THEME=$(${pkgs.coreutils}/bin/mktemp /tmp/vm-select-XXXXXX.css)
    build_theme > "$THEME"
    VM_COUNT=$(echo "$RUNNING" | ${pkgs.gnugrep}/bin/grep -c '.' || echo 1)
    SELECTED=$(echo -n "$DISPLAY_LIST" \
      | ${pkgs.wofi}/bin/wofi --show dmenu \
          --style="$THEME" \
          --prompt="WS$WS vm" \
          --lines="$VM_COUNT" \
          --width=320 \
          --no-actions \
          2>/dev/null || true)
    ${pkgs.coreutils}/bin/rm -f "$THEME"

    [[ -z "$SELECTED" ]] && exit 0

    # Strip marker prefix
    SELECTED=$(echo "$SELECTED" | ${pkgs.gnused}/bin/sed 's/^★ //; s/^  //')

    # ── Update active-vms.json ─────────────────────────────────────────────
    TMP=$(${pkgs.coreutils}/bin/mktemp)
    ${pkgs.jq}/bin/jq --arg type "$WS_TYPE" --arg vm "$SELECTED" \
      '.[$type] = $vm' "$ACTIVE_VMS_FILE" > "$TMP" \
      && mv "$TMP" "$ACTIVE_VMS_FILE"

    # ── Ensure waypipe-connect is running for the selected VM ─────────────
    if ! pgrep -f "waypipe-connect ''${SELECTED}$" >/dev/null 2>&1; then
      setsid ${waypipeConnect}/bin/waypipe-connect "$SELECTED" \
        </dev/null >"/tmp/waypipe-connect-''${SELECTED}.log" 2>&1 &
      notify "Switched to $SELECTED — connecting waypipe..."
    else
      notify "Switched to $SELECTED"
    fi
  '';

  # ── vm-push-display-mode ──────────────────────────────────────────────────
  # Pushes a display mode to all running profile VMs, or a specific VM.
  # Mode is auto-detected from the environment unless given explicitly.
  #
  # Usage:
  #   vm-push-display-mode              # auto-detect: xpra (X11) or waypipe (Wayland)
  #   vm-push-display-mode stop         # stop all display services in VMs
  #   vm-push-display-mode xpra         # force xpra mode
  #   vm-push-display-mode waypipe      # force waypipe mode
  #   vm-push-display-mode browsing     # push auto-detected mode to one VM
  #
  vmPushDisplayMode = pkgs.writeShellScriptBin "vm-push-display-mode" ''
    set -euo pipefail

    # If first arg is an explicit mode, use it; otherwise auto-detect.
    if [[ "''${1:-}" =~ ^(stop|xpra|waypipe)$ ]]; then
      MODE="$1"
      shift
    elif [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
      MODE="waypipe"
    else
      MODE="xpra"
    fi

    push_to_vm() {
      local cid="$1" name="$2"
      local result
      if result=$(printf '%s\n' "$MODE" \
          | ${pkgs.socat}/bin/socat -T5 - VSOCK-CONNECT:"$cid":14509 2>/dev/null); then
        echo "[$name] display-mode → $MODE ($result)"
      else
        echo "[$name] not reachable (not running?)" >&2
      fi
    }

    if [[ $# -ge 1 ]]; then
      # Specific profile name given
      PROFILE="$1"
      CID=$(${pkgs.jq}/bin/jq -r \
        --arg p "$PROFILE" '.[$p].cid // empty' "${VM_REGISTRY}" 2>/dev/null)
      if [[ -z "$CID" ]]; then
        echo "Unknown profile: $PROFILE" >&2
        exit 1
      fi
      push_to_vm "$CID" "$PROFILE"
    else
      # All profile VMs (workspace != null)
      while IFS= read -r entry; do
        CID=$(echo "$entry" | ${pkgs.jq}/bin/jq -r '.cid')
        NAME=$(echo "$entry" | ${pkgs.jq}/bin/jq -r '.name')
        push_to_vm "$CID" "$NAME"
      done < <(${pkgs.jq}/bin/jq -rc \
        'to_entries[] | select(.value.workspace != null) | {cid: .value.cid, name: .key}' \
        "${VM_REGISTRY}" 2>/dev/null)
    fi
  '';

  # ── waypipe-connect-all ───────────────────────────────────────────────────
  # Auto-start waypipe-connect for all currently-running profile VMs.
  # Called at sway/Hyprland startup. Spawns one background poller per running
  # VM; each poller sends PING until it gets OK, then immediately starts
  # waypipe-connect. No timeouts — VM readiness is the only gate.
  waypipeConnectAll = pkgs.writeShellScriptBin "waypipe-connect-all" ''
    set -euo pipefail

    if [[ ! -f "${VM_REGISTRY}" ]]; then
      exit 0
    fi

    wait_and_connect() {
      local vm_name="$1" cid="$2"

      # Poll until VM responds OK to PING — no timeout, VM readiness is the gate.
      while true; do
        resp=$(printf 'PING\n' \
          | ${pkgs.socat}/bin/socat -T2 - VSOCK-CONNECT:"$cid":14509 2>/dev/null || true)
        [[ "$resp" == "OK" ]] && break
        sleep 0.5
      done

      # Spawn waypipe-connect if not already running.
      if ! pgrep -f "waypipe-connect ''${vm_name}$" >/dev/null 2>&1; then
        setsid ${waypipeConnect}/bin/waypipe-connect "$vm_name" \
          </dev/null >"/tmp/waypipe-connect-''${vm_name}.log" 2>&1 &
      fi
    }

    while IFS= read -r entry; do
      VM_NAME=$(echo "$entry" | ${pkgs.jq}/bin/jq -r '.name')
      CID=$(echo "$entry" | ${pkgs.jq}/bin/jq -r '.cid')

      if systemctl is-active --quiet "microvm@''${VM_NAME}.service" 2>/dev/null; then
        wait_and_connect "$VM_NAME" "$CID" &
      fi
    done < <(${pkgs.jq}/bin/jq -rc \
      'to_entries[] | select(.value.workspace != null) | {cid: .value.cid, name: .value.vmName}' \
      "${VM_REGISTRY}" 2>/dev/null)
  '';

  # ── exit-i3 ───────────────────────────────────────────────────────────────
  # Gracefully exit i3.
  # Stops xpra inside all running VMs (via "stop" mode push) and kills any
  # host-side xpra attach processes, then exits i3.
  # Leaves VMs with no display service running — the next WM pushes its own
  # mode (sway-session → waypipe, i3 startup → xpra) when it comes up.
  #
  exitI3 = pkgs.writeShellScriptBin "exit-i3" ''
    vm-push-display-mode stop >/dev/null 2>&1 &
    pkill -f "xpra" 2>/dev/null || true
    i3-msg exit
  '';

  # ── exit-wayland ──────────────────────────────────────────────────────────
  # Gracefully exit sway or Hyprland from any terminal.
  # Kills all host-side waypipe-connect sessions, unsets WAYLAND_DISPLAY from
  # the systemd user environment, then exits the compositor.
  # VMs are left as-is — no mode push here. When i3 starts next it will push
  # xpra mode; when sway starts it will push waypipe mode.
  #
  exitWayland = pkgs.writeShellScriptBin "exit-wayland" ''
    echo "Killing host waypipe sessions..."
    pkill -f "waypipe-connect" 2>/dev/null || true
    pkill -f "waypipe.*--vsock.*client" 2>/dev/null || true

    # Signal VMs to stop their display services in the background — waypipe is
    # already dead so VMs notice the disconnect regardless. No need to block exit.
    vm-push-display-mode stop >/dev/null 2>&1 &

    # Remove WAYLAND_DISPLAY from the persistent systemd user environment so
    # picom's ConditionEnvironment=!WAYLAND_DISPLAY is satisfied on next i3 start.
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY 2>/dev/null || true

    if pgrep -x sway >/dev/null 2>&1; then
      swaymsg exit 2>/dev/null || true
    elif hyprctl instances 2>/dev/null | grep -q .; then
      hyprctl dispatch exit 2>/dev/null || true
    else
      echo "No Wayland session running" >&2
    fi
  '';

in lib.mkIf (config.hydrix.sway.enable || config.hydrix.hyprland.enable) {
  environment.systemPackages = [
    waypipeConnect waypipeConnectAll hyprWsApp swayWsApp vmSelect vmPushDisplayMode exitI3 exitWayland
    pkgs.waypipe pkgs.socat  # socat still needed for vm-push-display-mode (vsock:14509)
  ];

  # ── Audio forwarding for waypipe VMs ─────────────────────────────────────
  # waypipe carries Wayland display only; audio travels over a parallel vsock
  # channel (port 14505). VMs connect to host CID 2 on vsock:14505 and get
  # proxied directly to the PipeWire PulseAudio Unix socket.
  #
  # Anonymous auth on the Unix socket: VM clients won't have the host PA cookie,
  # and without auth.anonymous PipeWire silently degrades them to an isolated
  # null-sink session. Safe on a single-user machine — the cookie is only
  # meaningful separation between different Unix users, not same-UID processes.

  # PipeWire: accept anonymous connections on the PA Unix socket
  services.pipewire.extraConfig.pipewire-pulse."10-vm-audio" = {
    "pulse.properties" = {
      "server.address" = [
        { "address" = "unix:native"; "auth.anonymous" = true; }
      ];
    };
  };

  # Bridge vsock:14505 → PipeWire PA Unix socket
  systemd.user.services.pulse-vsock = {
    description = "PulseAudio vsock bridge for waypipe VMs (port 14505)";
    wantedBy = [ "default.target" ];
    after = [ "pipewire-pulse.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14505,reuseaddr,fork UNIX-CLIENT:/run/user/1000/pulse/native";
      Restart = "always";
      RestartSec = "3s";
    };
  };
}
