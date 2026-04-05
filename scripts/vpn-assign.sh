#!/usr/bin/env bash
# VPN Assignment Script for Router VM
# Manages which VPN tunnel each network uses
#
# Usage:
#   vpn-assign <network> <vpn-name|direct|blocked>
#   vpn-assign pentest client-vpn    # Route pentest traffic through client-vpn
#   vpn-assign browse mullvad-ch     # Route browsing through Mullvad Switzerland
#   vpn-assign comms mullvad-se      # Route comms through Mullvad Sweden
#   vpn-assign comms direct          # Direct WAN access for comms
#   vpn-assign dev blocked           # Kill switch only, no traffic allowed
#   vpn-assign --persistent browse mullvad-ch  # Save assignment across reboots
#
# Mullvad commands:
#   vpn-assign list-mullvad          # List available Mullvad exit nodes
#   vpn-assign connect mullvad-ch    # Connect to Mullvad Switzerland
#
# This script runs on the Router VM

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
STATE_DIR="/var/lib/hydrix-vpn"
PERSISTENT_FILE="$STATE_DIR/persistent.conf"
ROUTING_TABLES=(
    "pentest:100"
    "comms:101"
    "lurking:104"
    "browse:102"
    "dev:103"
)

# Network interface mapping (router side)
declare -A NETWORK_INTERFACES=(
    ["pentest"]="enp2s0"
    ["comms"]="enp3s0"
    ["lurking"]="enp7s0"
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
    for network in pentest comms browse dev lurking; do
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
    for network in pentest comms browse dev lurking; do
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

    # Mullvad configs (special category)
    local has_mullvad=false
    for conf in /etc/wireguard/mullvad-*.conf; do
        if [ -f "$conf" ]; then
            has_mullvad=true
            break
        fi
    done

    if [ "$has_mullvad" = true ]; then
        echo -e "${CYAN}Mullvad Exit Nodes:${NC}"
        for conf in /etc/wireguard/mullvad-*.conf; do
            if [ -f "$conf" ]; then
                local name
                name=$(basename "$conf" .conf)
                local active=""
                if ip link show "$name" &>/dev/null; then
                    active="${GREEN}(active)${NC}"
                fi
                local country=""
                case "${name#mullvad-}" in
                    ch) country="Switzerland" ;;
                    se) country="Sweden" ;;
                    de) country="Germany" ;;
                    us) country="United States" ;;
                    *) country="" ;;
                esac
                echo -e "  - $name ${YELLOW}$country${NC} $active"
            fi
        done
        echo ""
    fi

    # Other WireGuard configs
    echo "WireGuard:"
    for conf in /etc/wireguard/*.conf; do
        if [ -f "$conf" ]; then
            local name
            name=$(basename "$conf" .conf)
            # Skip Mullvad configs (already listed)
            [[ "$name" == mullvad-* ]] && continue
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

# List Mullvad exit nodes specifically
list_mullvad() {
    echo -e "${CYAN}=== Mullvad Exit Nodes ===${NC}"
    echo ""

    local found=false
    for conf in /etc/wireguard/mullvad-*.conf; do
        if [ -f "$conf" ]; then
            found=true
            local name
            name=$(basename "$conf" .conf)
            local code="${name#mullvad-}"
            local active=""
            local ip=""

            if ip link show "$name" &>/dev/null; then
                active="${GREEN}[ACTIVE]${NC}"
                ip=$(ip -4 addr show "$name" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
            fi

            local country=""
            case "$code" in
                ch) country="Switzerland (Zurich)" ;;
                se) country="Sweden (Stockholm)" ;;
                de) country="Germany (Frankfurt)" ;;
                us) country="United States (New York)" ;;
                *) country="Unknown" ;;
            esac

            printf "  %-12s ${YELLOW}%-30s${NC} %s %s\n" "$name" "$country" "$active" "$ip"
        fi
    done

    if [ "$found" = false ]; then
        echo -e "${YELLOW}No Mullvad configs found.${NC}"
        echo "Copy vpn/mullvad.nix.example to vpn/mullvad.nix and rebuild."
    fi

    echo ""
    echo -e "${BLUE}Usage:${NC}"
    echo "  vpn-assign connect mullvad-ch     # Connect to Switzerland"
    echo "  vpn-assign browse mullvad-ch      # Route browsing through Switzerland"
    echo "  vpn-assign --persistent browse mullvad-ch  # Save across reboots"
}

# Save assignment to persistent config
save_persistent() {
    local network="$1"
    local target="$2"

    # Ensure persistent file exists
    if [ ! -f "$PERSISTENT_FILE" ]; then
        cat > "$PERSISTENT_FILE" << 'EOF'
# Hydrix VPN Persistent Assignments
# Format: network=target
pentest=direct
comms=direct
lurking=direct
browse=direct
dev=direct
EOF
    fi

    # Update or add the assignment
    if grep -q "^${network}=" "$PERSISTENT_FILE"; then
        sed -i "s/^${network}=.*/${network}=${target}/" "$PERSISTENT_FILE"
    else
        echo "${network}=${target}" >> "$PERSISTENT_FILE"
    fi

    echo -e "${GREEN}Saved to persistent config: $network → $target${NC}"
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
  <network> <target>        Assign network to VPN/direct/blocked
  --persistent <net> <tgt>  Assign and save across reboots
  status                    Show current routing status
  list                      List available VPN configurations
  list-mullvad              List Mullvad exit nodes
  connect <vpn>             Connect a VPN tunnel
  disconnect <vpn>          Disconnect a VPN tunnel
  help                      Show this help

Networks: pentest, comms, browse, dev, lurking

Targets:
  mullvad-ch   Route through Mullvad Switzerland
  mullvad-se   Route through Mullvad Sweden
  mullvad-de   Route through Mullvad Germany
  mullvad-us   Route through Mullvad United States
  <vpn-name>   Route through specified VPN (e.g., client-vpn)
  direct       Route directly through WAN (no VPN)
  blocked      Block all traffic (kill switch)

Examples:
  vpn-assign browse mullvad-ch              # Route browsing → Switzerland
  vpn-assign comms mullvad-se               # Route comms → Sweden
  vpn-assign --persistent browse mullvad-ch # Save across reboots
  vpn-assign pentest direct                 # Direct WAN for pentest
  vpn-assign dev blocked                    # Block dev traffic

  vpn-assign list-mullvad                   # Show Mullvad exit nodes
  vpn-assign connect mullvad-ch             # Connect Switzerland tunnel
  vpn-assign status                         # Show all assignments

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
        list-mullvad)
            list_mullvad
            ;;
        --persistent|-p)
            # Persistent assignment: vpn-assign --persistent browse mullvad-ch
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                echo -e "${RED}Error: Usage: vpn-assign --persistent <network> <target>${NC}"
                exit 1
            fi
            local network="$2"
            local target="$3"
            if [[ ! "$network" =~ ^(pentest|comms|browse|dev|lurking)$ ]]; then
                echo -e "${RED}Error: Unknown network '$network'${NC}"
                exit 1
            fi
            update_routing "$network" "$target"
            save_persistent "$network" "$target"
            echo -e "${YELLOW}Note: Run 'systemctl restart dnsmasq' to update DNS settings${NC}"
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
        pentest|comms|browse|dev|lurking)
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
