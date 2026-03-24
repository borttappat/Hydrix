# Sops-nix Secrets Management for Hydrix
#
# This module configures sops-nix for secure secrets management:
# - Derives age key from SSH host key (no additional key management)
# - Decrypts secrets at activation time to /run/secrets/
# - Provides sops-age-pubkey helper to get the age public key
#
# Usage:
#   1. Enable: hydrix.secrets.enable = true;
#   2. Rebuild to generate age key: rebuild
#   3. Get public key: sops-age-pubkey
#   4. Configure secrets in secrets/.sops.yaml with your public key
#   5. Encrypt secrets: sops -e -i secrets/github.yaml
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.secrets;

  # Path where age key will be stored (derived from SSH host key)
  ageKeyPath = "/var/lib/sops-nix/age-key.txt";

  # SSH host key to derive age key from
  sshHostKeyPath = "/etc/ssh/ssh_host_ed25519_key";

  # Secrets file path (in repo - encrypted files are safe to commit)
  githubSecretsPath = ../../secrets/github.yaml;

in {
  config = lib.mkIf cfg.enable {
    # Ensure SSH host key exists before we try to derive age key
    services.openssh.enable = lib.mkDefault true;

    # Activation script to derive age key from SSH host key
    system.activationScripts.sops-age-key = {
      text = ''
        # Create directory for age key
        mkdir -p /var/lib/sops-nix
        chmod 700 /var/lib/sops-nix

        # Derive age key from SSH host key if it exists
        if [ -f "${sshHostKeyPath}" ]; then
          # Use ssh-to-age to convert SSH key to age key
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i "${sshHostKeyPath}" > "${ageKeyPath}" 2>/dev/null || true

          if [ -f "${ageKeyPath}" ]; then
            chmod 600 "${ageKeyPath}"
          fi
        fi
      '';
      deps = [ "etc" ];  # Run after /etc is set up (SSH keys)
    };

    # Configure sops-nix
    sops = {
      # Use the derived age key
      age.keyFile = ageKeyPath;

      # Default secrets go to /run/secrets
      defaultSopsFile = lib.mkIf cfg.github.enable githubSecretsPath;

      # GitHub SSH key secrets
      secrets = lib.mkIf cfg.github.enable {
        "id_ed25519" = {
          sopsFile = githubSecretsPath;
          path = "/run/secrets/github/id_ed25519";
          mode = "0600";
        };
        "id_ed25519_pub" = {
          sopsFile = githubSecretsPath;
          path = "/run/secrets/github/id_ed25519.pub";
          mode = "0644";
        };
      };
    };

    # Helper script to get age public key
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "sops-age-pubkey" ''
        #!/usr/bin/env bash
        set -e

        SSH_KEY="${sshHostKeyPath}"
        AGE_KEY="${ageKeyPath}"

        if [ ! -f "$SSH_KEY" ]; then
          echo "Error: SSH host key not found at $SSH_KEY" >&2
          echo "Run 'sudo ssh-keygen -A' or rebuild the system first." >&2
          exit 1
        fi

        # Get the public key from the derived age key
        if [ -f "$AGE_KEY" ]; then
          # Extract public key from private key
          ${pkgs.age}/bin/age-keygen -y "$AGE_KEY" 2>/dev/null
        else
          # Derive from SSH key directly (for display purposes)
          ${pkgs.ssh-to-age}/bin/ssh-to-age -i "$SSH_KEY.pub" 2>/dev/null
        fi
      '')

      # Also include sops binary for encrypting/decrypting secrets
      pkgs.sops
      pkgs.age
      pkgs.ssh-to-age
    ];
  };
}
