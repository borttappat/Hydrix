#!/usr/bin/env bash
# Quick VPN status check for Router VM
# Wrapper around vpn-assign status with watch support
#
# Usage:
#   vpn-status        # One-time status
#   vpn-status -w     # Watch mode (updates every 2s)
#   vpn-status -j     # JSON output

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

case "${1:-}" in
    -w|--watch)
        watch -n 2 -c "$SCRIPT_DIR/vpn-assign.sh status"
        ;;
    -j|--json)
        # JSON output for programmatic use
        STATE_DIR="/var/lib/hydrix-vpn"
        echo "{"
        echo "  \"networks\": {"
        first=true
        for network in pentest office browse dev; do
            if [ "$first" = false ]; then echo ","; fi
            first=false
            assignment="blocked"
            if [ -f "$STATE_DIR/${network}.assignment" ]; then
                assignment=$(cat "$STATE_DIR/${network}.assignment")
            fi
            printf "    \"%s\": \"%s\"" "$network" "$assignment"
        done
        echo ""
        echo "  },"
        echo "  \"vpn_tunnels\": ["
        first=true
        for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(wg-|tun)' || true); do
            if [ "$first" = false ]; then echo ","; fi
            first=false
            printf "    \"%s\"" "$iface"
        done
        echo ""
        echo "  ]"
        echo "}"
        ;;
    *)
        "$SCRIPT_DIR/vpn-assign.sh" status
        ;;
esac
