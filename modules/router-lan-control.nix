# Router LAN Control Service
#
# Vsock control endpoint for managing pentest VM LAN access.
# Listens on vsock port 14515 for commands from host.
#
# Commands:
#   ENABLE_LAN <CID>          - Bridge VM with CID to physical network
#   DISABLE_LAN <CID>         - Isolate VM from physical network
#   PORT_ADD <CID> <PORT>     - Forward port to VM
#   PORT_REMOVE <CID> <PORT>  - Remove port forward
#   LAN_STATUS                - Show current LAN access state
#   PING                      - Health check
#
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/hydrix-router";

  lanControlBin = pkgs.writeShellScriptBin "router-lan-control" ''
    #!/usr/bin/env bash
    set -euo pipefail

    export PATH="${pkgs.iproute2}/bin:${pkgs.iptables}/bin:${pkgs.coreutils}/bin:$PATH"

    STATE_FILE="${stateDir}/lan-state.json"
    LOG_FILE="${stateDir}/lan-control.log"
    PHYSICAL_IF="${stateDir}/wan_interface"

    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
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
      case "''${1}" in
        102) echo "mv-router-pent" ;;
        *) echo "" ;;
      esac
    }

    # Derive VM subnet from CID (convention: 192.168.<cid>.0/24)
    get_vm_subnet() {
      echo "192.168.''${1}.0/24"
    }

    enable_lan() {
      local cid="''${1}"
      local tap_iface="''${2}"
      local wan_iface
      wan_iface=$(get_wan_iface)
      local vm_subnet
      vm_subnet=$(get_vm_subnet "$cid")

      log "ENABLING LAN for CID $cid subnet=$vm_subnet tap=$tap_iface wan=$wan_iface"

      # Enable forwarding from VM tap to WAN
      iptables -I FORWARD 1 -i "$tap_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || true
      # Allow established/related return traffic
      iptables -I FORWARD 1 -i "$wan_iface" -o "$tap_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      # MASQUERADE so LAN hosts see traffic as coming from router's WAN IP (replies return correctly)
      iptables -t nat -I POSTROUTING 1 -s "$vm_subnet" -o "$wan_iface" -j MASQUERADE 2>/dev/null || true

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg cid "$cid" \
        'if .enabledVMs | index($cid) then . else .enabledVMs += [$cid] end' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      log "LAN enabled for CID $cid"
      echo "OK: LAN enabled for CID $cid via $wan_iface (MASQUERADE as $(ip addr show "$wan_iface" | awk '/inet / {print $2}' | cut -d/ -f1))"
    }

    disable_lan() {
      local cid="''${1}"
      local tap_iface="''${2}"
      local wan_iface
      wan_iface=$(get_wan_iface)
      local vm_subnet
      vm_subnet=$(get_vm_subnet "$cid")

      log "DISABLING LAN for CID $cid"

      iptables -D FORWARD -i "$tap_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i "$wan_iface" -o "$tap_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -t nat -D POSTROUTING -s "$vm_subnet" -o "$wan_iface" -j MASQUERADE 2>/dev/null || true

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg cid "$cid" \
        '.enabledVMs = [.enabledVMs[] | select(. != $cid)]' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      log "LAN disabled for CID $cid"
      echo "OK: LAN disabled for CID $cid"
    }

    add_port_forward() {
      local cid="''${1}"
      local port="''${2}"
      local tap_iface="''${3}"
      local wan_iface
      wan_iface=$(get_wan_iface)
      local vm_ip="192.168.102.$cid"

      log "Adding port forward: $port -> CID $cid"

      iptables -t nat -A PREROUTING -i "$wan_iface" -p tcp --dport "$port" \
        -j DNAT --to-destination "$vm_ip:$port" 2>/dev/null || true
      if [ -n "$tap_iface" ]; then
        iptables -I FORWARD 1 -i "$wan_iface" -o "$tap_iface" -p tcp --dport "$port" \
          -j ACCEPT 2>/dev/null || true
      fi

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg cid "$cid" --arg port "$port" \
        '.portForwards += [{"cid": $cid, "port": $port}]' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      log "Port $port forwarded to CID $cid"
      echo "OK: Port $port forwarded"
    }

    remove_port_forward() {
      local cid="''${1}"
      local port="''${2}"
      local wan_iface
      wan_iface=$(get_wan_iface)
      local vm_ip="192.168.102.$cid"

      log "Removing port forward: $port from CID $cid"

      iptables -t nat -D PREROUTING -i "$wan_iface" -p tcp --dport "$port" \
        -j DNAT --to-destination "$vm_ip:$port" 2>/dev/null || true
      iptables -D FORWARD -i "$wan_iface" -p tcp --dport "$port" \
        -j ACCEPT 2>/dev/null || true

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg port "$port" \
        '.portForwards = [.portForwards[] | select(.port != $port)]' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      log "Port $port removed"
      echo "OK: Port $port removed"
    }

    show_status() {
      local wan_iface
      wan_iface=$(get_wan_iface)
      echo "=== LAN Access Status ==="
      echo ""
      echo "Enabled VMs:"
      ${pkgs.jq}/bin/jq -r '.enabledVMs[] | "  CID " + .' "$STATE_FILE" 2>/dev/null || echo "  (none)"
      echo ""
      echo "Port Forwards:"
      ${pkgs.jq}/bin/jq -r '.portForwards[] | "  " + .cid + ":" + .port' "$STATE_FILE" 2>/dev/null || echo "  (none)"
      echo ""
      echo "WAN Interface: $wan_iface ($(ip addr show "$wan_iface" 2>/dev/null | awk '/inet / {print $2}' | head -1 || echo "no IP"))"
      echo ""
      echo "Active MASQUERADE rules:"
      iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQUERADE || echo "  (none)"
    }

    # Ensure state file exists
    mkdir -p "${stateDir}"
    if [ ! -f "$STATE_FILE" ]; then
      echo '{"enabledVMs":[],"portForwards":[]}' > "$STATE_FILE"
    fi

    read -r cmd arg1 arg2 arg3

    case "$cmd" in
      ENABLE_LAN)  enable_lan "$arg1" "$(get_vm_tap "$arg1")" ;;
      DISABLE_LAN) disable_lan "$arg1" "$(get_vm_tap "$arg1")" ;;
      PORT_ADD)    add_port_forward "$arg1" "$arg2" "$(get_vm_tap "$arg1")" ;;
      PORT_REMOVE) remove_port_forward "$arg1" "$arg2" ;;
      LAN_STATUS|STATUS) show_status ;;
      PING)        echo "OK" ;;
      *)           echo "Unknown: $cmd"; echo "Commands: ENABLE_LAN, DISABLE_LAN, PORT_ADD, PORT_REMOVE, LAN_STATUS, PING" ;;
    esac
  '';
in

{
  environment.systemPackages = [ lanControlBin pkgs.jq pkgs.iptables ];

  # Init: ensure state dir exists at boot
  systemd.services.router-lan-control = {
    description = "LAN access control state init";
    wantedBy = [ "multi-user.target" ];
    after = [ "router-network-setup.service" "router-firewall.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = let
        initScript = pkgs.writeShellScript "lan-control-init" ''
          mkdir -p ${stateDir}
          if [ ! -f ${stateDir}/lan-state.json ]; then
            echo '{"enabledVMs":[],"portForwards":[]}' > ${stateDir}/lan-state.json
          fi
        '';
      in "${initScript}";
    };
  };

  # Vsock server on port 14515
  systemd.services.lan-control-server = {
    description = "LAN control vsock server (port 14515)";
    wantedBy = [ "multi-user.target" ];
    after = [ "router-lan-control.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14515,reuseaddr,fork EXEC:${lanControlBin}/bin/router-lan-control";
      Restart = "always";
    };
  };
}
