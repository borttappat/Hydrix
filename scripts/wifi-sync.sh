#!/usr/bin/env bash
# wifi-sync - Sync WiFi credentials from Router VM to ~/hydrix-config
#
# Queries router VM via vsock for WiFi networks, compares with local config,
# and provides commands to pull credentials into shared/wifi.nix
#
# Usage:
#   wifi-sync poll                              # Query router, show differences
#   wifi-sync pull                              # Pull credentials, update wifi.nix
#   wifi-sync status                            # Quick status check
#

set -euo pipefail

# Auto-detect flake location
if [[ -n "${HYDRIX_FLAKE_DIR:-}" && -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
  PROJECT_DIR="$HYDRIX_FLAKE_DIR"
elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
  PROJECT_DIR="$HOME/hydrix-config"
elif [[ -f "$HOME/Hydrix/flake.nix" ]]; then
  PROJECT_DIR="$HOME/Hydrix"
else
  echo "Error: No Hydrix config found" >&2
  exit 1
fi

readonly WIFI_NIX="$PROJECT_DIR/shared/wifi.nix"
readonly ROUTER_CID=200
readonly ROUTER_PORT=14506

# Colors
readonly RED=$'\e[31m'
readonly GREEN=$'\e[32m'
readonly YELLOW=$'\e[33m'
readonly CYAN=$'\e[36m'
readonly MAGENTA=$'\e[35m'
readonly NC=$'\e[0m'
readonly BOLD=$'\e[1m'

log() { echo -e "$*"; }
error() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}$*${NC}"; }

# Query router VM via vsock
query_router() {
  echo "POLL" | socat -t5 - "VSOCK-CONNECT:${ROUTER_CID}:${ROUTER_PORT}" 2>/dev/null || echo ""
}

# Get local SSID from wifi.nix
get_local_ssid() {
  if [[ -f "$WIFI_NIX" ]]; then
    grep -oP 'ssid\s*=\s*"\K[^"]+' "$WIFI_NIX" 2>/dev/null | head -1 || echo ""
  else
    echo ""
  fi
}

# Get local password from wifi.nix
get_local_password() {
  if [[ -f "$WIFI_NIX" ]]; then
    grep -oP 'password\s*=\s*"\K[^"]+' "$WIFI_NIX" 2>/dev/null | head -1 || echo ""
  else
    echo ""
  fi
}

case "${1:-}" in
  poll)
    log "${BOLD}Querying router VM...${NC}"
    router_json=$(query_router)

    if [[ -z "$router_json" ]]; then
      error "Router unreachable (is microvm-router running?)"
    fi

    # Parse and display router networks
    router_count=$(echo "$router_json" | jq -r '.networks | length' 2>/dev/null || echo "0")

    log ""
    log "${CYAN}Router networks:${NC}"
    if [[ "$router_count" -gt 0 ]]; then
      echo "$router_json" | jq -r '.networks[] | "  SSID: \(.ssid)"' 2>/dev/null
      echo "$router_json" | jq -r '.networks[] | "  Password: \(.password)"' 2>/dev/null
    else
      log "  (no networks configured)"
    fi

    # Compare with local config
    local_ssid=$(get_local_ssid)
    log ""
    log "${CYAN}Local config: $WIFI_NIX${NC}"
    log "  Current SSID: ${local_ssid:-'(none)'}"

    if [[ "$router_count" -gt 0 ]]; then
      router_ssid=$(echo "$router_json" | jq -r '.networks[0].ssid // ""' 2>/dev/null)
      if [[ "$router_ssid" != "$local_ssid" ]]; then
        log ""
        log "${YELLOW}⚠️  Mismatch detected - run 'wifi-sync pull' to update${NC}"
      else
        log ""
        log "${GREEN}✓ In sync${NC}"
      fi
    fi
    ;;

  pull)
    log "${BOLD}Pulling WiFi credentials from router...${NC}"
    router_json=$(query_router)

    if [[ -z "$router_json" ]]; then
      error "Router unreachable (is microvm-router running?)"
    fi

    ssid=$(echo "$router_json" | jq -r '.networks[0].ssid // empty' 2>/dev/null)
    password=$(echo "$router_json" | jq -r '.networks[0].password // empty' 2>/dev/null)

    if [[ -z "$ssid" || -z "$password" ]]; then
      error "No WiFi credentials found on router"
    fi

    # Update wifi.nix
    if [[ ! -f "$WIFI_NIX" ]]; then
      error "wifi.nix not found at $WIFI_NIX"
    fi

    # Use sed to update the file
    sed -i "s/ssid = \"[^\"]*\"/ssid = \"$ssid\"/" "$WIFI_NIX"
    sed -i "s/password = \"[^\"]*\"/password = \"$password\"/" "$WIFI_NIX"

    success "Updated $WIFI_NIX:"
    log "  SSID: $ssid"
    log "  Password: $password"
    log ""
    log "Next steps:"
    log "  git add shared/wifi.nix"
    log "  git commit -m 'feat(wifi): update credentials'"
    log "  rebuild"
    ;;

  status)
    router_json=$(query_router)
    if [[ -n "$router_json" ]]; then
      count=$(echo "$router_json" | jq -r '.networks | length' 2>/dev/null || echo "0")
      log "Router: $count network(s) configured"

      local_ssid=$(get_local_ssid)
      if [[ -n "$local_ssid" ]]; then
        log "Local: $local_ssid"

        if [[ "$count" -gt 0 ]]; then
          router_ssid=$(echo "$router_json" | jq -r '.networks[0].ssid // ""' 2>/dev/null)
          if [[ "$router_ssid" != "$local_ssid" ]]; then
            log "${YELLOW}Status: OUT OF SYNC${NC}"
          else
            log "${GREEN}Status: In sync${NC}"
          fi
        fi
      fi
    else
      error "Router unreachable (is microvm-router running?)"
    fi
    ;;

  *)
    echo "Usage: wifi-sync {poll|pull|status}"
    echo ""
    echo "Commands:"
    echo "  poll   - Query router, show differences from local config"
    echo "  pull   - Pull credentials from router, update wifi.nix"
    echo "  status - Quick status check"
    ;;
esac
