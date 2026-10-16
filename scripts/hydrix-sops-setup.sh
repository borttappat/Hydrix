#!/usr/bin/env bash
# hydrix-sops-setup: manage the repo's single sops key (the master key).
#
# Every secret in secrets/ is encrypted to exactly one recipient: the master
# age key. Its private half is committed as secrets/master-age-key.age,
# encrypted with a passphrase, and unlocked onto the host at
# /var/lib/sops-nix/master-age-key.txt. It never leaves the host: VMs only
# receive decrypted files through /run/hydrix-secrets.
#
# Usage:
#   hydrix-sops-setup                  # fresh repo: create master key + .sops.yaml
#                                      # existing repo: check key and recipients
#   hydrix-sops-setup --print-key      # print the master public key
#   hydrix-sops-setup --unlock         # decrypt the master key and activate it here
#   hydrix-sops-setup --gen-master-key # generate the master key (fresh repo only)
#   hydrix-sops-setup --rekey          # make the master key the only recipient
#                                      # in .sops.yaml and every secret
#   hydrix-sops-setup --enroll-fido2   # enroll a FIDO2 key for a future
#                                      # replacement of the master key
#   hydrix-sops-setup --vault-key [--from FILE] [--add-to DB]
#                                      # store a vault key file as secrets/vault.key
#                                      # (new random key, or FILE read as-is); --add-to
#                                      # also adds it to an existing database (absolute
#                                      # paths; your files are shredded only on 'y')
#
# Encrypting elsewhere (e.g. on a machine that must never hold the private
# key) only needs the public key from --print-key:
#   sops -e --age <pubkey> <plaintext-file> > secrets/<name>.<yaml|json>
set -euo pipefail

CONFIG_DIR="${HYDRIX_FLAKE_DIR:-$HOME/hydrix-config}"
SECRETS_DIR="$CONFIG_DIR/secrets"
SOPS_YAML="$SECRETS_DIR/.sops.yaml"
MASTER_KEY_ENC="$SECRETS_DIR/master-age-key.age"
MASTER_KEY_DEST="/var/lib/sops-nix/master-age-key.txt"
ACTIVE_KEY="/var/lib/sops-nix/age-key.txt"
SOPS_AGE_DIR="$HOME/.config/sops/age"
PLUGIN_IDS="$SOPS_AGE_DIR/plugin-identities.txt"
KEYS_FILE="$SOPS_AGE_DIR/keys.txt"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
NC=$'\e[0m'; BOLD=$'\e[1m'

die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

is_unlocked() { sudo test -f "$MASTER_KEY_DEST"; }

master_pubkey() { sudo age-keygen -y "$MASTER_KEY_DEST" 2>/dev/null; }

# sops-encrypted .yaml/.json files and binary .key files (vault key) in secrets/; plain
# files there are skipped
secret_files() {
  local f
  for f in "$SECRETS_DIR"/*.yaml "$SECRETS_DIR"/*.json "$SECRETS_DIR"/*.key; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == ".sops.yaml" ]] && continue
    grep -qE '^sops:|"sops": *\{' "$f" && echo "$f"
  done
  return 0
}

recipients_of() { grep -oE 'age1[0-9a-z]{20,}' "$1" | sort -u; }

write_sops_yaml() {
  mkdir -p "$SECRETS_DIR"
  printf 'creation_rules:\n  - path_regex: .*\\.(yaml|json|key)$\n    age:\n      - %s\n' "$1" > "$SOPS_YAML"
}

# Install a plaintext master key as the host's only active key, for sops-nix
# services and for the user's own sops runs. Same result as the next
# rebuild's activation script, without waiting for it.
activate_key() {
  local key="$1"
  sudo mkdir -p /var/lib/sops-nix
  sudo chmod 700 /var/lib/sops-nix
  sudo install -m 600 "$key" "$MASTER_KEY_DEST"
  sudo install -m 600 "$key" "$ACTIVE_KEY"
  mkdir -p "$SOPS_AGE_DIR"
  chmod 700 "$SOPS_AGE_DIR"
  install -m 600 "$key" "$KEYS_FILE"
  if [[ -f "$PLUGIN_IDS" ]]; then
    grep '^AGE-PLUGIN-' "$PLUGIN_IDS" >> "$KEYS_FILE" || true
  fi
  sudo systemctl restart 'hydrix-sops-decrypt-*.service' 2>/dev/null || true
}

gen_master_key() {
  [[ -f "$MASTER_KEY_ENC" ]] && die "$MASTER_KEY_ENC already exists."
  [[ -f "$SOPS_YAML" ]] && die "$SOPS_YAML already exists without a master key; migrate it by hand."

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  rm -f "$tmp"
  age-keygen -o "$tmp" 2>/dev/null

  echo -e "${CYAN}Set a passphrase to protect the master key.${NC}"
  echo "It unlocks every secret on every machine: new installs, reinstalls, --unlock."
  echo ""
  mkdir -p "$SECRETS_DIR"
  age --passphrase -o "$MASTER_KEY_ENC" "$tmp"

  write_sops_yaml "$(age-keygen -y "$tmp")"
  activate_key "$tmp"
  rm -f "$tmp"
  trap - EXIT

  echo ""
  echo -e "${GREEN}Master key created and active.${NC}"
  echo -e "Public key: ${BOLD}$(master_pubkey)${NC}"
  echo ""
  echo "Commit it (the .age file is passphrase-encrypted, safe to commit):"
  echo -e "  ${BOLD}git -C $CONFIG_DIR add secrets/master-age-key.age secrets/.sops.yaml${NC}"
}

unlock() {
  [[ -f "$MASTER_KEY_ENC" ]] || die "$MASTER_KEY_ENC not found. Pull hydrix-config first."

  local tmp ok=0 attempt
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  echo -e "${CYAN}Unlocking master age key...${NC}"
  for attempt in 1 2 3; do
    echo "(Enter the master key passphrase)"
    if age -d -o "$tmp" "$MASTER_KEY_ENC"; then
      ok=1
      break
    fi
    [[ $attempt -lt 3 ]] && echo -e "${RED}Incorrect passphrase, try again ($attempt/3).${NC}" >&2
  done
  [[ $ok -eq 1 ]] || die "Decryption failed after 3 attempts."

  activate_key "$tmp"
  rm -f "$tmp"
  trap - EXIT
  echo -e "${GREEN}Master key active. Secrets decrypt now; no rebuild needed.${NC}"
}

rekey() {
  is_unlocked || die "master key not unlocked. Run 'hydrix-sops-setup --unlock' first."
  local pub f failed=0
  pub=$(master_pubkey)

  write_sops_yaml "$pub"
  echo -e "${GREEN}$SOPS_YAML now lists only the master key.${NC}"

  while read -r f; do
    [[ -n "$f" ]] || continue
    if ! grep -qF "$pub" "$f"; then
      echo -e "${RED}  $(basename "$f"): not encrypted to the master key, cannot re-key here${NC}"
      failed=1
      continue
    fi
    (cd "$SECRETS_DIR" && sops updatekeys --yes "$(basename "$f")" >/dev/null) || true
    if [[ "$(recipients_of "$f")" == "$pub" ]]; then
      echo -e "${GREEN}  $(basename "$f"): master key only${NC}"
    else
      echo -e "${RED}  $(basename "$f"): still has other recipients${NC}"
      failed=1
    fi
  done < <(secret_files)

  echo ""
  echo "Commit the result:"
  echo -e "  ${BOLD}git -C $CONFIG_DIR add secrets/ && git -C $CONFIG_DIR commit -m 'chore(secrets): re-key to master key only'${NC}"
  return $failed
}

check() {
  if ! is_unlocked; then
    echo -e "${YELLOW}Master key not unlocked on this machine.${NC}"
    echo -e "Run: ${BOLD}hydrix-sops-setup --unlock${NC}"
    exit 1
  fi

  local pub f extra=0
  pub=$(master_pubkey)
  echo -e "${CYAN}Master public key:${NC} $pub"

  if [[ "$(recipients_of "$SOPS_YAML")" != "$pub" ]]; then
    echo -e "${YELLOW}$SOPS_YAML lists recipients other than the master key.${NC}"
    extra=1
  fi
  while read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$(recipients_of "$f")" != "$pub" ]]; then
      echo -e "${YELLOW}$(basename "$f") is encrypted to recipients other than the master key.${NC}"
      extra=1
    fi
  done < <(secret_files)

  if [[ $extra -eq 1 ]]; then
    echo -e "Fix with: ${BOLD}hydrix-sops-setup --rekey${NC}"
    exit 1
  fi
  echo -e "${GREEN}Master key is the only recipient everywhere.${NC}"
}

# FIDO2 enrollment only stores the identity. Swapping it in for the master
# key is a deliberate, manual step: sops decrypt services run unattended at
# boot, and a FIDO2 identity needs a touch for every decryption.
enroll_fido2() {
  command -v age-plugin-fido2-hmac &>/dev/null ||
    die "age-plugin-fido2-hmac not found. Run 'rebuild' to install it."

  echo -e "${CYAN}Enrolling FIDO2 key with age-plugin-fido2-hmac...${NC}"
  echo "You will be asked to touch your key once to generate the credential."
  echo ""
  mkdir -p "$SOPS_AGE_DIR"
  chmod 700 "$SOPS_AGE_DIR"

  # The plugin mixes prompts and output on stdout; capture stdout only and
  # let stderr reach the terminal for the interactive prompts.
  local tmp identity pub
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  age-plugin-fido2-hmac --generate > "$tmp"
  echo ""

  identity=$(grep -E '^AGE-PLUGIN-FIDO2-HMAC-' "$tmp" | tr -d '\r' || true)
  [[ -n "$identity" ]] || die "no identity produced (empty stdout)."
  pub=$(grep -oP '(?<=# public key: )age1\S+' "$tmp" | tr -d '\r' | head -1 || true)
  if [[ -z "$pub" ]]; then
    echo -e "${CYAN}Could not parse the recipient; paste the age1... pubkey:${NC}"
    read -r pub
    pub="${pub// /}"
  fi
  [[ "$pub" == age1* ]] || die "no valid pubkey (expected 'age1...' prefix)."

  if [[ -f "$PLUGIN_IDS" ]] && grep -qF "$pub" "$PLUGIN_IDS"; then
    echo -e "${YELLOW}This FIDO2 key is already enrolled.${NC} Recipient: $pub"
    exit 0
  fi
  {
    echo ""
    echo "# FIDO2 identity enrolled $(date -I)"
    echo "# public key: $pub"
    echo "$identity"
  } >> "$PLUGIN_IDS"
  chmod 600 "$PLUGIN_IDS"

  echo -e "${GREEN}FIDO2 key enrolled.${NC} Recipient: ${BOLD}$pub${NC}"
  echo ""
  echo "Not added as a recipient: the master key stays the only key. To replace"
  echo "the master key with this one later, make it the only recipient in"
  echo "$SOPS_YAML, 'sops updatekeys' every secret, and remove"
  echo "secrets/master-age-key.age. Boot-time decrypt services cannot touch a"
  echo "FIDO2 key, so that switch needs its own design first."
}

# Shred a file the user owns only on an explicit "y" at a terminal; anything else keeps it.
offer_shred() {
  local file="$1" what="$2" answer=""
  if [[ -t 0 ]]; then
    read -rp "Shred $what ($file)? [y/N] " answer
  fi
  if [[ "$answer" == [yY] ]]; then
    shred -u "$file" && echo -e "${GREEN}Shredded $file.${NC}"
  else
    echo -e "${YELLOW}Kept $file. Shred it yourself once you no longer need it: shred -u $file${NC}"
  fi
}

# --vault-key [--from FILE] [--add-to DB]: store a vault key file as secrets/vault.key
# (binary sops, delivered to the vault VM by hydrix.secrets.vaultKeyFile). Plain key material
# is shredded once it is safely stored, but nothing the user owns is lost by accident: an
# existing secrets/vault.key is refused, the database is edited only after the key is stored
# and a copy of it is saved, and a --from key file or that copy is shredded only on an
# explicit "y". The key this command generates itself (tmpfs) is always shredded.
vault_key() {
  local from="" db="" src generated="" kpcli=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --add-to) db="${2:-}"; shift 2 ;;
      *) die "unknown argument '$1' (usage: --vault-key [--from FILE] [--add-to DB])" ;;
    esac
  done

  is_unlocked || die "master key not unlocked. Run 'hydrix-sops-setup --unlock' first."
  [[ -f "$SOPS_YAML" ]] || die "$SOPS_YAML missing. Run 'hydrix-sops-setup' first."
  if [[ -e "$SECRETS_DIR/vault.key" ]]; then
    die "secrets/vault.key already exists, and a database may need it. Not replacing it.
       To start over on purpose, move it away first: git -C $CONFIG_DIR mv secrets/vault.key secrets/vault.key.old"
  fi
  # Older .sops.yaml files (written before vault keys) only matched .yaml/.json.
  if grep -qF 'path_regex: .*\.(yaml|json)$' "$SOPS_YAML"; then
    sed -i 's/path_regex: \.\*\\\.(yaml|json)\$/path_regex: .*\\.(yaml|json|key)$/' "$SOPS_YAML"
    echo -e "${YELLOW}$SOPS_YAML: creation rule extended to *.key files.${NC}"
  fi
  for p in "$from" "$db"; do
    [[ -z "$p" || "$p" == /* ]] || die "give an absolute path: $p"
  done

  if [[ -n "$from" ]]; then
    [[ -f "$from" && -r "$from" && -s "$from" ]] || die "key file not found or empty: $from"
    src="$from"
  else
    generated=$(mktemp -p "${XDG_RUNTIME_DIR:?}" vault-key.XXXXXX)
    # shellcheck disable=SC2064
    trap "shred -u '$generated' 2>/dev/null || rm -f '$generated'" EXIT
    head -c 64 /dev/urandom > "$generated"
    src="$generated"
  fi

  if [[ -n "$db" ]]; then
    [[ -f "$db" ]] || die "database not found: $db"
    if command -v keepassxc-cli >/dev/null; then
      kpcli=(keepassxc-cli)
    else
      kpcli=(nix shell nixpkgs#keepassxc -c keepassxc-cli)
    fi
  fi

  # --filename-override: creation rules match the input name, which need not end in .key.
  (cd "$SECRETS_DIR" && sops --encrypt --input-type binary --filename-override vault.key \
    --output vault.key "$src") \
    || { rm -f "$SECRETS_DIR/vault.key"; die "sops could not encrypt the key"; }
  if ! (cd "$SECRETS_DIR" && sops --decrypt vault.key) | cmp -s - "$src"; then
    rm -f "$SECRETS_DIR/vault.key"
    die "secrets/vault.key does not decrypt to the same bytes; removed it"
  fi
  git -C "$CONFIG_DIR" add secrets/vault.key "$SOPS_YAML"
  echo -e "${GREEN}secrets/vault.key created and staged (sops, master key only).${NC}"

  if [[ -n "$db" ]]; then
    local backup pw
    backup="${XDG_RUNTIME_DIR}/$(basename "$db").before-key"
    cp -n "$db" "$backup" || die "could not save a copy of the database to $backup"
    echo -e "Saved a copy of the database (password only) to ${BOLD}$backup${NC} (tmpfs, gone at reboot)."
    # Asked once, passed on stdin to both keepassxc-cli runs (never on a command line).
    if [[ -t 0 ]]; then
      read -rsp "Master password of $db: " pw; echo
    else
      IFS= read -r pw || pw=""
    fi
    # secrets/vault.key was created by this run and nothing uses it yet: on failure it goes,
    # so a retry is not blocked.
    if ! printf '%s\n' "$pw" | "${kpcli[@]}" db-edit -q --set-key-file "$src" "$db"; then
      unset pw
      git -C "$CONFIG_DIR" rm -qf secrets/vault.key
      cmp -s "$backup" "$db" && rm -f "$backup"
      die "db-edit failed: wrong password, or the database already has a key file (then run without --add-to). $db is unchanged, secrets/vault.key removed again"
    fi
    if ! printf '%s\n' "$pw" | "${kpcli[@]}" ls -q -k "$src" "$db" >/dev/null; then
      unset pw
      die "the database did not open with the key; restore it with: cp $backup $db"
    fi
    unset pw
    echo -e "${GREEN}$db now needs the master password and the key file.${NC}"
    offer_shred "$backup" "the password-only copy of the database"
  fi
  [[ -z "$from" ]] || offer_shred "$from" "your plain key file (secrets/vault.key holds it now)"

  echo ""
  echo "Enable it, then rebuild and restart the vault VM:"
  echo -e "  machine config:          ${BOLD}hydrix.secrets.vaultKeyFile = ../secrets/vault.key;${NC}"
  echo -e "  infra/vault/default.nix: ${BOLD}hydrix.vault.agent.keyFile = \"/mnt/vm-secrets/vault/vault.key\";${NC}"
  echo -e "  ${BOLD}rebuild && shard -bR vault${NC}"
  [[ -n "$db" ]] || echo "With no database yet, the first 'vault' run creates one that uses the key."
  if [[ -n "$from" && -e "$from" ]]; then
    echo "Commit secrets/vault.key soon."
  else
    echo "Commit secrets/vault.key soon: it is the only copy of the key now."
  fi
}

case "${1:-}" in
  "")
    if [[ -f "$SOPS_YAML" ]]; then
      check
    elif [[ -f "$MASTER_KEY_ENC" ]]; then
      is_unlocked || unlock
      write_sops_yaml "$(master_pubkey)"
      echo -e "${GREEN}Created $SOPS_YAML with the master key as the only recipient.${NC}"
    else
      gen_master_key
    fi
    ;;
  --print-key)
    is_unlocked || die "master key not unlocked. Run 'hydrix-sops-setup --unlock'."
    master_pubkey
    ;;
  --unlock) unlock ;;
  --gen-master-key) gen_master_key ;;
  --rekey) rekey ;;
  --enroll-fido2) enroll_fido2 ;;
  --vault-key) shift; vault_key "$@" ;;
  *) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
