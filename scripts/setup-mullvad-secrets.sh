#!/usr/bin/env bash
# setup-mullvad-secrets - Move Mullvad WireGuard confs from the Nix store into sops
#
# hydrix.router.vpn.mullvad.bridges used to map each network to a conf file,
# which put every WireGuard PrivateKey into /nix/store, readable by every VM
# that shares the host store. This one-time migration reads that map from
# vpn/mullvad.nix and writes secrets/mullvad.yaml (sops-encrypted), one key per
# network with the conf text as its value. A "# Server: <file name>" line is
# added to each conf that lacks one, as the old processConfig did, so the
# exit-nodes widget keeps its labels.
#
# Prereqs: master key unlocked (hydrix-sops-setup --unlock), secrets/.sops.yaml.
#
# Usage: setup-mullvad-secrets [path/to/mullvad.nix]
set -euo pipefail

# HYDRIX_FLAKE_DIR is set by the mkHydrixScript wrapper; fall back for direct invocation.
if [[ -n "${HYDRIX_FLAKE_DIR:-}" && -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
  CONFIG_DIR="$HYDRIX_FLAKE_DIR"
elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
  CONFIG_DIR="$HOME/hydrix-config"
else
  echo "Error: hydrix-config not found" >&2; exit 1
fi

MULLVAD_NIX=$(realpath "${1:-$CONFIG_DIR/vpn/mullvad.nix}")
SECRETS_DIR="$CONFIG_DIR/secrets"
OUT="$SECRETS_DIR/mullvad.yaml"

if [[ -f "$OUT" ]]; then
  echo "Error: $OUT already exists. Edit it with: sops $OUT" >&2
  exit 1
fi
if [[ ! -f "$MULLVAD_NIX" ]]; then
  echo "Error: $MULLVAD_NIX not found." >&2
  exit 1
fi
if [[ ! -f "$SECRETS_DIR/.sops.yaml" ]]; then
  echo "Error: $SECRETS_DIR/.sops.yaml not found (run hydrix-sops-setup first)." >&2
  exit 1
fi

# network -> absolute conf path. toString keeps the paths on disk instead of
# copying them into the store again.
MAP=$(nix eval --impure --json --expr "
  let
    m = import $MULLVAD_NIX;
    v = if builtins.isFunction m then m {} else m;
    b = v.bridges or {};
  in builtins.mapAttrs (n: f:
    if builtins.isAttrs f
    then throw \"bridges.\${n} lists several confs; keep one per network and run again\"
    else toString f) b
")

COUNT=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$MAP")
if [[ "$COUNT" -eq 0 ]]; then
  echo "No bridges found in $MULLVAD_NIX, nothing to migrate." >&2
  exit 1
fi

umask 077
TMPFILE="$SECRETS_DIR/.mullvad-setup-$$.yaml"
trap 'rm -f "$TMPFILE"' EXIT

python3 - "$MAP" > "$TMPFILE" <<'PY'
import json, os, sys
for net, path in sorted(json.loads(sys.argv[1]).items()):
    text = open(path).read()
    if "PrivateKey" not in text:
        sys.exit(f"Error: {path} has no PrivateKey, not a WireGuard conf")
    if not any(l.startswith("# Server: ") for l in text.splitlines()):
        server = os.path.basename(path).removesuffix(".conf")
        text = f"# Server: {server}\n" + text
    if not text.endswith("\n"):
        text += "\n"
    # A JSON string literal is a valid YAML double-quoted scalar.
    print(f"{json.dumps(net)}: {json.dumps(text)}")
    print(f"  {net}: {path}", file=sys.stderr)
PY

echo "Encrypting with sops..."
sops --config "$SECRETS_DIR/.sops.yaml" --encrypt --input-type yaml --output-type yaml "$TMPFILE" > "$OUT"

NETS=$(python3 -c 'import json,sys; print(" ".join(f"\"{n}\"" for n in sorted(json.loads(sys.argv[1]))))' "$MAP")

echo ""
echo "Created: $OUT ($COUNT network(s))"
echo ""
echo "Next steps:"
echo "  1. In $MULLVAD_NIX replace bridges = { ... }; with:"
echo "       networks = [ $NETS ];"
echo "  2. Replace processConfig (a Nix function) with processScript, a shell filter"
echo "     (conf on stdin, result on stdout), e.g. in infra/router/default.nix:"
echo "       hydrix.router.vpn.mullvad.processScript = ''"
echo "         sed -e '/^\\[Interface\\]/a Table = off' -e '/^Address/s/,.*\$//' -e '/^DNS/d'"
echo "       '';"
echo "  3. In your machine config:"
echo "       hydrix.secrets.mullvadSecretsFile = ../secrets/mullvad.yaml;"
echo "       and add \"mullvad\" to the router's secrets (byName.router.secrets)"
echo "  4. git -C $CONFIG_DIR add secrets/mullvad.yaml"
echo "  5. rebuild, then shard -bR router; check with: vpn-assign list-mullvad (in the router)"
echo "  6. Delete the plaintext confs, rotate the keys at mullvad.net (the old ones were"
echo "     readable from /nix/store), then garbage-collect the old store paths."
