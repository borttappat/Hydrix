#!/usr/bin/env bash
#
# setup-secrets.sh - Initialize sops-nix secrets from an SSH key
#
# Usage:
#   ./scripts/setup-secrets.sh                    # Uses ~/.ssh/id_ed25519
#   ./scripts/setup-secrets.sh ~/.ssh/github_key  # Uses specific key
#
# This script:
#   1. Gets your machine's age public key
#   2. Creates secrets/.sops.yaml with your age key
#   3. Creates secrets/github.yaml with your SSH key
#   4. Encrypts it with sops
#   5. Stages it for commit
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}::${NC} $*"; }
success() { echo -e "${GREEN}::${NC} $*"; }
warn() { echo -e "${YELLOW}::${NC} $*"; }
error() { echo -e "${RED}::${NC} $*" >&2; }

# Find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$REPO_ROOT/secrets"

# Default SSH key
SSH_KEY="${1:-$HOME/.ssh/id_ed25519}"
SSH_KEY_PUB="${SSH_KEY}.pub"

# Check prerequisites
check_prereqs() {
    local missing=()

    if ! command -v sops &>/dev/null; then
        missing+=("sops")
    fi

    if ! command -v sops-age-pubkey &>/dev/null; then
        missing+=("sops-age-pubkey (rebuild with hydrix.secrets.enable = true)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        echo ""
        echo "Make sure you have enabled secrets in machines/<serial>.nix:"
        echo "  hydrix.secrets.enable = true;"
        echo ""
        echo "Then rebuild: rebuild"
        exit 1
    fi
}

# Check SSH key exists
check_ssh_key() {
    if [[ ! -f "$SSH_KEY" ]]; then
        error "SSH private key not found: $SSH_KEY"
        echo ""
        echo "Usage: $0 [path-to-ssh-key]"
        echo ""
        echo "Examples:"
        echo "  $0                           # Use ~/.ssh/id_ed25519"
        echo "  $0 ~/.ssh/github_key         # Use specific key"
        echo "  $0 /tmp/my_key               # Use any ed25519 key"
        exit 1
    fi

    if [[ ! -f "$SSH_KEY_PUB" ]]; then
        error "SSH public key not found: $SSH_KEY_PUB"
        echo "The public key must exist alongside the private key"
        exit 1
    fi

    info "Using SSH key: $SSH_KEY"
}

# Check age key setup
check_age_key() {
    local user_age_key="$HOME/.config/sops/age/keys.txt"

    # The age key is copied to the user's sops config by the system activation
    # script (host/base/sops.nix). If it's missing, the user needs to rebuild.
    if [[ ! -f "$user_age_key" ]]; then
        error "Age key not found at $user_age_key"
        echo ""
        echo "The age key is derived from your SSH host key during system activation."
        echo "Make sure hydrix.secrets.enable = true and rebuild:"
        echo "  rebuild"
        exit 1
    fi
}

# Get age public key
get_age_pubkey() {
    AGE_PUBKEY=$(sops-age-pubkey 2>/dev/null)
    if [[ -z "$AGE_PUBKEY" ]]; then
        error "Failed to get age public key"
        exit 1
    fi
    info "Age public key: $AGE_PUBKEY"
}

# Create .sops.yaml
create_sops_config() {
    local sops_file="$SECRETS_DIR/.sops.yaml"

    if [[ -f "$sops_file" ]]; then
        warn "Existing .sops.yaml found, backing up to .sops.yaml.bak"
        cp "$sops_file" "$sops_file.bak"
    fi

    cat > "$sops_file" << EOF
creation_rules:
  - path_regex: .*\\.yaml\$
    age:
      - $AGE_PUBKEY
EOF

    success "Created $sops_file"
}

# Create and encrypt github.yaml
create_github_secrets() {
    local github_file="$SECRETS_DIR/github.yaml"
    local temp_file=$(mktemp)

    # Read key contents
    local private_key=$(cat "$SSH_KEY")
    local public_key=$(cat "$SSH_KEY_PUB")

    # Create unencrypted yaml (in temp file)
    cat > "$temp_file" << EOF
id_ed25519: |
$(echo "$private_key" | sed 's/^/  /')
id_ed25519_pub: "$public_key"
EOF

    # Encrypt
    info "Encrypting secrets..."
    if sops -e "$temp_file" > "$github_file"; then
        success "Created encrypted $github_file"
    else
        error "Failed to encrypt secrets"
        rm -f "$temp_file"
        exit 1
    fi

    # Clean up
    rm -f "$temp_file"

    # Verify
    info "Verifying decryption..."
    if sops -d "$github_file" &>/dev/null; then
        success "Verification passed"
    else
        error "Verification failed - cannot decrypt"
        exit 1
    fi
}

# Stage for commit
stage_secrets() {
    cd "$REPO_ROOT"
    git add secrets/github.yaml
    success "Staged secrets/github.yaml for commit"
}

# Print next steps
print_next_steps() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    success "Secrets setup complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Enable secrets in machines/<serial>.nix:"
    echo "     ${BLUE}hydrix.secrets = {"
    echo "       enable = true;"
    echo "       githubSecretsFile = ../secrets/github.yaml;"
    echo "     };${NC}"
    echo ""
    echo "     ${BLUE}hydrix.microvmHost.vms.\"microvm-dev\" = {"
    echo "       enable = true;"
    echo "       secrets = [ \"github\" ];"
    echo "     };${NC}"
    echo ""
    echo "  2. Rebuild and test:"
    echo "     ${BLUE}rebuild"
    echo "     microvm build microvm-browsing"
    echo "     microvm start microvm-browsing"
    echo "     # In VM: ssh -T git@github.com${NC}"
    echo ""
    echo "  4. Commit your encrypted secrets:"
    echo "     ${BLUE}git commit -m 'feat: add encrypted github ssh key'${NC}"
    echo ""
}

# Main
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Hydrix Secrets Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    check_prereqs
    check_ssh_key
    check_age_key
    get_age_pubkey
    create_sops_config
    create_github_secrets
    stage_secrets
    print_next_steps
}

main "$@"
