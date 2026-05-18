#!/usr/bin/env bash
# Quick VPN status check for Router VM
#
# Usage:
#   vpn-status        # One-time status
#   vpn-status -w     # Watch mode (updates every 2s)
#   vpn-status -j     # JSON output

set -euo pipefail

case "${1:-}" in
    -w|--watch)
        watch -n 2 -c vpn-assign status
        ;;
    -j|--json)
        STATE_DIR="/var/lib/hydrix-vpn"
        NETWORK_MAP_FILE="/etc/hydrix-router/network-map"
        echo "{"
        echo "  \"networks\": {"
        first=true
        while IFS=: read -r name table_id subnet; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue
            if [ "$first" = false ]; then echo ","; fi
            first=false
            assignment="blocked"
            [ -f "$STATE_DIR/${name}.assignment" ] && assignment=$(cat "$STATE_DIR/${name}.assignment")
            printf "    \"%s\": \"%s\"" "$name" "$assignment"
        done < "$NETWORK_MAP_FILE"
        echo ""
        echo "  },"
        echo "  \"vpn_tunnels\": ["
        first=true
        for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(mullvad-|wg-|tun)' || true); do
            if [ "$first" = false ]; then echo ","; fi
            first=false
            printf "    \"%s\"" "$iface"
        done
        echo ""
        echo "  ]"
        echo "}"
        ;;
    *)
        vpn-assign status
        ;;
esac
