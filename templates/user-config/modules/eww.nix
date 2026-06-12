# shared/eww.nix — eww widget daemon + left-side overlay
#
# left-overlay (top-left): stacked vertical panel showing:
#   - exit-nodes: active VM WireGuard exit nodes (queries router CID 200 vsock 14515)
#   - vm-status:  running/stopped VM overview (parses `microvm status`)
#
# Window opens when either exit nodes are active OR any VM is running.
# Colors sourced from ~/.cache/wal/colors.scss (pywal SCSS output).
# Font size and geometry derived from hydrix.graphical.ui/scaling values.
#
# Gated on hydrix.hyprland.enable — host-only, no VM usage.
#
{ config, lib, pkgs, ... }:
let
  username  = config.hydrix.username;
  ui        = config.hydrix.graphical.ui;
  gaps    = let v = ui.gaps or null; in if v != null then v else 10;
  widgetX = gaps;
  widgetY = gaps;
  fontSize  = let v = config.hydrix.graphical.font.size or null; in if v != null then v else 10;

  # Polling script: queries router vsock 14515 for wg dump JSON, then
  # cross-references /tmp/hydrix-metrics-* to filter down to running VMs with
  # active tunnels. Returns JSON array for eww defpoll.
  ewwWgStatus = pkgs.writeShellApplication {
    name = "eww-wg-status";
    runtimeInputs = [ pkgs.socat pkgs.jq pkgs.coreutils pkgs.gnused ];
    text = ''
      router_json=$(echo "" | socat -T2 - VSOCK-CONNECT:200:14515 2>/dev/null || true)
      if [ -z "$router_json" ] || [ "$router_json" = "[]" ]; then
        echo "[]"; exit 0
      fi

      format_bytes() {
        local b=''${1:-0}
        if   [ "$b" -ge 1073741824 ]; then echo "$((b / 1073741824))GB"
        elif [ "$b" -ge 1048576 ];    then echo "$((b / 1048576))MB"
        elif [ "$b" -ge 1024 ];       then echo "$((b / 1024))KB"
        else                               echo "''${b}B"
        fi
      }

      format_age() {
        local age=$1
        if   [ "$age" -lt 0 ];    then echo "no hs"
        elif [ "$age" -lt 60 ];   then echo "''${age}s"
        elif [ "$age" -lt 3600 ]; then echo "$((age / 60))m"
        else                           echo "$((age / 3600))h"
        fi
      }

      result="["; sep=""

      for f in /tmp/hydrix-metrics-*; do
        [ -f "$f" ] || continue
        vm=$(basename "$f" | sed 's/hydrix-metrics-//')

        iface="wg-$vm"
        iface_json=$(echo "$router_json" \
          | jq -c --arg i "$iface" '.[] | select(.iface == $i)' 2>/dev/null || true)
        [ -z "$iface_json" ] && continue

        endpoint=$(echo "$iface_json" | jq -r '.endpoint')
        location=$(echo "$iface_json" | jq -r '.location // .endpoint')
        handshake=$(echo "$iface_json" | jq -r '.handshake')
        rx=$(echo "$iface_json" | jq -r '.rx')
        tx=$(echo "$iface_json" | jq -r '.tx')

        age_str=$(format_age "$handshake")
        rx_str=$(format_bytes "$rx")
        tx_str=$(format_bytes "$tx")

        if   [ "$handshake" -lt 0 ];   then cls="dead"
        elif [ "$handshake" -lt 180 ]; then cls="active"
        else                                cls="stale"
        fi

        result+="$sep{\"vm\":\"$vm\",\"endpoint\":\"$endpoint\",\"location\":\"$location\",\"age\":\"$age_str\",\"rx\":\"$rx_str\",\"tx\":\"$tx_str\",\"class\":\"$cls\"}"
        sep=","
      done

      echo "$result]"
    '';
  };

  # Polling script: parses `microvm status` table output (NAME STATUS CID columns).
  # microvm status uses ANSI color codes in the STATUS field — strip them before parsing.
  # Returns {"running":[{name,cid},...], "stopped":[{name,cid},...]} for eww.
  ewwMvmStatus = pkgs.writeShellApplication {
    name = "eww-mvm-status";
    runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.gnused ];
    text = ''
      microvm=/run/current-system/sw/bin/microvm

      running_json="[]"
      stopped_json="[]"

      if [ ! -x "$microvm" ]; then
        echo '{"running":[],"stopped":[]}'
        exit 0
      fi

      # Strip ANSI codes, then process lines beginning with "microvm-".
      while read -r name status cid; do
        case "$name" in microvm-*) ;; *) continue ;; esac
        short="''${name#microvm-}"
        entry="{\"name\":\"$short\",\"cid\":\"$cid\"}"
        case "$status" in
          running) running_json=$(echo "$running_json" | jq --argjson e "$entry" '. + [$e]') ;;
          stopped) stopped_json=$(echo "$stopped_json" | jq --argjson e "$entry" '. + [$e]') ;;
        esac
      done < <("$microvm" status 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
        || true)

      echo "{\"running\":$running_json,\"stopped\":$stopped_json}"
    '';
  };

  # Watcher: opens left-overlay when exit nodes active OR any VM running; closes when both empty.
  ewwLeftWatcher = pkgs.writeShellApplication {
    name = "eww-left-watch";
    runtimeInputs = [ pkgs.eww pkgs.jq pkgs.coreutils ];
    text = ''
      last="closed"
      while true; do
        wg=$(eww-wg-status 2>/dev/null || echo "[]")
        vm=$(eww-mvm-status 2>/dev/null || echo '{"running":[],"stopped":[]}')
        wg_count=$(echo "$wg" | jq 'length' 2>/dev/null || echo 0)
        vm_count=$(echo "$vm" | jq '.running | length' 2>/dev/null || echo 0)

        if [ "$wg_count" -gt 0 ] || [ "$vm_count" -gt 0 ]; then
          state="open"
        else
          state="closed"
        fi

        if [ "$state" != "$last" ]; then
          if [ "$state" = "open" ]; then
            eww open left-overlay 2>/dev/null || true
          else
            eww close left-overlay 2>/dev/null || true
          fi
          last="$state"
        fi
        sleep 5
      done
    '';
  };

  ewwYuck = ''
    (defpoll wg_nodes
      :interval "5s"
      :initial "[]"
      `eww-wg-status`)

    (defpoll vm_status
      :interval "5s"
      :initial "{\"running\":[],\"stopped\":[]}"
      `eww-mvm-status`)

    (defwindow left-overlay
      :monitor 0
      :geometry (geometry
        :x "${toString widgetX}px"
        :y "${toString widgetY}px"
        :width "270px"
        :anchor "top left")
      :exclusive false
      :stacking "bottom"
      :focusable false
      (left-overlay-widget))

    (defwidget left-overlay-widget []
      (box
        :orientation "v"
        :space-evenly false
        :spacing 0
        (exit-nodes-widget)
        (label
          :class "section-sep"
          :text " "
          :halign "start"
          :visible {arraylength(wg_nodes) > 0 && arraylength(vm_status.running) > 0})
        (vm-status-widget)))

    (defwidget exit-nodes-widget []
      (box
        :class "exit-nodes"
        :orientation "v"
        :space-evenly false
        :spacing 0
        :visible {arraylength(wg_nodes) > 0}
        (label
          :class "en-title"
          :text "EXIT NODES"
          :halign "start")
        (for node in wg_nodes
          (node-row :node node))))

    (defwidget node-row [node]
      (box
        :class "node-row"
        :orientation "v"
        :space-evenly false
        (box
          :orientation "h"
          :space-evenly false
          :spacing 6
          (label
            :class "node-dot {node.class}"
            :text {node.class == "active" ? "●" : node.class == "stale" ? "○" : "✗"})
          (label
            :class "node-vm"
            :text {node.vm}
            :hexpand true
            :halign "start")
          (label
            :class "node-ep {node.class}"
            :text {node.location}))
        (label
          :class "node-meta"
          :text {(node.location == node.endpoint ? "" : node.endpoint + "   ") + node.age + "   " + node.rx + "↓  " + node.tx + "↑"}
          :halign "start")))

    (defwidget vm-status-widget []
      (box
        :class "vm-status"
        :orientation "v"
        :space-evenly false
        :spacing 0
        :visible {arraylength(vm_status.running) > 0}
        (label
          :class "vs-title"
          :text "VMS"
          :halign "start")
        (box
          :orientation "v"
          :space-evenly false
          (for vm in {vm_status.running}
            (vm-row-running :vm vm)))
        (box
          :orientation "v"
          :space-evenly false
          :visible {arraylength(vm_status.stopped) > 0}
          (label
            :class "vs-section"
            :text "STOPPED"
            :halign "start")
          (for vm in {vm_status.stopped}
            (vm-row-stopped :vm vm)))))

    (defwidget vm-row-running [vm]
      (box
        :class "vm-row"
        :orientation "h"
        :space-evenly false
        :spacing 6
        (label
          :class "vm-dot running"
          :text "●")
        (label
          :class "vm-name"
          :text {vm.name}
          :hexpand true
          :halign "start")
        (label
          :class "vm-cid"
          :text {"CID " + vm.cid}
          :visible {vm.cid != ""})))

    (defwidget vm-row-stopped [vm]
      (box
        :class "vm-row stopped"
        :orientation "h"
        :space-evenly false
        :spacing 6
        (label
          :class "vm-dot stopped"
          :text "○")
        (label
          :class "vm-name stopped"
          :text {vm.name}
          :hexpand true
          :halign "start")))
  '';

  ewwScss = ''
    @import "/home/${username}/.cache/wal/colors.scss";

    window {
      background-color: transparent;
    }

    * {
      font-family: "Iosevka", monospace;
      font-size: ${toString fontSize}pt;
      color: $foreground;
      background-color: transparent;
    }

    /* exit-nodes */

    .exit-nodes {
      background-color: transparent;
      padding: 6px 10px;
    }

    .en-title {
      font-weight: bold;
      color: $color4;
      letter-spacing: 0.06em;
      margin-bottom: 4px;
    }

    .node-row {
      margin-top: 4px;
    }

    .node-dot {
      min-width: 14px;
    }
    .node-dot.active { color: $color2; }
    .node-dot.stale  { color: $color3; }
    .node-dot.dead   { color: $color1; }

    .node-vm {
      font-weight: bold;
      color: $foreground;
    }

    .node-ep.active { color: $color2; }
    .node-ep.stale  { color: $color3; }
    .node-ep.dead   { color: $color1; }

    .node-meta {
      color: $color8;
      margin-top: 1px;
    }

    .section-sep {
      color: $color8;
      padding: 0 10px;
      margin-top: 4px;
    }

    /* vm-status */

    .vm-status {
      background-color: transparent;
      padding: 6px 10px;
    }

    .vs-title {
      font-weight: bold;
      color: $color4;
      letter-spacing: 0.06em;
      margin-bottom: 4px;
    }

    .vs-section {
      font-weight: bold;
      color: $color8;
      letter-spacing: 0.06em;
      margin-top: 6px;
      margin-bottom: 2px;
    }

    .vm-row {
      margin-top: 3px;
    }

    .vm-dot {
      min-width: 14px;
    }
    .vm-dot.running { color: $color2; }
    .vm-dot.stopped { color: $color8; }

    .vm-name {
      font-weight: bold;
      color: $foreground;
    }
    .vm-name.stopped {
      color: $color8;
      font-weight: normal;
    }

    .vm-cid {
      color: $color8;
    }
  '';

  ewwYuckFile = pkgs.writeText "eww.yuck" ewwYuck;
  ewwScssFile = pkgs.writeText "eww.scss" ewwScss;
in lib.mkIf config.hydrix.hyprland.enable {

  home-manager.users.${username} = { lib, ... }: {
    home.packages = [ pkgs.eww ewwWgStatus ewwMvmStatus ewwLeftWatcher ];

    home.activation.ewwConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _dir="$HOME/.config/eww"
      mkdir -p "$_dir"
      [ -L "$_dir/eww.yuck" ] && rm "$_dir/eww.yuck" || true
      [ -L "$_dir/eww.scss" ] && rm "$_dir/eww.scss" || true
      cp ${ewwYuckFile} "$_dir/eww.yuck" && chmod 644 "$_dir/eww.yuck"
      cp ${ewwScssFile} "$_dir/eww.scss" && chmod 644 "$_dir/eww.scss"
    '';

    systemd.user.paths.eww-colors = {
      Unit.Description = "Watch pywal SCSS for eww color reload";
      Path.PathChanged = "%h/.cache/wal/colors.scss";
      Install.WantedBy = [ "hyprland-session.target" ];
    };

    systemd.user.services.eww-colors = {
      Unit = {
        Description = "Reload eww on pywal color change";
        After       = [ "hyprland-session.target" ];
      };
      Service = {
        Type      = "oneshot";
        ExecStart = "${pkgs.eww}/bin/eww reload";
      };
    };

    systemd.user.services.eww-left-watch = {
      Unit = {
        Description = "eww left-overlay open/close watcher";
        After       = [ "hyprland-session.target" ];
        PartOf      = [ "hyprland-session.target" ];
      };
      Service = {
        Type       = "simple";
        ExecStart  = "${ewwLeftWatcher}/bin/eww-left-watch";
        Restart    = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}
