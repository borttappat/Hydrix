# Router LAN Control Service
#
# Vsock control endpoint for managing pentest VM LAN access.
# Listens on vsock port 14515 for commands from host.
#
# Commands:
#   ENABLE_LAN <CID>     - Bridge VM with CID to physical network
#   DISABLE_LAN <CID>    - Isolate VM from physical network
#   PORT_ADD <CID> <PORT> - Forward port to VM
#   PORT_REMOVE <CID> <PORT> - Remove port forward
#   LAN_STATUS           - Show current LAN access state
#
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/hydrix-router";
in

{
  # State persistence directory
  environment.etc = {
    "hydrix-router/lan-state.json".text = ''
      {
        "enabledVMs": [],
        "portForwards": []
      }
    '';
  };

  systemd.services.router-lan-control = {
    description = "LAN access control handler";
    wantedBy = [ "multi-user.target" ];
    after = [ "router-network-setup.service" "router-firewall.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = let
      lanControlScript = pkgs.writeShellScript "lan-control" ''
        #!/usr/bin/env bash
        set -euo pipefail

        STATE_FILE="${stateDir}/lan-state.json"
        LOG_FILE="${stateDir}/lan-control.log"
        PHYSICAL_IF="${stateDir}/wan_interface"

        log() {
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
        }

        init_state() {
          mkdir -p "$(dirname "$STATE_FILE")" "$stateDir"
          if [ ! -f "$STATE_FILE" ]; then
            echo '{"enabledVMs":[],"portForwards":[]}' > "$STATE_FILE"
          fi
        }

        get_wan_iface() {
          if [ -f "$PHYSICAL_IF" ]; then
            cat "$PHYSICAL_IF"
          else
            for iface in $(ls /sys/class/net/ 2>/dev/null); do
              if [[ "$iface" == wl* ]] || [[ -d "/sys/class/net/$iface/wireless" ]]; then
                echo "$iface"
                return
              fi
            done
            echo "wlan0"
          fi
        }

        get_vm_tap() {
          local cid="$1"
          # CID 102 = pentest VM tap
          case "$cid" in
            102) echo "mv-router-pent" ;;
            *) echo "" ;;
          esac
        }

        enable_lan() {
          local cid="$1"
          local tap_iface="$2"
          local wan_iface=$(get_wan_iface)

          log "ENABLING LAN for CID $cid (tap: $tap_iface, wan: $wan_iface)"

          # Create bridge
          local bridge_name="br-pentest-lan"
          if ! ip link show "$bridge_name" &>/dev/null; then
            ip link add name "$bridge_name" type bridge
            ip link set "$bridge_name" up
            log "Created bridge $bridge_name"
          fi

          # Add tap to bridge
          if [ -n "$tap_iface" ] && ip link show "$tap_iface" &>/dev/null; then
            ip link set "$tap_iface" master "$bridge_name"
            ip link set "$tap_iface" up
            log "Added $tap_iface to $bridge_name"
          fi

          # Enable forwarding
          echo 1 > /proc/sys/net/ipv4/conf/all/forwarding
          echo 1 > /proc/sys/net/ipv4/conf/$bridge_name/forwarding

          # Update state
          local tmp_file=$(mktemp)
          jq --arg cid "$cid" 'if .enabledVMs | index($cid) then . else .enabledVMs += [$cid] end' "$STATE_FILE" > "$tmp_file"
          mv "$tmp_file" "$STATE_FILE"

          log "LAN enabled for CID $cid"
          echo "OK: LAN enabled for CID $cid"
        }

        disable_lan() {
          local cid="$1"
          local tap_iface="$2"
          local bridge_name="br-pentest-lan"

          log "DISABLING LAN for CID $cid"

          # Remove from bridge
          if [ -n "$tap_iface" ] && ip link show "$tap_iface" &>/dev/null; then
            ip link set "$tap_iface" nomaster 2>/dev/null || true
            log "Removed $tap_iface from bridge"
          fi

          # Cleanup bridge if empty
          local bridge_ports=$(ip link show type bridge_slave 2>/dev/null | grep -c "$bridge_name" || echo "0")
          if [ "$bridge_ports" = "0" ]; then
            ip link set "$bridge_name" down 2>/dev/null || true
            ip link delete "$bridge_name" 2>/dev/null || true
            log "Removed bridge $bridge_name"
          fi

          # Update state
          local tmp_file=$(mktemp)
          jq --arg cid "$cid" '.enabledVMs = [.enabledVMs[] | select(. != $cid)]' "$STATE_FILE" > "$tmp_file"
          mv "$tmp_file" "$STATE_FILE"

          log "LAN disabled for CID $cid"
          echo "OK: LAN disabled for CID $cid"
        }

        add_port_forward() {
          local cid="$1"
          local port="$2"
          local tap_iface="$3"
          local wan_iface=$(get_wan_iface)

          log "Adding port forward: $port -> CID $cid"

          # DNAT rule (pentest subnet is 192.168.102.x)
          local vm_ip="192.168.102.$cid"
          iptables -t nat -A PREROUTING -i "$wan_iface" -p tcp --dport "$port" -j DNAT --to-destination "${vm_ip}:${port}" 2>/dev/null || true
          if [ -n "$tap_iface" ]; then
            iptables -I FORWARD 1 -i "$wan_iface" -o "$tap_iface" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
          fi

          local tmp_file=$(mktemp)
          jq --arg cid "$cid" --arg port "$port" '.portForwards += [{"cid": $cid, "port": $port}]' "$STATE_FILE" > "$tmp_file"
          mv "$tmp_file" "$STATE_FILE"

          log "Port $port forwarded to CID $cid"
          echo "OK: Port $port forwarded"
        }

        remove_port_forward() {
          local cid="$1"
          local port="$2"
          local wan_iface=$(get_wan_iface)

          log "Removing port forward: $port from CID $cid"

          local vm_ip="192.168.102.$cid"
          iptables -t nat -D PREROUTING -i "$wan_iface" -p tcp --dport "$port" -j DNAT --to-destination "${vm_ip}:${port}" 2>/dev/null || true
          iptables -D FORWARD -i "$wan_iface" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true

          local tmp_file=$(mktemp)
          jq --arg port "$port" '.portForwards = [.portForwards[] | select(.port != $port)]' "$STATE_FILE" > "$tmp_file"
          mv "$tmp_file" "$STATE_FILE"

          log "Port $port removed"
          echo "OK: Port $port removed"
        }

        show_status() {
          echo "=== LAN Access Status ==="
          echo ""
          echo "Enabled VMs:"
          jq -r '.enabledVMs[] | "  CID " + .' "$STATE_FILE" 2>/dev/null || echo "  (none)"
          echo ""
          echo "Port Forwards:"
          jq -r '.portForwards[] | "  " + .cid + ":" + .port' "$STATE_FILE" 2>/dev/null || echo "  (none)"
          echo ""
          echo "Bridge: br-pentest-lan"
          ip link show br-pentest-lan 2>/dev/null || echo "  (not created)"
          echo ""
          echo "WAN Interface: $(get_wan_iface)"
        }

        init_state
        read -r cmd arg1 arg2 arg3

        case "$cmd" in
          ENABLE_LAN)
            enable_lan "$arg1" "$(get_vm_tap "$arg1")"
            ;;
          DISABLE_LAN)
            disable_lan "$arg1" "$(get_vm_tap "$arg1")"
            ;;
          PORT_ADD)
            add_port_forward "$arg1" "$arg2" "$(get_vm_tap "$arg1")"
            ;;
          PORT_REMOVE)
            remove_port_forward "$arg1" "$arg2"
            ;;
          LAN_STATUS|STATUS)
            show_status
            ;;
          PING)
            echo "OK"
            ;;
          *)
            echo "Unknown: $cmd"
            echo "Commands: ENABLE_LAN, DISABLE_LAN, PORT_ADD, PORT_REMOVE, LAN_STATUS, PING"
            ;;
        esac
      '';
    in "${lanControlScript}";
  };

  # Vsock server on port 14515
  systemd.services.lan-control-server = {
    description = "LAN control vsock server (port 14515)";
    wantedBy = [ "multi-user.target" ];
    after = [ "router-lan-control.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14515,reuseaddr,fork EXEC:/run/current-system/sw/bin/router-lan-control";
      Restart = "always";
    };
  };

  # Packages
  environment.systemPackages = with pkgs; [
    jq
    bridge-utils
  ];
}
