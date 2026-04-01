# Sops-nix Secrets Management for Hydrix
#
# This module configures sops-nix for secure secrets management:
# - Derives age key from SSH host key (no additional key management)
# - Decrypts secrets at boot time via systemd service (non-fatal on fresh install)
# - Provides sops-age-pubkey helper to get the age public key
#
# Fresh install behaviour:
#   On the first boot after a fresh install, the SSH host key is new so the
#   derived age key won't match the recipients in secrets/github.yaml.
#   hydrix-github-secrets.service handles this gracefully: it creates an empty
#   /run/secrets/github/ directory and logs a warning instead of failing.
#   VMs that need secrets will start without SSH keys until the operator
#   re-encrypts the secrets file for the new age key.
#
# Usage:
#   1. Enable: hydrix.secrets.enable = true;
#   2. Rebuild to generate age key: rebuild
#   3. Get public key: sops-age-pubkey
#   4. Re-encrypt secrets for new key: SOPS_AGE_KEY_FILE=/var/lib/sops-nix/age-key.txt sops rotate -i secrets/github.yaml
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.secrets;

  # Path where age key will be stored (derived from SSH host key)
  ageKeyPath = "/var/lib/sops-nix/age-key.txt";

  # SSH host key to derive age key from
  sshHostKeyPath = "/etc/ssh/ssh_host_ed25519_key";

  # Secrets file path (in Hydrix repo — encrypted with user's age key)
  githubSecretsPath = toString ../../secrets/github.yaml;

in {
  config = lib.mkIf cfg.enable {
    # Ensure SSH host key exists before we try to derive age key
    services.openssh.enable = lib.mkDefault true;

    # Activation script to derive age key from SSH host key
    system.activationScripts.sops-age-key = {
      text = ''
        mkdir -p /var/lib/sops-nix
        chmod 700 /var/lib/sops-nix

        if [ -f "${sshHostKeyPath}" ]; then
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i "${sshHostKeyPath}" > "${ageKeyPath}" 2>/dev/null || true
          if [ -f "${ageKeyPath}" ]; then
            chmod 600 "${ageKeyPath}"
          fi
        fi
      '';
      deps = [ "etc" ];
    };

    # Decrypt GitHub secrets at boot (non-fatal — fresh install safe)
    # Runs before VM provisioning services which copy from /run/secrets/github/
    systemd.services.hydrix-github-secrets = lib.mkIf cfg.github.enable {
      description = "Decrypt GitHub SSH secrets for MicroVM provisioning";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -uo pipefail

        SECRETS_OUT="/run/secrets/github"
        AGE_KEY="${ageKeyPath}"
        SOPS_FILE="${githubSecretsPath}"

        # Always create output dir — VM provisioning services expect it to exist
        mkdir -p "$SECRETS_OUT"
        chmod 700 "$SECRETS_OUT"

        if [ ! -f "$AGE_KEY" ]; then
          echo "No age key found — secrets unavailable (fresh install, run 'rebuild' first)"
          exit 0
        fi

        # Attempt decryption — exit 0 on failure so the service stays non-fatal
        if SOPS_AGE_KEY_FILE="$AGE_KEY" \
           ${pkgs.sops}/bin/sops --decrypt --extract '["id_ed25519"]' "$SOPS_FILE" \
           > "$SECRETS_OUT/id_ed25519" 2>/dev/null; then
          chmod 600 "$SECRETS_OUT/id_ed25519"
          SOPS_AGE_KEY_FILE="$AGE_KEY" \
            ${pkgs.sops}/bin/sops --decrypt --extract '["id_ed25519_pub"]' "$SOPS_FILE" \
            > "$SECRETS_OUT/id_ed25519.pub" 2>/dev/null || true
          chmod 644 "$SECRETS_OUT/id_ed25519.pub" 2>/dev/null || true
          echo "GitHub secrets decrypted successfully"
        else
          echo "Warning: could not decrypt GitHub secrets"
          echo "On a fresh install, run 'sops-age-pubkey' after first rebuild, then:"
          echo "  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/age-key.txt sops rotate -i ${githubSecretsPath}"
        fi
      '';
    };

    # Helper script to get age public key
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "sops-age-pubkey" ''
        SSH_KEY="${sshHostKeyPath}"
        AGE_KEY="${ageKeyPath}"

        if [ ! -f "$SSH_KEY" ]; then
          echo "Error: SSH host key not found at $SSH_KEY" >&2
          echo "Run 'sudo ssh-keygen -A' or rebuild the system first." >&2
          exit 1
        fi

        if [ -f "$AGE_KEY" ]; then
          ${pkgs.age}/bin/age-keygen -y "$AGE_KEY" 2>/dev/null
        else
          ${pkgs.ssh-to-age}/bin/ssh-to-age -i "$SSH_KEY.pub" 2>/dev/null
        fi
      '')

      pkgs.sops
      pkgs.age
      pkgs.ssh-to-age
    ];
  };
}
