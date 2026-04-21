#!/usr/bin/env bash
# VPN Assignment Script for Router VM
# Manages which VPN tunnel each network bridge uses via policy routing.
#
# Usage:
#   vpn-assign <network> <vpn-name|direct|blocked>
#   vpn-assign browse mullvad-se      # Route browsing through Sweden
#   vpn-assign pentest mullvad-de     # Route pentest through Germany
#   vpn-assign comms direct           # Direct WAN for comms
#   vpn-assign dev blocked            # Kill switch — no traffic allowed
#   vpn-assign --persistent browse mullvad-se  # Save across reboots
#
#   vpn-assign connect mullvad-se     # Bring up WireGuard tunnel
#   vpn-assign disconnect mullvad-se  # Tear down tunnel
#   vpn-assign list-mullvad           # List available exit nodes
#   vpn-assign status                 # Show all assignments and active tunnels

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

STATE_DIR="/var/lib/hydrix-vpn"
PERSISTENT_FILE="$STATE_DIR/persistent.conf"

# Routing table names — must match /etc/iproute2/rt_tables in the router VM
declare -A ROUTING_TABLES=(
    ["pentest"]=100
    ["comms"]=101
    ["browse"]=102
    ["dev"]=103
    ["lurking"]=104
)

# Subnet for each bridge — used to set up ip rule policy routing entries
declare -A NETWORK_SUBNETS=(
    ["pentest"]="192.168.102.0/24"
    ["comms"]="192.168.104.0/24"
    ["browse"]="192.168.103.0/24"
    ["dev"]="192.168.105.0/24"
    ["lurking"]="192.168.106.0/24"
)

get_wan_interface() {
    ip route | awk '/^default/{print $5; exit}'
}

vpn_interface_exists() {
    ip link show "$1" &>/dev/null
}

get_vpn_interface() {
    local name="$1"
    ip link show "$name" &>/dev/null && echo "$name" && return
    ip link show "tun-${name}" &>/dev/null && echo "tun-${name}" && return
    echo ""
}

# Ensure ip rule entries exist for all networks so policy routing triggers.
# Idempotent — safe to call multiple times.
ensure_ip_rules() {
    for network in "${!ROUTING_TABLES[@]}"; do
        local subnet="${NETWORK_SUBNETS[$network]}"
        local prio="${ROUTING_TABLES[$network]}"
        if ! ip rule show | grep -q "from $subnet lookup $network"; then
            ip rule add from "$subnet" lookup "$network" priority "$prio" 2>/dev/null || true
        fi
    done
}

update_routing() {
    local network="$1"
    local target="$2"

    if [[ -z "${ROUTING_TABLES[$network]+_}" ]]; then
        echo -e "${RED}Error: Unknown network '$network'${NC}"
        return 1
    fi

    ensure_ip_rules

    ip route flush table "$network" 2>/dev/null || true

    case "$target" in
        blocked)
            # Empty table = no route = all traffic dropped (kill switch)
            echo -e "${YELLOW}[$network]${NC} Blocked (kill switch)"
            ;;
        direct)
            local wan gw
            wan=$(get_wan_interface)
            [ -z "$wan" ] && { echo -e "${RED}Error: No WAN interface${NC}"; return 1; }
            gw=$(ip route | awk "/default.*$wan/{print \$3}")
            if [ -n "$gw" ]; then
                ip route add default via "$gw" dev "$wan" table "$network"
            else
                ip route add default dev "$wan" table "$network"
            fi
            echo -e "${GREEN}[$network]${NC} Direct WAN ($wan)"
            ;;
        *)
            local vpn_if
            vpn_if=$(get_vpn_interface "$target")
            if [ -z "$vpn_if" ]; then
                echo -e "${RED}Error: '$target' is not connected${NC}"
                echo -e "${YELLOW}Run first: vpn-assign connect $target${NC}"
                return 1
            fi
            ip route add default dev "$vpn_if" table "$network"
            echo -e "${GREEN}[$network]${NC} → $vpn_if"
            ;;
    esac

    echo "$target" > "$STATE_DIR/${network}.assignment"
}

connect_vpn() {
    local vpn_name="$1"
    local conf="/etc/wireguard/${vpn_name}.conf"

    [ -f "$conf" ] || { echo -e "${RED}No WireGuard config for '$vpn_name'${NC}"; return 1; }

    if ip link show "$vpn_name" &>/dev/null; then
        echo -e "${YELLOW}$vpn_name already connected${NC}"
        return 0
    fi

    # wg-quick with Table=off only creates the interface + peer config.
    # The main routing table's default route (WAN) handles endpoint reachability.
    echo -e "${BLUE}Connecting $vpn_name...${NC}"
    wg-quick up "$vpn_name"
    echo -e "${GREEN}Connected: $vpn_name${NC}"
}

disconnect_vpn() {
    local vpn_name="$1"

    if ! ip link show "$vpn_name" &>/dev/null; then
        echo -e "${YELLOW}$vpn_name not connected${NC}"
        return 0
    fi

    # Clear any bridge assignments using this tunnel before tearing down
    for network in "${!ROUTING_TABLES[@]}"; do
        local assignment=""
        [ -f "$STATE_DIR/${network}.assignment" ] && assignment=$(cat "$STATE_DIR/${network}.assignment")
        if [ "$assignment" = "$vpn_name" ]; then
            ip route flush table "$network" 2>/dev/null || true
            echo -e "${YELLOW}Cleared routing for $network (was → $vpn_name)${NC}"
        fi
    done

    wg-quick down "$vpn_name"
    echo -e "${GREEN}Disconnected: $vpn_name${NC}"
}

show_status() {
    echo -e "${BLUE}=== VPN Routing Status ===${NC}"
    echo ""
    local wan
    wan=$(get_wan_interface)
    echo -e "WAN: ${GREEN}${wan:-none}${NC}"
    echo ""

    echo -e "${BLUE}Bridge Assignments:${NC}"
    for network in pentest comms browse dev lurking; do
        local assignment="blocked"
        [ -f "$STATE_DIR/${network}.assignment" ] && assignment=$(cat "$STATE_DIR/${network}.assignment")

        local color="$RED" icon="✗"
        case "$assignment" in
            blocked) ;;
            direct) color="$GREEN"; icon="→" ;;
            *)
                if vpn_interface_exists "$assignment"; then
                    color="$GREEN"; icon="🔒"
                else
                    color="$YELLOW"; icon="⚠"
                    assignment="$assignment (disconnected)"
                fi
                ;;
        esac
        printf "  %-10s ${color}%s %s${NC}\n" "$network:" "$icon" "$assignment"
    done
    echo ""

    echo -e "${BLUE}Active Tunnels:${NC}"
    local found=false
    while IFS= read -r iface; do
        found=true
        local ip_addr
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet/{print $2}' | head -1)
        echo -e "  ${GREEN}$iface${NC}  $ip_addr"
    done < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(mullvad-|wg-|tun)' || true)
    [ "$found" = false ] && echo -e "  ${YELLOW}none${NC}"
    echo ""

    echo -e "${BLUE}Routing Tables:${NC}"
    for network in pentest comms browse dev lurking; do
        local route
        route=$(ip route show table "$network" 2>/dev/null | head -1)
        if [ -n "$route" ]; then
            echo -e "  $network: ${GREEN}$route${NC}"
        else
            echo -e "  $network: ${RED}(empty — blocked)${NC}"
        fi
    done
}

list_mullvad() {
    echo -e "${CYAN}=== Mullvad Exit Nodes ===${NC}"
    echo ""
    local found=false
    for conf in /etc/wireguard/mullvad-*.conf; do
        [ -f "$conf" ] || continue
        found=true
        local name endpoint active
        name=$(basename "$conf" .conf)
        endpoint=$(awk -F'= *' '/^Endpoint/{print $2}' "$conf" | head -1)
        if ip link show "$name" &>/dev/null; then
            active="${GREEN}[UP]${NC}"
        else
            active="${RED}[DOWN]${NC}"
        fi
        printf "  %-15b ${YELLOW}%-45s${NC} %b\n" "$name" "$endpoint" "$active"
    done
    [ "$found" = false ] && echo -e "${YELLOW}No Mullvad configs — fill in vpn/mullvad.nix and rebuild the router.${NC}"
    echo ""
    echo -e "${BLUE}Workflow:${NC}"
    echo "  vpn-assign connect mullvad-se        # bring up tunnel"
    echo "  vpn-assign browse mullvad-se         # route browsing VM through it"
    echo "  vpn-assign pentest mullvad-de        # route pentest VM through Germany"
    echo "  vpn-assign --persistent browse mullvad-se"
}

save_persistent() {
    local network="$1" target="$2"

    if [ ! -f "$PERSISTENT_FILE" ]; then
        printf '# Hydrix VPN persistent assignments\n# network=target\n' > "$PERSISTENT_FILE"
        for n in pentest comms browse dev lurking; do
            echo "${n}=direct" >> "$PERSISTENT_FILE"
        done
    fi

    if grep -q "^${network}=" "$PERSISTENT_FILE"; then
        sed -i "s|^${network}=.*|${network}=${target}|" "$PERSISTENT_FILE"
    else
        echo "${network}=${target}" >> "$PERSISTENT_FILE"
    fi

    echo -e "${GREEN}Saved: $network → $target${NC}"
}

usage() {
    cat << EOF
Usage: vpn-assign <command> [args]

  <network> <target>          Assign bridge to VPN/direct/blocked
  --persistent <net> <tgt>    Assign and save across reboots
  connect <vpn>               Bring up WireGuard tunnel
  disconnect <vpn>            Tear down tunnel
  list-mullvad                List configured Mullvad exit nodes
  status                      Show assignments and active tunnels
  help                        This help

Networks:  pentest  comms  browse  dev  lurking
Targets:   mullvad-se  mullvad-de  ...  direct  blocked
EOF
}

main() {
    mkdir -p "$STATE_DIR"

    case "${1:-}" in
        ""|status)    show_status ;;
        list-mullvad) list_mullvad ;;
        connect)
            [ -z "${2:-}" ] && { echo -e "${RED}VPN name required${NC}"; exit 1; }
            connect_vpn "$2"
            ;;
        disconnect)
            [ -z "${2:-}" ] && { echo -e "${RED}VPN name required${NC}"; exit 1; }
            disconnect_vpn "$2"
            ;;
        --persistent|-p)
            [[ -z "${2:-}" || -z "${3:-}" ]] && { echo -e "${RED}Usage: vpn-assign --persistent <network> <target>${NC}"; exit 1; }
            [[ "${2}" =~ ^(pentest|comms|browse|dev|lurking)$ ]] || { echo -e "${RED}Unknown network '$2'${NC}"; exit 1; }
            update_routing "$2" "$3"
            save_persistent "$2" "$3"
            ;;
        help|--help|-h) usage ;;
        pentest|comms|browse|dev|lurking)
            [ -z "${2:-}" ] && { echo -e "${RED}Target required${NC}"; exit 1; }
            update_routing "$1" "$2"
            ;;
        *)
            echo -e "${RED}Unknown command '$1'${NC}"
            usage; exit 1
            ;;
    esac
}

main "$@"
