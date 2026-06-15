# Router LAN Control Service
#
# Vsock control endpoint for managing pentest VM LAN access.
# Listens on vsock port 14516 for commands from host.
#
# Commands:
#   ENABLE_LAN <CID>          - Bridge VM with CID to physical network
#   DISABLE_LAN <CID>         - Isolate VM from physical network
#   PORT_ADD <CID> <PORT> <VM_IP>  - Forward port to VM (host resolves IP first)
#   PORT_REMOVE <CID> <PORT>  - Remove port forward
#   LAN_STATUS                - Show current LAN access state
#   PING                      - Health check
#   DEBUG_NAT                 - Show all NAT/FORWARD rules
#   DEBUG_RULESET             - Dump full nft ruleset
#   DEBUG_IP <CID>            - Debug IP lookup for a CID
#   RESET_STATE               - Reset state file
#
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/hydrix-router";

  lanControlBin = pkgs.writeShellScriptBin "router-lan-control" ''
    #!/usr/bin/env bash
    set -euo pipefail

    export PATH="${pkgs.iproute2}/bin:${pkgs.iptables}/bin:${pkgs.nftables}/bin:${pkgs.coreutils}/bin:$PATH"

    STATE_FILE="${stateDir}/lan-state.json"
    LOG_FILE="${stateDir}/lan-control.log"
    PHYSICAL_IF="${stateDir}/wan_interface"

    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
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

    # Look up VM's current IP — tries dnsmasq leases, then ARP (with ping to populate)
    get_vm_ip() {
      local cid="''${1}"
      local prefix="192.168.$cid."
      local ip=""

      # Try dnsmasq lease file
      for lease_file in /var/lib/dnsmasq/dnsmasq.leases /var/lib/misc/dnsmasq.leases /tmp/dnsmasq.leases; do
        if [ -f "$lease_file" ]; then
          ip=$(awk -v p="$prefix" '$3 ~ "^" p {print $3; exit}' "$lease_file" 2>/dev/null || true)
          [ -n "$ip" ] && break
        fi
      done

      # Ping broadcast to solicit ARP replies from all VMs on the subnet, then recheck
      if [ -z "$ip" ]; then
        ping -c 1 -W 1 -b "''${prefix}255" &>/dev/null || true
        ip=$(ip neigh show 2>/dev/null | awk -v p="$prefix" '$1 ~ "^" p {print $1; exit}' || true)
      fi

      echo "$ip"
    }

    # Get connected LAN subnet from WAN interface (e.g. 192.168.0.0/24 from wlp1s0)
    get_lan_subnet() {
      ip route show dev "''${1}" 2>/dev/null | awk '/scope link/ {print $1; exit}' || true
    }

    enable_lan() {
      local cid="''${1}"
      local tap_iface="''${2}"
      local wan_iface
      wan_iface=$(get_wan_iface)
      local vm_subnet
      vm_subnet=$(get_vm_subnet "$cid")
      local wan_ip
      wan_ip=$(ip addr show "$wan_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1 || true)
      local lan_subnet
      lan_subnet=$(get_lan_subnet "$wan_iface" || true)

      log "ENABLING LAN for CID $cid subnet=$vm_subnet tap=$tap_iface wan=$wan_iface ip=$wan_ip lan=$lan_subnet"

      # Enable forwarding from VM tap to WAN
      iptables -I FORWARD 1 -i "$tap_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || true
      # Allow established/related return traffic
      iptables -I FORWARD 1 -i "$wan_iface" -o "$tap_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      # MASQUERADE so LAN hosts see traffic as coming from router's WAN IP
      iptables -t nat -I POSTROUTING 1 -s "$vm_subnet" -o "$wan_iface" -j MASQUERADE 2>/dev/null || true

      # Policy routing: VM traffic destined for the local LAN bypasses VPN and goes
      # directly via the WAN interface (main table has the connected route).
      # Without this, per-VM WireGuard tunnels would intercept LAN-destined traffic.
      if [ -n "$lan_subnet" ]; then
        ip rule del from "$vm_subnet" to "$lan_subnet" lookup main priority 100 2>/dev/null || true
        ip rule add from "$vm_subnet" to "$lan_subnet" lookup main priority 100 2>/dev/null || true
        log "Added policy route: $vm_subnet -> $lan_subnet via main table (bypasses VPN)"
      fi

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg cid "$cid" \
        'if .enabledVMs | index($cid) then . else .enabledVMs += [$cid] end' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      log "LAN enabled for CID $cid"
      echo "OK: LAN enabled for CID $cid via $wan_iface (MASQUERADE as $wan_ip, LAN $lan_subnet direct)"
    }

    disable_lan() {
      local cid="''${1}"
      local tap_iface="''${2}"
      local wan_iface
      wan_iface=$(get_wan_iface)
      local vm_subnet
      vm_subnet=$(get_vm_subnet "$cid")
      local lan_subnet
      lan_subnet=$(get_lan_subnet "$wan_iface" || true)

      log "DISABLING LAN for CID $cid"

      iptables -D FORWARD -i "$tap_iface" -o "$wan_iface" -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i "$wan_iface" -o "$tap_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -t nat -D POSTROUTING -s "$vm_subnet" -o "$wan_iface" -j MASQUERADE 2>/dev/null || true

      # Remove LAN bypass policy rule
      if [ -n "$lan_subnet" ]; then
        ip rule del from "$vm_subnet" to "$lan_subnet" lookup main priority 100 2>/dev/null || true
        log "Removed policy route: $vm_subnet -> $lan_subnet"
      fi

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg cid "$cid" \
        '.enabledVMs = [.enabledVMs[] | select(. != $cid)]' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      log "LAN disabled for CID $cid"
      echo "OK: LAN disabled for CID $cid"
    }

    # Ensure hydrix-lan nft table and chains exist (idempotent)
    ensure_nft_table() {
      nft add table ip hydrix-lan 2>/dev/null || true
      nft add chain ip hydrix-lan prerouting \
        '{ type nat hook prerouting priority -100; policy accept; }' 2>/dev/null || true
      nft add chain ip hydrix-lan forward \
        '{ type filter hook forward priority -1; policy accept; }' 2>/dev/null || true
    }

    add_port_forward() {
      local cid="''${1}"
      local port="''${2}"
      local vm_ip="''${3}"
      local tap_iface="''${4}"
      local wan_iface
      wan_iface=$(get_wan_iface)

      if [ -z "$vm_ip" ]; then
        echo "ERROR: no VM IP provided for CID $cid"
        exit 1
      fi

      log "Adding port forward: $port -> $vm_ip (CID $cid, wan=$wan_iface tap=$tap_iface)"

      ensure_nft_table

      # DNAT inbound TCP on WAN to VM
      nft add rule ip hydrix-lan prerouting \
        iif "$wan_iface" tcp dport "$port" dnat to "$vm_ip:$port"

      # Allow forwarded traffic from WAN to VM tap
      # Must add to BOTH hydrix-lan (ip, prio -1) AND main inet router forward chain (prio 0, policy drop)
      # Without the inet router rule, the main chain's DROP policy kills the DNAT-redirected packets
      if [ -n "$tap_iface" ]; then
        nft add rule ip hydrix-lan forward \
          iif "$wan_iface" oif "$tap_iface" tcp dport "$port" accept
        nft add rule inet router forward \
          iif "$wan_iface" oif "$tap_iface" tcp dport "$port" accept 2>/dev/null || true
      fi

      local tmp_file
      tmp_file=$(mktemp)
      ${pkgs.jq}/bin/jq --arg cid "$cid" --arg port "$port" --arg ip "$vm_ip" \
        'if .portForwards | map(select(.port==$port and .cid==$cid)) | length == 0
         then .portForwards += [{"cid": $cid, "port": $port, "ip": $ip}]
         else . end' \
        "$STATE_FILE" > "$tmp_file"
      mv "$tmp_file" "$STATE_FILE"

      local wan_ip
      wan_ip=$(ip addr show "$wan_iface" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
      log "Port $port forwarded to $vm_ip"
      echo "OK: $port → $vm_ip:$port  (connect to $wan_ip:$port from LAN)"
    }

    remove_port_forward() {
      local cid="''${1}"
      local port="''${2}"

      log "Removing port forward: $port from CID $cid"

      # Delete all matching rules by handle from ip hydrix-lan chains
      for chain in prerouting forward; do
        while true; do
          local handle
          handle=$(nft -a list chain ip hydrix-lan "$chain" 2>/dev/null \
            | awk -v p="$port" '$0 ~ "dport " p {
                for(i=1;i<=NF;i++) if($i=="handle") { print $(i+1); exit }
              }' || true)
          [ -z "$handle" ] && break
          nft delete rule ip hydrix-lan "$chain" handle "$handle" 2>/dev/null || true
          log "Deleted ip hydrix-lan $chain handle $handle (port $port)"
        done
      done

      # Also remove the rule from main inet router forward chain (added for reverse shell support)
      while true; do
        local handle
        handle=$(nft -a list chain inet router forward 2>/dev/null \
          | awk -v p="$port" '$0 ~ "dport " p {
              for(i=1;i<=NF;i++) if($i=="handle") { print $(i+1); exit }
            }' || true)
        [ -z "$handle" ] && break
        nft delete rule inet router forward handle "$handle" 2>/dev/null || true
        log "Deleted inet router forward handle $handle (port $port)"
      done

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
      local wan_ip
      wan_ip=$(ip addr show "$wan_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1 || true)
      local lan_subnet
      lan_subnet=$(get_lan_subnet "$wan_iface" || true)
      echo "=== LAN Access Status ==="
      echo ""
      echo "Enabled VMs:"
      ${pkgs.jq}/bin/jq -r '.enabledVMs[] | "  CID " + .' "$STATE_FILE" 2>/dev/null || echo "  (none)"
      echo ""
      echo "Port Forwards:"
      ${pkgs.jq}/bin/jq -r '.portForwards[] | "  " + .cid + ":" + .port' "$STATE_FILE" 2>/dev/null || echo "  (none)"
      echo ""
      echo "WAN Interface: $wan_iface (''${wan_ip:-no IP})"
      echo "Local LAN:     ''${lan_subnet:-(unknown)}"
      echo ""
      echo "Active MASQUERADE rules:"
      iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQUERADE || echo "  (none)"
      echo ""
      echo "LAN bypass policy rules:"
      ip rule show 2>/dev/null | grep "lookup main" | grep -v "^0:" | grep -v "^32766:" | sed 's/^/  /' || echo "  (none)"
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
      PORT_ADD)    add_port_forward "$arg1" "$arg2" "$arg3" "$(get_vm_tap "$arg1")" ;;
      PORT_REMOVE) remove_port_forward "$arg1" "$arg2" ;;
      LAN_STATUS|STATUS) show_status ;;
      PING)        echo "OK" ;;
      DEBUG_NAT)
        echo "=== PREROUTING (DNAT) ==="
        iptables -t nat -L PREROUTING -n -v 2>/dev/null || echo "(none)"
        echo ""
        echo "=== FORWARD chain ==="
        iptables -L FORWARD -n -v 2>/dev/null || echo "(none)"
        echo ""
        echo "=== POSTROUTING (MASQUERADE) ==="
        iptables -t nat -L POSTROUTING -n -v 2>/dev/null || echo "(none)"
        echo ""
        echo "=== nft nat table ==="
        nft list table ip nat 2>/dev/null || echo "(no nft nat table)"
        echo ""
        echo "=== nft hydrix-lan table ==="
        nft list table ip hydrix-lan 2>/dev/null || echo "(no hydrix-lan table)"
        ;;
      RESET_STATE)
        echo '{"enabledVMs":[],"portForwards":[]}' > "$STATE_FILE"
        log "State reset"
        echo "OK: state reset"
        ;;
      DEBUG_RULESET)
        nft list ruleset 2>/dev/null || echo "(nft error)"
        ;;
      DEBUG_IP)
        echo "=== IP lookup debug for CID $arg1 ==="
        echo "Lease files:"
        for f in /var/lib/dnsmasq/dnsmasq.leases /var/lib/misc/dnsmasq.leases /tmp/dnsmasq.leases; do
          [ -f "$f" ] && echo "  $f:" && cat "$f" || echo "  $f: not found"
        done
        echo "ARP/neigh (192.168.$arg1.x):"
        ip neigh show 2>/dev/null | grep "192.168.$arg1\." || echo "  (none)"
        echo "Resolved IP: $(get_vm_ip "$arg1")"
        ;;
      *)           echo "Unknown: $cmd"; echo "Commands: ENABLE_LAN, DISABLE_LAN, PORT_ADD, PORT_REMOVE, LAN_STATUS, PING, DEBUG_IP, DEBUG_NAT, DEBUG_RULESET, RESET_STATE" ;;
    esac
  '';
in

{
  environment.systemPackages = [ lanControlBin pkgs.jq pkgs.iptables pkgs.nftables ];

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

  # Vsock server on port 14516
  systemd.services.lan-control-server = {
    description = "LAN control vsock server (port 14516)";
    wantedBy = [ "multi-user.target" ];
    after = [ "router-lan-control.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14516,reuseaddr,fork EXEC:${lanControlBin}/bin/router-lan-control";
      Restart = "always";
    };
  };
}
