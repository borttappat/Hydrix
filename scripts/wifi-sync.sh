#!/usr/bin/env bash
# wifi-sync - Manage known WiFi networks in secrets/wifi.yaml (sops)
#
# Admin mode (router VM reachable via vsock):
#   wifi-sync              Show status: current SSID, known list, router connections
#   wifi-sync add SSID PW  Push network to router NM + save to wifi.yaml
#   wifi-sync pull         Merge all router NM connections into wifi.yaml
#   wifi-sync list         Show known networks in wifi.yaml
#   wifi-sync remove SSID  Remove a network from wifi.yaml and from the router
#
# Fallback mode (direct WiFi on host, router VM not running):
#   wifi-sync              Auto-detect current connection via nmcli, save to wifi.yaml
#
# The first save creates secrets/wifi.yaml, encrypted for the recipients in
# secrets/.sops.yaml. The router receives it through hydrix.secrets.wifiSecretsFile.

set -euo pipefail

# HYDRIX_FLAKE_DIR is set by the mkHydrixScript wrapper; fall back for direct invocation.
if [[ -n "${HYDRIX_FLAKE_DIR:-}" && -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
  CONFIG_DIR="$HYDRIX_FLAKE_DIR"
elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
  CONFIG_DIR="$HOME/hydrix-config"
else
  echo "Error: hydrix-config not found" >&2; exit 1
fi

WIFI_YAML="$CONFIG_DIR/secrets/wifi.yaml"
SOPS_CONFIG="$CONFIG_DIR/secrets/.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
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

r_remove() {
  printf 'REMOVE\n%s\n' "$1" | timeout 10 \
    socat -t10 - "VSOCK-CONNECT:${ROUTER_CID}:${ROUTER_PORT}" 2>/dev/null
}

# Router connections not yet saved locally, as a jq array. Profiles that never
# connected (failed attempts NetworkManager kept) are left out; the router
# reports "connected" per profile, and a missing field counts as connected.
poll_pending() {
  local conns="$1" local_nets="$2"
  echo "$conns" | jq --argjson l "$local_nets" \
    '[.[] | select(.connected != false) | select(.ssid as $s | $l | all(.[]; .ssid != $s))]'
}

# Known networks -> JSON [{ssid,psk,priority}], from secrets/wifi.yaml.
read_nix() {
  [[ -f "$WIFI_YAML" ]] || { echo "[]"; return; }
  local raw
  raw=$(sops --decrypt --extract '["networks"]' "$WIFI_YAML" 2>/dev/null || echo "[]")
  echo "$raw" | jq '[.[] | . + {"priority": (.priority // 100)}]' 2>/dev/null || echo "[]"
}

# Write the JSON array back to secrets/wifi.yaml. sops --set updates the one
# key in place; the networks array is stored as a JSON string. A missing file
# is created and encrypted for the recipients in secrets/.sops.yaml.
write_nix() {
  local json="$1" json_str err
  json_str=$(python3 -c "import sys, json; print(json.dumps(sys.argv[1]))" "$json")
  err=$(mktemp)
  if [[ ! -f "$WIFI_YAML" ]]; then
    [[ -f "$SOPS_CONFIG" ]] || error "No $SOPS_CONFIG. Set up sops first (hydrix-sops-setup)."
    if ! printf 'networks: %s\n' "$json_str" \
      | sops --config "$SOPS_CONFIG" --encrypt --filename-override "$WIFI_YAML" \
          --input-type yaml --output-type yaml /dev/stdin > "$WIFI_YAML.tmp" 2>"$err"; then
      rm -f "$WIFI_YAML.tmp"
      error "Failed to create $WIFI_YAML: $(cat "$err")"
    fi
    mv "$WIFI_YAML.tmp" "$WIFI_YAML"
    rm -f "$err"
    success "Created $WIFI_YAML"
    log "Wire it up in your machine config if it is not yet:"
    log "  hydrix.secrets.enable = true;"
    log "  hydrix.secrets.wifiSecretsFile = ../secrets/wifi.yaml;"
    log "  router VM entry in hydrix.microvmHost.vms: secrets = [ \"wifi\" ];"
    log "Then git add secrets/wifi.yaml, rebuild, and shard -bR router."
    return
  fi
  if ! sops --set '["networks"] '"$json_str" "$WIFI_YAML" 2>"$err"; then
    error "Failed to write to $WIFI_YAML: $(cat "$err")"
  fi
  rm -f "$err"
  success "Updated $WIFI_YAML"
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
          || warn "Connected: $current - NOT in wifi.yaml. Run: wifi-sync pull"
      else
        log "Connected: (none)"
      fi
      log ""
      log "${CYAN}Known networks in wifi.yaml ($local_count):${NC}"
      echo "$local_nets" | jq -r 'sort_by(-.priority)[] | "  \(.ssid)  [priority \(.priority)]"'
      log ""
      log "${CYAN}All connections on router ($router_count):${NC}"
      echo "$connections" | jq -r '.[].ssid | "  \(.)"' 2>/dev/null
      if [[ "$pending_count" -gt 0 ]]; then
        log ""
        warn "Not yet in wifi.yaml ($pending_count) - run: wifi-sync pull"
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
      merged=$(merge_one "$local_nets" "$ssid" "$psk")
      write_nix "$merged"
      log "The router gets it on its next start after ${BOLD}rebuild${NC}."
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
    local_nets=$(read_nix)
    merged=$(merge_one "$local_nets" "$ssid" "$psk")
    write_nix "$merged"
    ;;

  pull)
    is_admin || error "Router not reachable. Use 'wifi-sync' in fallback mode."
    log "Pulling pending networks from router..."
    poll=$(r_poll)
    local_nets=$(read_nix)
    pending=$(poll_pending "$(echo "$poll" | jq '.connections // []')" "$local_nets")
    count=$(echo "$pending" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] || { log "No pending networks on router - all already in $WIFI_YAML."; exit 0; }
    merged="$local_nets"; added=0; updated=0
    i=0
    while [[ $i -lt $count ]]; do
      ssid=$(echo "$pending" | jq -r ".[$i].ssid")
      psk=$(echo "$pending"  | jq -r ".[$i].psk // \"\"")
      exists=$(echo "$merged" | jq --arg s "$ssid" 'any(.[]; .ssid == $s)')
      [[ "$exists" == "true" ]] && updated=$((updated + 1)) || added=$((added + 1))
      merged=$(merge_one "$merged" "$ssid" "$psk")
      i=$((i + 1))
    done
    write_nix "$merged"
    log "+$added new, $updated updated."
    ;;

  list)
    local_nets=$(read_nix)
    count=$(echo "$local_nets" | jq 'length')
    log "${CYAN}Known WiFi networks ($count) [from secrets/wifi.yaml]:${NC}"
    echo "$local_nets" | jq -r 'sort_by(-.priority)[] | "  \(.ssid)  [priority \(.priority)]"'
    ;;

  remove)
    [[ $# -ge 2 ]] || error "Usage: wifi-sync remove SSID"
    target="$2"
    # Removes from the credential store when saved there, and from the router
    # either way: a router-only profile (e.g. left by a failed connection
    # attempt) has no store entry.
    removed=0
    local_nets=$(read_nix)
    exists=$(echo "$local_nets" | jq --arg s "$target" 'any(.[]; .ssid == $s)')
    if [[ "$exists" == "true" ]]; then
      updated=$(echo "$local_nets" | jq --arg s "$target" '[.[] | select(.ssid != $s)]')
      write_nix "$updated"
      success "Removed '$target' from credential store"
      removed=1
    else
      log "'$target' is not in the credential store"
    fi
    if is_admin; then
      result=$(r_remove "$target")
      ok=$(echo "$result" | jq -r '.ok' 2>/dev/null)
      if [[ "$ok" == "true" ]]; then
        success "Removed '$target' from router NM"
        removed=1
      else
        warn "Router: $(echo "$result" | jq -r '.error // "not found (already gone?)"' 2>/dev/null)"
      fi
    else
      warn "Router not reachable - delete manually: nmcli con delete \"$target\""
    fi
    [[ "$removed" == 1 ]] || error "'$target' not found in the credential store or on the router"
    ;;

  count)
    # Optional $2: router status JSON the caller already holds (POLL output,
    # or ALL output with it under .wifi), which saves two router round trips.
    # Known SSIDs are cached in $XDG_RUNTIME_DIR keyed on the source file's
    # mtime, so the sops decrypt only reruns after that file changes. Only
    # SSIDs are cached, never PSKs.
    if [[ -n "${2:-}" ]]; then
      poll="$2"
    else
      if ! is_admin; then echo 0; exit 0; fi
      poll=$(r_poll)
    fi
    connections=$(jq -c '(.wifi // .) | .connections // []' <<< "$poll" 2>/dev/null) || connections='[]'
    src="$WIFI_YAML"
    cache="${XDG_RUNTIME_DIR:-/tmp}/hydrix-wifi-known-ssids"
    stamp="$(stat -c '%Y' "$src" 2>/dev/null || echo none) $src"
    if [[ ! -f "$cache" ]] || [[ "$(head -n1 "$cache")" != "$stamp" ]]; then
      ( umask 077
        { echo "$stamp"; read_nix | jq -r '.[].ssid'; } > "$cache.tmp" && mv "$cache.tmp" "$cache" )
    fi
    jq -rn --argjson c "$connections" --rawfile k "$cache" '
      ($k | split("\n") | .[1:] | map(select(. != ""))) as $known
      | [$c[] | select(.connected != false) | select(.ssid as $s | $known | any(.[]; . == $s) | not)] | length'
    ;;

  *)
    cat <<'USAGE'
Usage: wifi-sync [command] [args]

  (none)            Admin: show status.  Fallback: capture current connection.
  add SSID PASS     Push to router NM + save credentials (admin mode)
  pull              Merge all router NM connections into credential store (admin mode)
  list              Show known networks in secrets/wifi.yaml
  remove SSID       Remove a network from credential store
  count [JSON]      Print number of unsaved router connections (for scripts/widgets);
                    JSON: router POLL/ALL output the caller already has

Credentials live in secrets/wifi.yaml (sops). The first save creates it.
An old modules/wifi.nix network list migrates with: setup-wifi-secrets
USAGE
    ;;
esac
