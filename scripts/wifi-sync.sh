#!/usr/bin/env bash
# wifi-sync — Manage known WiFi networks in modules/wifi.nix
#
# Admin mode (router VM reachable via vsock):
#   wifi-sync              Show status: current SSID, known list, router connections
#   wifi-sync add SSID PW  Push network to router NM + save to wifi.nix
#   wifi-sync pull         Merge all router NM connections into wifi.nix
#   wifi-sync list         Show known networks in wifi.nix
#   wifi-sync remove SSID  Remove a network from wifi.nix
#
# Fallback mode (direct WiFi on host, router VM not running):
#   wifi-sync              Auto-detect current connection via nmcli, save to wifi.nix

set -euo pipefail

# HYDRIX_FLAKE_DIR is set by the mkHydrixScript wrapper; fall back for direct invocation.
if [[ -n "${HYDRIX_FLAKE_DIR:-}" && -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
  CONFIG_DIR="$HYDRIX_FLAKE_DIR"
elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
  CONFIG_DIR="$HOME/hydrix-config"
else
  echo "Error: hydrix-config not found" >&2; exit 1
fi

WIFI_NIX="$CONFIG_DIR/modules/wifi.nix"
ROUTER_PORT=14506

VM_REGISTRY="/etc/hydrix/vm-registry.json"
ROUTER_CID=$(jq -r 'to_entries[] | select(.value.vmName == "microvm-router") | .value.cid' \
  "$VM_REGISTRY" 2>/dev/null | head -1)
ROUTER_CID="${ROUTER_CID:-200}"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
NC=$'\e[0m'; BOLD=$'\e[1m'
log()     { echo -e "$*"; }
error()   { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}$*${NC}"; }
warn()    { echo -e "${YELLOW}$*${NC}"; }

is_admin() {
  echo "POLL" | timeout 2 socat -t2 - "VSOCK-CONNECT:${ROUTER_CID}:${ROUTER_PORT}" \
    > /dev/null 2>&1
}

r_poll() {
  echo "POLL" | timeout 5 socat -t5 - "VSOCK-CONNECT:${ROUTER_CID}:${ROUTER_PORT}" 2>/dev/null
}

r_add() {
  printf 'ADD\n%s\n%s\n' "$1" "$2" | timeout 30 \
    socat -t30 - "VSOCK-CONNECT:${ROUTER_CID}:${ROUTER_PORT}" 2>/dev/null
}

# Split router connections against wifi.nix: returns jq array of those not in wifi.nix
poll_pending() {
  local conns="$1" local_nets="$2"
  echo "$conns" | jq --argjson l "$local_nets" \
    '[.[] | select(.ssid as $s | $l | all(.[]; .ssid != $s))]'
}

# Derive WPA PSK hash from SSID + plaintext password.
# Pass-through if already a 64-char hex hash.
hash_psk() {
  local ssid="$1" pass="$2"
  if [[ ${#pass} -eq 64 && "$pass" =~ ^[0-9a-f]+$ ]]; then
    echo "$pass"
    return
  fi
  wpa_passphrase "$ssid" "$pass" | grep -E '^\s+psk=' | grep -v '#' | sed 's/.*psk=//'
}

# Parse wifi.nix -> JSON [{ssid,psk,priority}] — handles both legacy and networks list format
read_nix() {
  [[ -f "$WIFI_NIX" ]] || { echo "[]"; return; }
  python3 - "$WIFI_NIX" <<'PY'
import sys, re, json
content = open(sys.argv[1]).read()
m = re.search(r'\.networks\s*=\s*\[(.*?)\]', content, re.DOTALL)
if m:
    entries = []
    for e in re.finditer(r'\{([^}]+)\}', m.group(1)):
        s  = re.search(r'ssid\s*=\s*"([^"]*)"', e.group(1))
        p  = re.search(r'(?:password|psk)\s*=\s*"([^"]*)"', e.group(1))
        pr = re.search(r'priority\s*=\s*(\d+)', e.group(1))
        if s and p:
            entries.append({"ssid": s.group(1), "psk": p.group(1),
                            "priority": int(pr.group(1)) if pr else 100})
    print(json.dumps(entries)); sys.exit(0)
# Legacy single-network format
s = re.search(r'ssid\s*=\s*"([^"]*)"', content)
p = re.search(r'(?:password|psk)\s*=\s*"([^"]*)"', content)
if s and p:
    print(json.dumps([{"ssid": s.group(1), "psk": p.group(1), "priority": 100}]))
else:
    print("[]")
PY
}

# Write JSON array back to wifi.nix (always networks list format)
write_nix() {
  local json="$1" count
  count=$(echo "$json" | jq 'length')
  {
    printf '# WiFi Configuration - Shared across all machines\n'
    printf '#\n'
    printf '# Run '"'"'wifi-sync add SSID PASSWORD'"'"' (admin mode) to add via router.\n'
    printf '# Run '"'"'wifi-sync'"'"' (fallback mode) to capture the current host connection.\n'
    printf '# Run '"'"'wifi-sync pull'"'"' to merge all router NM connections into this list.\n'
    printf '\n{ config, lib, pkgs, ... }:\n\n{\n'
    if [[ "$count" -eq 0 ]]; then
      printf '  hydrix.router.wifi.networks = [];\n'
    else
      printf '  hydrix.router.wifi.networks = [\n'
      local i=0
      while [[ $i -lt $count ]]; do
        local ssid psk pri
        ssid=$(echo "$json" | jq -r ".[$i].ssid")
        psk=$(echo "$json"  | jq -r ".[$i].psk")
        pri=$(echo "$json"  | jq -r ".[$i].priority // 100")
        printf '    { ssid = "%s"; password = "%s"; priority = %s; }\n' "$ssid" "$psk" "$pri"
        i=$((i + 1))
      done
      printf '  ];\n'
    fi
    printf '}\n'
  } > "$WIFI_NIX"
}

# Merge one network into JSON array (update psk if SSID exists, append if new)
merge_one() {
  local json="$1" ssid="$2" psk="$3"
  local exists
  exists=$(echo "$json" | jq --arg s "$ssid" 'any(.[]; .ssid == $s)')
  if [[ "$exists" == "true" ]]; then
    echo "$json" | jq --arg s "$ssid" --arg p "$psk" \
      'map(if .ssid == $s then .psk = $p else . end)'
  else
    local min_pri
    min_pri=$(echo "$json" | jq '([.[].priority] | min // 110) - 10')
    echo "$json" | jq --arg s "$ssid" --arg p "$psk" --argjson pri "$min_pri" \
      '. + [{"ssid":$s,"psk":$p,"priority":$pri}]'
  fi
}

CMD="${1:-auto}"
case "$CMD" in

  auto)
    if is_admin; then
      log "${BOLD}WiFi status (admin mode)${NC}"
      poll=$(r_poll)
      current=$(echo "$poll" | jq -r '.current // ""' 2>/dev/null)
      connections=$(echo "$poll" | jq '.connections // []' 2>/dev/null)
      local_nets=$(read_nix)
      local_count=$(echo "$local_nets" | jq 'length')
      pending=$(poll_pending "$connections" "$local_nets")
      pending_count=$(echo "$pending" | jq 'length')
      router_count=$(echo "$connections" | jq 'length' 2>/dev/null || echo 0)
      if [[ -n "$current" ]]; then
        known=$(echo "$local_nets" | jq --arg s "$current" 'any(.[]; .ssid == $s)')
        [[ "$known" == "true" ]] \
          && log "${GREEN}Connected: $current (known)${NC}" \
          || warn "Connected: $current — NOT in wifi.nix. Run: wifi-sync pull"
      else
        log "Connected: (none)"
      fi
      log ""
      log "${CYAN}Known networks in wifi.nix ($local_count):${NC}"
      echo "$local_nets" | jq -r 'sort_by(-.priority)[] | "  \(.ssid)  [priority \(.priority)]"'
      log ""
      log "${CYAN}All connections on router ($router_count):${NC}"
      echo "$connections" | jq -r '.[].ssid | "  \(.)"' 2>/dev/null
      if [[ "$pending_count" -gt 0 ]]; then
        log ""
        warn "Not yet in wifi.nix ($pending_count) — run: wifi-sync pull"
        echo "$pending" | jq -r '.[].ssid | "  \(.)"' 2>/dev/null
      fi
    else
      log "${BOLD}Capturing WiFi (fallback mode)${NC}"
      wifi_show=$(nmcli dev wifi show 2>/dev/null || true)
      ssid=""; psk=""
      if [[ -n "$wifi_show" ]]; then
        ssid=$(echo "$wifi_show" | grep -E "^SSID:"     | sed 's/^SSID:[[:space:]]*//' | head -1)
        psk=$(echo "$wifi_show"  | grep -E "^Password:" | sed 's/^Password:[[:space:]]*//' | head -1)
      fi
      [[ -z "$ssid" ]] && error "No WiFi detected. Are you connected in fallback mode?"
      [[ -z "$psk"  ]] && error "Connected to '$ssid' but password unreadable."
      local_nets=$(read_nix)
      hashed=$(hash_psk "$ssid" "$psk")
      merged=$(merge_one "$local_nets" "$ssid" "$hashed")
      write_nix "$merged"
      success "Saved '$ssid' to $WIFI_NIX"
      log "Run ${BOLD}rebuild${NC} to bake into router VM."
    fi
    ;;

  add)
    [[ $# -ge 3 ]] || error "Usage: wifi-sync add SSID PASSWORD"
    ssid="$2"; pass="$3"
    is_admin || error "Router not reachable. In fallback mode, just run: wifi-sync"
    log "Sending ADD to router: ${BOLD}$ssid${NC}"
    result=$(r_add "$ssid" "$pass")
    ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
    [[ "$ok" == "true" ]] || error "Router rejected: $(echo "$result" | jq -r '.error // "unknown"' 2>/dev/null)"
    connected=$(echo "$result" | jq -r '.connected // true' 2>/dev/null)
    [[ "$connected" == "true" ]] \
      && success "Router connected to '$ssid'" \
      || warn "Profile added; router did not connect (may be out of range)"
    poll=$(r_poll)
    psk=$(echo "$poll" | jq -r --arg s "$ssid" \
      '.connections[] | select(.ssid == $s) | .psk // ""' 2>/dev/null | head -1)
    [[ -z "$psk" ]] && psk="$pass"
    psk=$(hash_psk "$ssid" "$psk")
    local_nets=$(read_nix)
    merged=$(merge_one "$local_nets" "$ssid" "$psk")
    write_nix "$merged"
    success "Saved to $WIFI_NIX. Run ${BOLD}rebuild${NC} to make it permanent."
    ;;

  pull)
    is_admin || error "Router not reachable. Use 'wifi-sync' in fallback mode."
    log "Pulling pending networks from router..."
    poll=$(r_poll)
    local_nets=$(read_nix)
    pending=$(poll_pending "$(echo "$poll" | jq '.connections // []')" "$local_nets")
    count=$(echo "$pending" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] || { log "No pending networks on router — all already in wifi.nix."; exit 0; }
    merged="$local_nets"; added=0; updated=0
    i=0
    while [[ $i -lt $count ]]; do
      ssid=$(echo "$pending" | jq -r ".[$i].ssid")
      psk=$(echo "$pending"  | jq -r ".[$i].psk // \"\"")
      psk=$(hash_psk "$ssid" "$psk")
      exists=$(echo "$merged" | jq --arg s "$ssid" 'any(.[]; .ssid == $s)')
      [[ "$exists" == "true" ]] && updated=$((updated + 1)) || added=$((added + 1))
      merged=$(merge_one "$merged" "$ssid" "$psk")
      i=$((i + 1))
    done
    write_nix "$merged"
    success "Updated $WIFI_NIX: +$added new, $updated updated. Run ${BOLD}rebuild${NC} to apply."
    ;;

  list)
    local_nets=$(read_nix)
    count=$(echo "$local_nets" | jq 'length')
    log "${CYAN}Known WiFi networks ($count):${NC}"
    echo "$local_nets" | jq -r 'sort_by(-.priority)[] | "  \(.ssid)  [priority \(.priority)]"'
    ;;

  remove)
    [[ $# -ge 2 ]] || error "Usage: wifi-sync remove SSID"
    target="$2"
    local_nets=$(read_nix)
    exists=$(echo "$local_nets" | jq --arg s "$target" 'any(.[]; .ssid == $s)')
    [[ "$exists" == "true" ]] || error "'$target' not found in wifi.nix"
    updated=$(echo "$local_nets" | jq --arg s "$target" '[.[] | select(.ssid != $s)]')
    write_nix "$updated"
    success "Removed '$target'"
    ;;

  count)
    if ! is_admin; then echo 0; exit 0; fi
    poll=$(r_poll)
    connections=$(echo "$poll" | jq '.connections // []' 2>/dev/null)
    local_nets=$(read_nix)
    pending=$(poll_pending "$connections" "$local_nets")
    echo "$pending" | jq 'length'
    ;;

  *)
    cat <<'USAGE'
Usage: wifi-sync [command] [args]

  (none)            Admin: show status.  Fallback: capture current connection.
  add SSID PASS     Push to router NM + save to wifi.nix (admin mode)
  pull              Merge all router NM connections into wifi.nix (admin mode)
  list              Show known networks in wifi.nix
  remove SSID       Remove a network from wifi.nix
  count             Print number of unsaved router connections (for scripts/widgets)

After any change, run 'rebuild' to bake credentials into the router VM.
USAGE
    ;;
esac
