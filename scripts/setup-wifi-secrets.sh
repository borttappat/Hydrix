#!/usr/bin/env bash
# setup-wifi-secrets — Migrate WiFi credentials from modules/wifi.nix into sops
#
# Creates secrets/wifi.yaml (sops-encrypted) from the current modules/wifi.nix,
# then guides you through the rest of the migration.
#
# Prereqs: hydrix.secrets.enable = true, rebuild done (age key exists),
#          sops CLI available, .sops.yaml configured with your age key as recipient.
#
# Usage: setup-wifi-secrets
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
SECRETS_DIR="$CONFIG_DIR/secrets"
OUT="$SECRETS_DIR/wifi.yaml"

if [[ -f "$OUT" ]]; then
  echo "Error: $OUT already exists. Remove it first if you want to regenerate." >&2
  exit 1
fi

if [[ ! -f "$WIFI_NIX" ]]; then
  echo "Error: $WIFI_NIX not found." >&2
  exit 1
fi

# Extract networks from modules/wifi.nix using Python
NETWORKS=$(python3 - "$WIFI_NIX" <<'PY'
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
    print(json.dumps(entries))
    sys.exit(0)
# Legacy single-network format
s = re.search(r'ssid\s*=\s*"([^"]*)"', content)
p = re.search(r'(?:password|psk)\s*=\s*"([^"]*)"', content)
if s and p:
    print(json.dumps([{"ssid": s.group(1), "psk": p.group(1), "priority": 100}]))
else:
    print("[]")
PY
)

COUNT=$(echo "$NETWORKS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [[ "$COUNT" -eq 0 ]]; then
  echo "No WiFi networks found in $WIFI_NIX — nothing to migrate." >&2
  exit 1
fi

echo "Found $COUNT network(s) in modules/wifi.nix"
echo "$NETWORKS" | python3 -c "
import json, sys
for n in json.load(sys.stdin):
    print(f\"  {n['ssid']} (priority {n.get('priority', 100)})\")
"

# Build YAML with networks as a JSON string value (sops encrypts per key)
# json.dumps of the JSON array gives a JSON string literal valid as YAML double-quoted value
TMPFILE="$SECRETS_DIR/.wifi-setup-$$.yaml"
trap 'rm -f "$TMPFILE"' EXIT

python3 -c "
import sys, json
networks = sys.argv[1]
# json.dumps produces a JSON string literal, which is also a valid YAML double-quoted string
print('networks: ' + json.dumps(networks))
" "$NETWORKS" > "$TMPFILE"

echo "Encrypting with sops..."
sops --config "$SECRETS_DIR/.sops.yaml" --encrypt "$TMPFILE" > "$OUT"

echo ""
echo "Created: $OUT"
echo ""
echo "Next steps:"
echo "  1. git -C $CONFIG_DIR add secrets/wifi.yaml"
echo "     git -C $CONFIG_DIR commit -m 'feat(secrets): add encrypted wifi credentials'"
echo ""
echo "  2. In your machine config, add:"
echo "       hydrix.secrets.wifiSecretsFile = ../secrets/wifi.yaml;"
echo "       hydrix.microvmHost.vms.\"microvm-router\".secrets = [ \"wifi\" ];"
echo ""
echo "  3. Empty the networks list in modules/wifi.nix:"
echo "       hydrix.router.wifi.networks = lib.mkDefault [];"
echo ""
echo "  4. rebuild"
echo "  5. microvm purge microvm-router --force && mvm rebuild router"
echo "  6. wifi-sync   # verify"
