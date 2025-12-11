#!/usr/bin/env bash
# VPN Assignment Script for Router VM
# Manages which VPN tunnel each network uses
#
# Usage:
#   vpn-assign <network> <vpn-name|direct|blocked>
#   vpn-assign pentest client-vpn    # Route pentest traffic through client-vpn
#   vpn-assign browse mullvad        # Route browsing through mullvad
#   vpn-assign office direct         # Direct WAN access for office
#   vpn-assign dev blocked           # Kill switch only, no traffic allowed
#
# This script runs on the Router VM

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STATE_DIR="/var/lib/hydrix-vpn"
ROUTING_TABLES=(
    "pentest:100"
    "office:101"
    "browse:102"
    "dev:103"
)

# Network interface mapping (router side)
declare -A NETWORK_INTERFACES=(
    ["pentest"]="enp2s0"
    ["office"]="enp3s0"
    ["browse"]="enp4s0"
    ["dev"]="enp5s0"
)

# Get WAN interface (detect WiFi or first ethernet)
get_wan_interface() {
    local wan
    wan=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -z "$wan" ]; then
        wan=$(ls /sys/class/net/ | grep -E '^(wl|en|eth)' | grep -v '^enp[2-5]' | head -1)
    fi
    echo "$wan"
}

# Get routing table ID for network
get_table_id() {
    local network="$1"
    for entry in "${ROUTING_TABLES[@]}"; do
        local name="${entry%%:*}"
        local id="${entry##*:}"
        if [ "$name" = "$network" ]; then
            echo "$id"
            return
        fi
    done
    echo ""
}

# Check if VPN interface exists
vpn_interface_exists() {
    local vpn_name="$1"
    ip link show "$vpn_name" &>/dev/null
}

# Get VPN interface for a VPN name
get_vpn_interface() {
    local vpn_name="$1"

    # Check for WireGuard interface
    if ip link show "$vpn_name" &>/dev/null; then
        echo "$vpn_name"
        return
    fi

    # Check for OpenVPN tun interface
    local tun_if="tun-${vpn_name}"
    if ip link show "$tun_if" &>/dev/null; then
        echo "$tun_if"
        return
    fi

    # Check for generic tun interfaces
    if ip link show tun0 &>/dev/null; then
        echo "tun0"
        return
    fi

    echo ""
}

# Update routing table for a network
update_routing() {
    local network="$1"
    local target="$2"
    local table_id
    table_id=$(get_table_id "$network")

    if [ -z "$table_id" ]; then
        echo -e "${RED}Error: Unknown network '$network'${NC}"
        return 1
    fi

    # Flush existing routes in table
    ip route flush table "$network" 2>/dev/null || true

    case "$target" in
        blocked)
            # No routes = all traffic dropped (kill switch)
            echo -e "${YELLOW}[$network]${NC} Traffic blocked (kill switch active)"
            ;;
        direct)
            # Route through WAN interface
            local wan
            wan=$(get_wan_interface)
            if [ -z "$wan" ]; then
                echo -e "${RED}Error: No WAN interface found${NC}"
                return 1
            fi
            local gw
            gw=$(ip route | grep "default.*$wan" | awk '{print $3}')
            if [ -n "$gw" ]; then
                ip route add default via "$gw" dev "$wan" table "$network"
            else
                ip route add default dev "$wan" table "$network"
            fi
            echo -e "${GREEN}[$network]${NC} Routing through WAN ($wan)"
            ;;
        *)
            # Route through VPN
            local vpn_if
            vpn_if=$(get_vpn_interface "$target")
            if [ -z "$vpn_if" ]; then
                echo -e "${RED}Error: VPN interface '$target' not found${NC}"
                echo -e "${YELLOW}Tip: Make sure the VPN is connected first${NC}"
                echo -e "     systemctl start wg-quick@$target"
                return 1
            fi

            # Get VPN gateway/endpoint
            local vpn_gw
            vpn_gw=$(ip route | grep "$vpn_if" | grep -v default | head -1 | awk '{print $1}')

            # Add default route through VPN
            ip route add default dev "$vpn_if" table "$network"
            echo -e "${GREEN}[$network]${NC} Routing through VPN ($vpn_if)"
            ;;
    esac

    # Save assignment state
    echo "$target" > "$STATE_DIR/${network}.assignment"
}

# Show current status
show_status() {
    echo -e "${BLUE}=== VPN Routing Status ===${NC}"
    echo ""

    local wan
    wan=$(get_wan_interface)
    echo -e "WAN Interface: ${GREEN}${wan:-none}${NC}"
    echo ""

    echo -e "${BLUE}Network Assignments:${NC}"
    for network in pentest office browse dev; do
        local assignment="blocked"
        if [ -f "$STATE_DIR/${network}.assignment" ]; then
            assignment=$(cat "$STATE_DIR/${network}.assignment")
        fi

        local status_color="$RED"
        local status_icon="✗"
        case "$assignment" in
            blocked)
                status_color="$RED"
                status_icon="✗"
                ;;
            direct)
                status_color="$GREEN"
                status_icon="→"
                ;;
            *)
                if vpn_interface_exists "$assignment" || vpn_interface_exists "tun-$assignment"; then
                    status_color="$GREEN"
                    status_icon="🔒"
                else
                    status_color="$YELLOW"
                    status_icon="⚠"
                    assignment="$assignment (disconnected)"
                fi
                ;;
        esac

        printf "  %-10s ${status_color}%s %s${NC}\n" "$network:" "$status_icon" "$assignment"
    done
    echo ""

    echo -e "${BLUE}Active VPN Tunnels:${NC}"
    local found_vpn=false
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wg-|tun)'); do
        found_vpn=true
        local ip_addr
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        echo -e "  ${GREEN}$iface${NC}: $ip_addr"
    done
    if [ "$found_vpn" = false ]; then
        echo -e "  ${YELLOW}No active VPN tunnels${NC}"
    fi
    echo ""

    echo -e "${BLUE}Routing Tables:${NC}"
    for network in pentest office browse dev; do
        local routes
        routes=$(ip route show table "$network" 2>/dev/null | head -1)
        if [ -n "$routes" ]; then
            echo -e "  $network: ${GREEN}$routes${NC}"
        else
            echo -e "  $network: ${RED}(empty - blocked)${NC}"
        fi
    done
}

# List available VPNs
list_vpns() {
    echo -e "${BLUE}Available VPN Configurations:${NC}"
    echo ""

    # WireGuard configs
    echo "WireGuard:"
    for conf in /etc/wireguard/*.conf; do
        if [ -f "$conf" ]; then
            local name
            name=$(basename "$conf" .conf)
            local active=""
            if ip link show "$name" &>/dev/null; then
                active="${GREEN}(active)${NC}"
            fi
            echo "  - $name $active"
        fi
    done

    # OpenVPN configs
    echo ""
    echo "OpenVPN:"
    for conf in /etc/openvpn/*.conf /etc/openvpn/client/*.conf; do
        if [ -f "$conf" ]; then
            local name
            name=$(basename "$conf" .conf)
            echo "  - $name"
        fi
    done
}

# Connect a VPN
connect_vpn() {
    local vpn_name="$1"

    # Try WireGuard first
    if [ -f "/etc/wireguard/${vpn_name}.conf" ]; then
        echo -e "${BLUE}Connecting WireGuard VPN: $vpn_name${NC}"
        wg-quick up "$vpn_name"
        return
    fi

    # Try OpenVPN
    if [ -f "/etc/openvpn/${vpn_name}.conf" ] || [ -f "/etc/openvpn/client/${vpn_name}.conf" ]; then
        echo -e "${BLUE}Connecting OpenVPN: $vpn_name${NC}"
        systemctl start "openvpn-${vpn_name}"
        return
    fi

    echo -e "${RED}Error: No VPN config found for '$vpn_name'${NC}"
    return 1
}

# Disconnect a VPN
disconnect_vpn() {
    local vpn_name="$1"

    # Try WireGuard
    if ip link show "$vpn_name" &>/dev/null; then
        echo -e "${BLUE}Disconnecting WireGuard VPN: $vpn_name${NC}"
        wg-quick down "$vpn_name"
        return
    fi

    # Try OpenVPN
    if systemctl is-active --quiet "openvpn-${vpn_name}"; then
        echo -e "${BLUE}Disconnecting OpenVPN: $vpn_name${NC}"
        systemctl stop "openvpn-${vpn_name}"
        return
    fi

    echo -e "${YELLOW}VPN '$vpn_name' is not connected${NC}"
}

# Print usage
usage() {
    cat << EOF
Usage: vpn-assign <command> [arguments]

Commands:
  <network> <target>   Assign network to VPN/direct/blocked
  status               Show current routing status
  list                 List available VPN configurations
  connect <vpn>        Connect a VPN tunnel
  disconnect <vpn>     Disconnect a VPN tunnel
  help                 Show this help

Networks: pentest, office, browse, dev

Targets:
  <vpn-name>   Route through specified VPN (e.g., mullvad, client-vpn)
  direct       Route directly through WAN (no VPN)
  blocked      Block all traffic (kill switch)

Examples:
  vpn-assign pentest client-vpn   # Route pentest → client VPN
  vpn-assign browse mullvad       # Route browsing → Mullvad
  vpn-assign office direct        # Direct WAN for office
  vpn-assign dev blocked          # Block dev traffic

  vpn-assign connect mullvad      # Connect Mullvad VPN
  vpn-assign status               # Show all assignments

EOF
}

# Main
main() {
    # Ensure state directory exists
    mkdir -p "$STATE_DIR"

    case "${1:-}" in
        status|"")
            show_status
            ;;
        list)
            list_vpns
            ;;
        connect)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: VPN name required${NC}"
                exit 1
            fi
            connect_vpn "$2"
            ;;
        disconnect)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: VPN name required${NC}"
                exit 1
            fi
            disconnect_vpn "$2"
            ;;
        help|--help|-h)
            usage
            ;;
        pentest|office|browse|dev)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: Target required (vpn-name, direct, or blocked)${NC}"
                exit 1
            fi
            update_routing "$1" "$2"
            ;;
        *)
            echo -e "${RED}Error: Unknown command '$1'${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
