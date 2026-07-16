# shared/eww.nix — eww widget daemon + unified left-side overlay
#
# Single left-overlay window (center left) with three stacked sections:
#   - VMS:        running/stopped VM overview (parses `microvm status`)
#   - EXIT NODES: active WireGuard exit nodes with session totals
#                 (queries router CID 200 vsock 14515)
#   - NETWORK:    connected SSID, unsaved count, WAN + per-VM bandwidth
#                 (wifi-sync vsock 14506; net-stats vsock 14517)
#
# Panel is gated by :visible so it appears fully-formed once data arrives.
# Colors sourced from ~/.cache/wal/colors.scss (pywal SCSS output).
# Font size and geometry derived from hydrix.graphical.ui/scaling values.
#
# Gated on hydrix.hyprland.enable — host-only, no VM usage.
#
{ config, lib, pkgs, ... }:
let
  username = config.hydrix.username;
  ui       = config.hydrix.graphical.ui;
  gaps     = let v = ui.gaps or null; in if v != null then v else 10;
  widgetX  = gaps;
  fontSize = let v = config.hydrix.graphical.font.size or null; in if v != null then v else 10;

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
  # CID = subnet last octet, so running VM IP = 192.168.<cid>.2.
  # Returns {"running":[{name,ip},...], "stopped":[{name},...]} for eww.
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

      while read -r name status cid; do
        case "$name" in microvm-*) ;; *) continue ;; esac
        short="''${name#microvm-}"
        case "$status" in
          running)
            ip="192.168.$cid.2"
            entry="{\"name\":\"$short\",\"ip\":\"$ip\"}"
            running_json=$(echo "$running_json" | jq --argjson e "$entry" '. + [$e]') ;;
          stopped)
            entry="{\"name\":\"$short\"}"
            stopped_json=$(echo "$stopped_json" | jq --argjson e "$entry" '. + [$e]') ;;
        esac
      done < <("$microvm" status 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
        || true)

      echo "{\"running\":$running_json,\"stopped\":$stopped_json}"
    '';
  };

  # Polling script: queries wifi-sync vsock 14506 (already used by wifi-sync tool).
  # Returns router POLL JSON enriched with "pending": N (connections not yet in credential store).
  ewwRouterStats = pkgs.writeShellApplication {
    name = "eww-router-stats";
    runtimeInputs = [ pkgs.socat pkgs.jq ];
    text = ''
      result=$(echo "POLL" | socat -T3 - VSOCK-CONNECT:200:14506 2>/dev/null || true)
      if [ -z "$result" ]; then
        echo '{"current":"","connections":[],"pending":0}'
      else
        pending=$(wifi-sync count 2>/dev/null || echo 0)
        echo "$result" | jq --argjson p "$pending" '. + {"pending": $p}'
      fi
    '';
  };

  # Polling script: queries net-stats vsock 14517, formats byte rates,
  # normalises direction to VM perspective (router rx/tx → VM up/down).
  ewwNetStats = pkgs.writeShellApplication {
    name = "eww-net-stats";
    runtimeInputs = [ pkgs.socat pkgs.jq ];
    text = ''
      raw=$(echo "" | socat -T4 - VSOCK-CONNECT:200:14517 2>/dev/null || true)
      [ -z "$raw" ] && { echo '{"wan":{"iface":"","down":"","up":""},"vms":[]}'; exit 0; }
      echo "$raw" | jq '
        def fmt:
          if . >= 1048576 then "\(. / 1048576 | floor)MB/s"
          elif . >= 1024 then "\(. / 1024 | floor)KB/s"
          else "\(.)B/s"
          end;
        {wan:{iface:.wan.iface,down:(.wan.rx|fmt),up:(.wan.tx|fmt)},
         vms:[.vms[]|{vm:.vm,down:(.tx|fmt),up:(.rx|fmt)}]}
      ' 2>/dev/null || echo '{"wan":{"iface":"","down":"","up":""},"vms":[]}'
    '';
  };

  # Watcher: opens left-overlay after a brief delay so the first poll cycle
  # completes before the window renders (avoids layout jitter on spawn).
  ewwLeftWatcher = pkgs.writeShellApplication {
    name = "eww-left-watch";
    runtimeInputs = [ pkgs.eww pkgs.coreutils ];
    text = ''
      sleep 3
      eww open left-overlay 2>/dev/null || true
      sleep infinity
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

    (defpoll router_stats
      :interval "5s"
      :initial "{\"current\":\"\",\"connections\":[],\"pending\":0}"
      `eww-router-stats`)

    (defpoll net_stats
      :interval "5s"
      :initial "{\"wan\":{\"iface\":\"\",\"down\":\"\",\"up\":\"\"},\"vms\":[]}"
      `eww-net-stats`)

    (defwindow left-overlay
      :monitor 0
      :geometry (geometry
        :x "${toString widgetX}px"
        :y "0px"
        :width "270px"
        :anchor "center left")
      :exclusive false
      :stacking "bottom"
      :focusable false
      (left-panel))

    (defwidget left-panel []
      (box
        :orientation "v"
        :space-evenly false
        :spacing 10
        :visible {router_stats.current != "" || arraylength(vm_status.running) > 0}
        (vm-status-widget)
        (exit-nodes-widget)
        (router-widget)))

    (defwidget router-widget []
      (box
        :class "router-stats"
        :orientation "v"
        :space-evenly false
        :spacing 0
        :visible {router_stats.current != ""}
        (label
          :class "rs-title"
          :text "NETWORK"
          :halign "start")
        (label
          :class "rs-ssid"
          :text {router_stats.current}
          :halign "start")
        (label
          :class {router_stats.pending > 0 ? "rs-pending unsaved" : "rs-pending"}
          :visible {router_stats.pending > 0}
          :text {"+" + router_stats.pending + " unsaved"}
          :halign "start")
        (net-wan-row :stats {net_stats.wan})
        (for vm in {net_stats.vms}
          (net-vm-row :vm vm))))

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
            :text {node.class == "active" ? "●" : "○"})
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
          :text {(node.location == node.endpoint ? "" : node.endpoint + "   ") + node.age + "   " + node.rx + "↓  " + node.tx + "↑  total"}
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
        (for vm in {vm_status.running}
          (vm-row-running :vm vm))
        (for vm in {vm_status.stopped}
          (vm-row-stopped :vm vm))))

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
          :class "vm-ip"
          :text {vm.ip})))

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

    (defwidget net-wan-row [stats]
      (box
        :class "net-row wan-row"
        :orientation "h"
        :space-evenly false
        :spacing 6
        (label
          :class "net-iface"
          :text {stats.iface}
          :hexpand true
          :halign "start")
        (label
          :class "net-down"
          :text {stats.down + "↓"})
        (label
          :class "net-up"
          :text {stats.up + "↑"})))

    (defwidget net-vm-row [vm]
      (box
        :class "net-row"
        :orientation "h"
        :space-evenly false
        :spacing 6
        (label
          :class "net-vm"
          :text {vm.vm}
          :hexpand true
          :halign "start")
        (label
          :class "net-down"
          :text {vm.down + "↓"})
        (label
          :class "net-up"
          :text {vm.up + "↑"})))
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

    /* router-stats */

    .router-stats {
      background-color: transparent;
      padding: 6px 10px;
    }

    .rs-title {
      font-weight: bold;
      color: $color4;
      letter-spacing: 0.06em;
      margin-bottom: 10px;
    }

    .rs-ssid {
      font-weight: bold;
      color: $foreground;
    }

    .rs-pending.unsaved {
      color: $color1;
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

    .vm-ip {
      color: $color8;
    }

    /* net-stats (rows embedded in router-widget) */

    .net-row {
      margin-top: 3px;
    }

    .wan-row {
      margin-top: 4px;
    }

    .net-iface {
      font-weight: bold;
      color: $foreground;
    }

    .net-vm {
      color: $foreground;
    }

    .net-down {
      color: $color8;
      min-width: 70px;
    }

    .net-up {
      color: $color8;
    }
  '';

  ewwYuckFile = pkgs.writeText "eww.yuck" ewwYuck;
  ewwScssFile = pkgs.writeText "eww.scss" ewwScss;
in lib.mkIf config.hydrix.hyprland.enable {

  home-manager.users.${username} = { lib, ... }: {
    home.packages = [ pkgs.eww ewwWgStatus ewwMvmStatus ewwRouterStats ewwNetStats ewwLeftWatcher ];

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
        Description = "eww left-overlay watcher";
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
