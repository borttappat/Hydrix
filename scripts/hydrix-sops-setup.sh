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
#   hydrix-sops-setup                  # create/check .sops.yaml
#   hydrix-sops-setup --print-key      # just print the host age public key and exit
#   hydrix-sops-setup --gen-key        # generate a personal age key usable across machines
#   hydrix-sops-setup --enroll-fido2   # enroll a FIDO2 key (Titan, Yubikey, etc.)
#   hydrix-sops-setup --gen-master-key # generate password-protected portable master key
#   hydrix-sops-setup --unlock         # decrypt master key and activate it on this machine
#
# Master key workflow (for multi-machine / reinstall use):
#   First machine:
#     hydrix-sops-setup --gen-master-key   # creates secrets/master-age-key.age
#     # Add printed public key to secrets/.sops.yaml, re-encrypt, commit
#     git add -f secrets/master-age-key.age secrets/.sops.yaml && git commit
#   New machine or reinstall (after cloning hydrix-config and first rebuild):
#     hydrix-sops-setup --unlock           # prompts for passphrase, activates key
#     # Secrets decrypt immediately without sops updatekeys
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

# ── --gen-key ────────────────────────────────────────────────────────────────
#
# Generates a personal age key not tied to any machine's SSH host key.
# The private key goes into plugin-identities.txt (persists across rebuilds).
# The public key is added to .sops.yaml so any machine holding the private
# key can decrypt secrets immediately -- no sops updatekeys required.
#
# Transfer the private key to new machines by copying plugin-identities.txt
# (or just the age key lines) before first rebuild. Keep a copy in your
# password manager or on an encrypted USB as a backup.
#
# When a Yubikey is later set up it replaces this key as the portable
# recipient -- at that point this key can be removed from .sops.yaml.

if [[ "${1:-}" == "--gen-key" ]]; then
  mkdir -p "$SOPS_AGE_DIR"
  chmod 700 "$SOPS_AGE_DIR"

  # Check if a personal key already exists in plugin-identities.txt
  if [[ -f "$PLUGIN_IDS" ]] && grep -qE '^AGE-SECRET-KEY-1' "$PLUGIN_IDS" 2>/dev/null; then
    EXISTING=$(grep -oP '(?<=# public key: )age1\S+' "$PLUGIN_IDS" | head -1 || true)
    echo -e "${YELLOW}A personal age key is already enrolled.${NC}"
    [[ -n "$EXISTING" ]] && echo "Public key: $EXISTING"
    echo "Remove the AGE-SECRET-KEY-1 line from $PLUGIN_IDS to re-generate."
    exit 0
  fi

  # Generate the key (mktemp creates the file; age-keygen refuses to overwrite, so remove first)
  TMPKEY=$(mktemp)
  trap 'rm -f "$TMPKEY"' EXIT
  rm -f "$TMPKEY"
  age-keygen -o "$TMPKEY"
  PERSONAL_PUBKEY=$(age-keygen -y "$TMPKEY")

  # Append to plugin-identities.txt (persists across rebuilds)
  {
    echo ""
    echo "# Personal age key generated $(date -I) — transfer to new machines"
    echo "# public key: $PERSONAL_PUBKEY"
    cat "$TMPKEY"
  } >> "$PLUGIN_IDS"
  chmod 600 "$PLUGIN_IDS"

  # Also append to keys.txt immediately so sops can use it now
  if [[ -f "$KEYS_FILE" ]]; then
    echo "" >> "$KEYS_FILE"
    cat "$TMPKEY" >> "$KEYS_FILE"
  fi

  rm -f "$TMPKEY"

  echo -e "${GREEN}Personal age key generated.${NC}"
  echo -e "Public key: ${BOLD}$PERSONAL_PUBKEY${NC}"
  echo ""

  # Add to .sops.yaml if it exists
  if [[ -f "$SOPS_YAML" ]]; then
    if grep -qF "$PERSONAL_PUBKEY" "$SOPS_YAML"; then
      echo -e "${GREEN}Key already in $SOPS_YAML.${NC}"
    else
      awk -v key="$PERSONAL_PUBKEY" '
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

      existing=$(find "$SECRETS_DIR" -name "*.yaml" ! -name ".sops.yaml" 2>/dev/null | head -5)
      if [[ -n "$existing" ]]; then
        echo ""
        echo "Re-encrypting existing secrets for the personal key..."
        cd "$SECRETS_DIR"
        for f in *.yaml; do
          [[ "$f" == ".sops.yaml" ]] && continue
          sops updatekeys --yes "$f"
        done
        cd "$CONFIG_DIR"
        echo ""
        echo -e "${GREEN}Done. Commit the updated secrets:${NC}"
        echo "  git add secrets/.sops.yaml secrets/*.yaml && git commit -m 'feat(secrets): add personal age key as recipient'"
      else
        echo "  git add -f secrets/.sops.yaml && git commit -m 'feat(secrets): add personal age key as recipient'"
      fi
    fi
  else
    echo "No .sops.yaml yet. Run 'hydrix-sops-setup' first, then re-run --gen-key."
  fi

  echo ""
  echo -e "${YELLOW}Keep a copy of $PLUGIN_IDS (or just the AGE-SECRET-KEY-1 line) in your"
  echo -e "password manager. On a new machine, append it to ~/.config/sops/age/plugin-identities.txt"
  echo -e "before the first rebuild.${NC}"

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

# ── --gen-master-key ─────────────────────────────────────────────────────────
#
# Generates a portable age key encrypted with a passphrase. The encrypted file
# is committed to the hydrix-config repo. On new machines or reinstalls, run
# --unlock to decrypt it (password required) and activate it as the sops key.
# The private key is never written to the Nix store or to disk unencrypted.
#
# To replace this key with a YubiKey later:
#   1. hydrix-sops-setup --enroll-fido2
#   2. Remove master key from secrets/.sops.yaml recipients
#   3. sops updatekeys --yes secrets/*.yaml
#   4. Optionally remove secrets/master-age-key.age from the repo

if [[ "${1:-}" == "--gen-master-key" ]]; then
  MASTER_KEY_ENC="$SECRETS_DIR/master-age-key.age"

  if [[ -f "$MASTER_KEY_ENC" ]]; then
    echo -e "${YELLOW}Master key already exists at $MASTER_KEY_ENC${NC}"
    echo "Remove it first to regenerate (and re-encrypt all secrets afterwards)."
    exit 0
  fi

  mkdir -p "$SECRETS_DIR"

  TMPKEY=$(mktemp)
  trap 'rm -f "$TMPKEY"' EXIT
  rm -f "$TMPKEY"
  age-keygen -o "$TMPKEY" 2>/dev/null
  MASTER_PUBKEY=$(age-keygen -y "$TMPKEY" 2>/dev/null)

  echo ""
  echo -e "${CYAN}Set a passphrase to protect the master key.${NC}"
  echo "You will need this passphrase when setting up new machines or reinstalling."
  echo ""
  age --passphrase -o "$MASTER_KEY_ENC" "$TMPKEY"
  rm -f "$TMPKEY"
  trap - EXIT

  echo ""
  echo -e "${GREEN}Master key encrypted and saved to:${NC} $MASTER_KEY_ENC"
  echo -e "${CYAN}Master key public key:${NC} ${BOLD}$MASTER_PUBKEY${NC}"
  echo ""
  echo "Next steps:"
  echo "1. Add the master key as a recipient in secrets/.sops.yaml:"
  echo -e "   Under 'age:', add a new line:  ${BOLD}- $MASTER_PUBKEY${NC}"
  echo ""
  echo "2. Re-encrypt all existing secrets for the master key:"
  echo -e "   ${BOLD}cd $CONFIG_DIR && sops updatekeys --yes secrets/*.yaml${NC}"
  echo ""
  echo "3. Commit the encrypted key and updated secrets:"
  echo -e "   ${BOLD}git add -f secrets/master-age-key.age secrets/.sops.yaml secrets/*.yaml${NC}"
  echo -e "   ${BOLD}git commit -m 'feat(secrets): add password-protected master age key'${NC}"
  echo ""
  echo "On a new machine or reinstall, after cloning hydrix-config and first rebuild:"
  echo -e "   ${BOLD}hydrix-sops-setup --unlock${NC}"
  exit 0
fi

# ── --unlock ──────────────────────────────────────────────────────────────────
#
# Decrypts the master age key (created with --gen-master-key) using the
# passphrase and writes the private key to /var/lib/sops-nix/master-age-key.txt.
# The sops.nix activation script prioritises this key over the SSH-derived one,
# so secrets decrypt immediately after the next rebuild (or service restart).

if [[ "${1:-}" == "--unlock" ]]; then
  MASTER_KEY_ENC="$SECRETS_DIR/master-age-key.age"
  MASTER_KEY_DEST="/var/lib/sops-nix/master-age-key.txt"

  if [[ ! -f "$MASTER_KEY_ENC" ]]; then
    echo -e "${RED}Error: $MASTER_KEY_ENC not found.${NC}" >&2
    echo "Run 'hydrix-sops-setup --gen-master-key' on another machine first," >&2
    echo "then commit secrets/master-age-key.age and pull it here." >&2
    exit 1
  fi

  echo -e "${CYAN}Unlocking master age key...${NC}"
  echo "(Enter the passphrase you set when generating the master key)"
  echo ""

  # age prompts for the passphrase interactively on the terminal
  TMPUNLOCK=$(mktemp)
  trap 'rm -f "$TMPUNLOCK"' EXIT
  if ! age -d -o "$TMPUNLOCK" "$MASTER_KEY_ENC"; then
    echo -e "${RED}Decryption failed — wrong passphrase?${NC}" >&2
    exit 1
  fi

  sudo mkdir -p /var/lib/sops-nix
  sudo chmod 700 /var/lib/sops-nix
  sudo cp "$TMPUNLOCK" "$MASTER_KEY_DEST"
  sudo chmod 600 "$MASTER_KEY_DEST"
  rm -f "$TMPUNLOCK"
  trap - EXIT

  echo ""
  echo -e "${GREEN}Master key installed at $MASTER_KEY_DEST${NC}"
  echo "Restarting sops decrypt services..."
  sudo systemctl restart hydrix-sops-decrypt-*.service 2>/dev/null || true
  echo -e "${GREEN}Done. Secrets are now available.${NC}"
  echo ""
  echo "The master key persists at $MASTER_KEY_DEST across reboots."
  echo "It is not in the Nix store and survives rebuilds."
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
