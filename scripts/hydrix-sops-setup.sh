#!/usr/bin/env bash
# hydrix-sops-setup — Initialize sops for the current machine.
#
# Run this after the first rebuild on a new machine.
# Creates secrets/.sops.yaml with the machine's age public key so that
# 'sops secrets/myfile.yaml' works without any additional configuration.
#
# If secrets files already exist (e.g. from another machine's config),
# the script prints the command to re-key them for this machine.
#
# Usage:
#   hydrix-sops-setup               # create/check .sops.yaml
#   hydrix-sops-setup --print-key   # just print the host age public key and exit
#   hydrix-sops-setup --enroll-fido2  # enroll a FIDO2 key (Titan, Yubikey, etc.)
#
set -euo pipefail

CONFIG_DIR="${HYDRIX_FLAKE_DIR:-$HOME/hydrix-config}"
SECRETS_DIR="$CONFIG_DIR/secrets"
SOPS_YAML="$SECRETS_DIR/.sops.yaml"
SOPS_AGE_DIR="$HOME/.config/sops/age"
PLUGIN_IDS="$SOPS_AGE_DIR/plugin-identities.txt"
KEYS_FILE="$SOPS_AGE_DIR/keys.txt"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
NC=$'\e[0m'; BOLD=$'\e[1m'

# ── Derive host age public key ───────────────────────────────────────────────

AGE_KEY="/var/lib/sops-nix/age-key.txt"
SSH_PUB="/etc/ssh/ssh_host_ed25519_key.pub"

HOST_PUBKEY=""
if [[ -f "$AGE_KEY" ]]; then
  HOST_PUBKEY=$(age-keygen -y "$AGE_KEY" 2>/dev/null || true)
fi
if [[ -z "$HOST_PUBKEY" && -f "$SSH_PUB" ]]; then
  HOST_PUBKEY=$(ssh-to-age -i "$SSH_PUB" 2>/dev/null || true)
fi

# ── --print-key ──────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--print-key" ]]; then
  if [[ -z "$HOST_PUBKEY" ]]; then
    echo "Error: could not derive host age public key. Run 'rebuild' first." >&2
    exit 1
  fi
  echo "$HOST_PUBKEY"
  exit 0
fi

# ── --enroll-fido2 ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--enroll-fido2" ]]; then
  if ! command -v age-plugin-fido2-hmac &>/dev/null; then
    echo -e "${RED}Error: age-plugin-fido2-hmac not found.${NC}" >&2
    echo "Run 'rebuild' to install it, then try again." >&2
    exit 1
  fi

  echo -e "${CYAN}Enrolling FIDO2 key with age-plugin-fido2-hmac...${NC}"
  echo "You will be asked to touch your key once to generate the credential."
  echo ""

  mkdir -p "$SOPS_AGE_DIR"
  chmod 700 "$SOPS_AGE_DIR"

  # Generate identity (touch required).
  # The plugin mixes prompts and output on stdout, so we tee to both the
  # terminal (so the user can see prompts and respond) and a temp file (to
  # capture the final credential lines).
  TMPFILE=$(mktemp)
  trap 'rm -f "$TMPFILE"' EXIT
  # Capture stdout only; stderr flows to terminal for interactive prompts.
  age-plugin-fido2-hmac --generate > "$TMPFILE"
  echo ""

  # The identity credential line (required to use the key for decryption)
  IDENTITY=$(grep -E '^AGE-PLUGIN-FIDO2-HMAC-' "$TMPFILE" | tr -d '\r' || true)
  if [[ -z "$IDENTITY" ]]; then
    echo -e "${RED}Error: no identity produced (empty stdout).${NC}" >&2
    exit 1
  fi

  # Extract pubkey from stdout output
  FIDO2_PUBKEY=$(grep -oP '(?<=# public key: )age1\S+' "$TMPFILE" | tr -d '\r' | head -1 || true)
  if [[ -z "$FIDO2_PUBKEY" ]]; then
    echo -e "${RED}Error: could not parse recipient pubkey from stdout.${NC}" >&2
    echo "Raw stdout above -- paste the 'age1...' pubkey manually if visible." >&2
    echo -e "${CYAN}Enter recipient pubkey:${NC}"
    read -r FIDO2_PUBKEY
    FIDO2_PUBKEY="${FIDO2_PUBKEY// /}"
  fi
  if [[ -z "$FIDO2_PUBKEY" || "$FIDO2_PUBKEY" != age1* ]]; then
    echo -e "${RED}Error: no valid pubkey (expected 'age1...' prefix).${NC}" >&2
    exit 1
  fi

  # Check if this key is already enrolled
  if [[ -f "$PLUGIN_IDS" ]] && grep -qF "$FIDO2_PUBKEY" "$PLUGIN_IDS" 2>/dev/null; then
    echo -e "${YELLOW}This FIDO2 key is already enrolled.${NC}"
    echo "Recipient: $FIDO2_PUBKEY"
    exit 0
  fi

  # Save to plugin-identities.txt (persists across rebuilds).
  # Format: comment with pubkey so the file is self-documenting, then the identity.
  mkdir -p "$SOPS_AGE_DIR"
  chmod 700 "$SOPS_AGE_DIR"
  {
    echo ""
    echo "# FIDO2 identity enrolled $(date -I)"
    echo "# public key: $FIDO2_PUBKEY"
    echo "$IDENTITY"
  } >> "$PLUGIN_IDS"
  chmod 600 "$PLUGIN_IDS"

  # Also append to keys.txt immediately so sops can use it without a rebuild
  if [[ -f "$KEYS_FILE" ]]; then
    echo "" >> "$KEYS_FILE"
    echo "$IDENTITY" >> "$KEYS_FILE"
  fi

  echo -e "${GREEN}FIDO2 key enrolled.${NC}"
  echo -e "Recipient: ${BOLD}$FIDO2_PUBKEY${NC}"
  echo ""

  # Add recipient to .sops.yaml if it exists
  if [[ -f "$SOPS_YAML" ]]; then
    if grep -qF "$FIDO2_PUBKEY" "$SOPS_YAML"; then
      echo -e "${GREEN}Key already in $SOPS_YAML.${NC}"
    else
      # Insert after the last existing age recipient line, matching its indentation
      awk -v key="$FIDO2_PUBKEY" '
        /^[[:space:]]+-[[:space:]]+age1/ { last=NR; indent=$0; sub(/-.*/, "", indent) }
        { lines[NR]=$0 }
        END {
          for (i=1; i<=NR; i++) {
            print lines[i]
            if (i==last) print indent "- " key
          }
        }
      ' "$SOPS_YAML" > "$SOPS_YAML.tmp" && mv "$SOPS_YAML.tmp" "$SOPS_YAML"
      echo -e "${GREEN}Added to $SOPS_YAML.${NC}"

      # Re-encrypt existing secrets for the new recipient
      existing=$(find "$SECRETS_DIR" -name "*.yaml" ! -name ".sops.yaml" 2>/dev/null | head -5)
      if [[ -n "$existing" ]]; then
        echo ""
        echo "Re-encrypting existing secrets for the FIDO2 key..."
        echo "You will be asked to touch your key once for decryption."
        echo ""
        cd "$SECRETS_DIR"
        for f in *.yaml; do
          [[ "$f" == ".sops.yaml" ]] && continue
          sops updatekeys --yes "$f"
        done
        cd "$CONFIG_DIR"
        echo ""
        echo -e "${GREEN}Done. Commit the updated secrets:${NC}"
        echo "  git add secrets/.sops.yaml secrets/*.yaml && git commit -m 'feat(secrets): add FIDO2 key as recipient'"
      else
        echo ""
        echo -e "Commit the updated .sops.yaml:"
        echo "  git add -f $SOPS_YAML && git commit -m 'feat(secrets): add FIDO2 key as recipient'"
      fi
    fi
  else
    echo "No .sops.yaml yet. Run 'hydrix-sops-setup' first to initialize, then"
    echo "the FIDO2 key will be added automatically as a recipient."
  fi

  exit 0
fi

# ── Normal init / check mode ─────────────────────────────────────────────────

if [[ -z "$HOST_PUBKEY" ]]; then
  echo -e "${RED}Error: could not derive age public key.${NC}" >&2
  echo "Run 'rebuild' first to generate the SSH host key and age key." >&2
  exit 1
fi

echo -e "${CYAN}Host age public key:${NC} $HOST_PUBKEY"
echo ""

# ── Create secrets/ directory if needed ─────────────────────────────────────

mkdir -p "$SECRETS_DIR"

# ── Check / create .sops.yaml ────────────────────────────────────────────────

if [[ -f "$SOPS_YAML" ]]; then
  if grep -qF "$HOST_PUBKEY" "$SOPS_YAML"; then
    echo -e "${GREEN}$SOPS_YAML already contains this machine's key.${NC}"
  else
    echo -e "${YELLOW}Warning: $SOPS_YAML exists but does not contain this machine's key.${NC}"
    echo ""
    echo "Add the following line under the 'age:' list in $SOPS_YAML:"
    echo -e "  ${BOLD}- $HOST_PUBKEY${NC}"
    echo ""
    existing=$(find "$SECRETS_DIR" -name "*.yaml" ! -name ".sops.yaml" 2>/dev/null | head -5)
    if [[ -n "$existing" ]]; then
      echo "Then re-key existing secrets for this machine:"
      echo -e "  ${BOLD}cd $CONFIG_DIR && sops updatekeys secrets/*.yaml${NC}"
    fi
  fi
  exit 0
fi

# Create a new .sops.yaml covering all YAML files in secrets/
cat > "$SOPS_YAML" << EOF
creation_rules:
  - path_regex: .*\\.yaml\$
    age:
      - $HOST_PUBKEY
EOF

echo -e "${GREEN}Created $SOPS_YAML${NC}"
echo ""
echo "To also add a FIDO2 hardware key (Titan, Yubikey):"
echo -e "  ${BOLD}hydrix-sops-setup --enroll-fido2${NC}"
echo ""
echo "Next steps:"
echo -e "  Create a secret:  ${BOLD}sops $SECRETS_DIR/mysecret.yaml${NC}"
echo -e "  Commit the config:  ${BOLD}git add -f $SOPS_YAML && git commit${NC}"
echo ""

# Check for existing encrypted files that may need re-keying
existing=$(find "$SECRETS_DIR" -name "*.yaml" ! -name ".sops.yaml" 2>/dev/null | head -5)
if [[ -n "$existing" ]]; then
  echo -e "${YELLOW}Existing secrets found — re-key them for this machine:${NC}"
  echo -e "  ${BOLD}cd $CONFIG_DIR && sops updatekeys secrets/*.yaml${NC}"
fi
