# Sops-nix Secrets Management for Hydrix
#
# This module configures sops-nix for secure secrets management:
# - Derives age key from SSH host key (no additional key management)
# - Decrypts secrets at boot via hydrix-sops-decrypt-<name>.service (non-fatal on fresh install)
# - Provides sops-age-pubkey helper to get the age public key
#
# Fresh install behaviour:
#   On the first boot after a fresh install, the SSH host key is new so the
#   derived age key won't match the recipients in the encrypted files.
#   Decrypt services handle this gracefully: they create empty /run/secrets/<name>/
#   directories and log a warning instead of failing. VMs start normally without
#   secrets until the operator re-encrypts for the new age key.
#
# Usage:
#   1. Enable: hydrix.secrets.enable = true;
#   2. Set: hydrix.secrets.githubSecretsFile = ../secrets/github.yaml;
#   3. Rebuild to generate age key: rebuild
#   4. Get public key: sops-age-pubkey
#   5. Re-encrypt secrets for new key: SOPS_AGE_KEY_FILE=/var/lib/sops-nix/age-key.txt sops rotate -i secrets/github.yaml
#
{ config, lib, pkgs, ... }:

let
  cfg      = config.hydrix.secrets;
  username = config.hydrix.username;

  # Path where age key will be stored (derived from SSH host key)
  ageKeyPath = "/var/lib/sops-nix/age-key.txt";

  # SSH host key to derive age key from
  sshHostKeyPath = "/etc/ssh/ssh_host_ed25519_key";

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

        # Assemble ~/.config/sops/age/keys.txt from:
        #   1. The host age key (derived from SSH host key above)
        #   2. Any plugin identities (Titan/FIDO2 keys) saved in plugin-identities.txt
        #
        # keys.txt is sops' default search path. It is rebuilt on every activation
        # so the host key stays current; plugin-identities.txt persists across rebuilds.
        if [ -f "${ageKeyPath}" ]; then
          SOPS_AGE_DIR="/home/${username}/.config/sops/age"
          PLUGIN_IDS="$SOPS_AGE_DIR/plugin-identities.txt"
          KEYS_FILE="$SOPS_AGE_DIR/keys.txt"

          install -d -o ${username} -m 700 "$SOPS_AGE_DIR"
          install -o ${username} -m 600 "${ageKeyPath}" "$KEYS_FILE"

          if [ -f "$PLUGIN_IDS" ]; then
            cat "$PLUGIN_IDS" >> "$KEYS_FILE"
          fi
        fi
      '';
      deps = [ "etc" "users" ];
    };

    # Auto-wire convenience shorthands into hydrix.secrets.files.
    # lib.mkDefault means explicit files.github / files.wifi in user config take priority.
    hydrix.secrets.files = lib.mkMerge [
      (lib.mkIf (cfg.githubSecretsFile != null) {
        github = lib.mkDefault {
          file  = cfg.githubSecretsFile;
          vmDir = "ssh";
          keys  = {
            "id_ed25519"     = { outFile = "id_ed25519";     mode = "0600"; };
            "id_ed25519_pub" = { outFile = "id_ed25519.pub"; mode = "0644"; };
          };
        };
      })
      (lib.mkIf (cfg.wifiSecretsFile != null) {
        wifi = lib.mkDefault {
          file  = cfg.wifiSecretsFile;
          vmDir = "wifi";
          keys  = {
            "networks" = { outFile = "networks.json"; mode = "0600"; };
          };
        };
      })
    ];

    # Generate one decryption service per files entry.
    # Replaces the old hardcoded hydrix-github-secrets.service.
    # All services are non-fatal: exit 0 with a warning on decryption failure
    # so fresh-install / wrong-key machines can still boot and start VMs.
    systemd.services = lib.mapAttrs' (name: fileCfg:
      let
        wholeFile = fileCfg.keys == {};
        outFileName =
          if fileCfg.outFile != "" then fileCfg.outFile
          else builtins.baseNameOf (toString fileCfg.file);
      in
      lib.nameValuePair "hydrix-sops-decrypt-${name}" {
        description = "Decrypt sops ${name} secrets";
        wantedBy    = [ "multi-user.target" ];
        after       = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          OUT="/run/secrets/${name}"
          AGE_KEY="${ageKeyPath}"

          mkdir -p "$OUT"
          chmod 700 "$OUT"

          if [ ! -f "$AGE_KEY" ]; then
            echo "No age key — ${name} secrets unavailable (run rebuild first)"
            exit 0
          fi

          ${if wholeFile then ''
            # Whole-file mode: decrypt entire sops file as-is
            if SOPS_AGE_KEY_FILE="$AGE_KEY" \
               ${pkgs.sops}/bin/sops --decrypt "${toString fileCfg.file}" \
               > "$OUT/${outFileName}" 2>/dev/null; then
              chmod 0600 "$OUT/${outFileName}"
            else
              echo "Warning: could not decrypt ${name} secrets"
            fi
          '' else ''
            # Per-key mode: extract individual YAML keys
            ${lib.concatStringsSep "" (lib.mapAttrsToList (keyName: keyCfg: ''
              if SOPS_AGE_KEY_FILE="$AGE_KEY" \
                 ${pkgs.sops}/bin/sops --decrypt --extract '["${keyName}"]' "${toString fileCfg.file}" \
                 > "$OUT/${keyCfg.outFile}" 2>/dev/null; then
                chmod ${keyCfg.mode} "$OUT/${keyCfg.outFile}"
              else
                echo "Warning: could not extract ${keyName} from ${name} secrets"
              fi
            '') fileCfg.keys)}
          ''}
        '';
      }
    ) (lib.filterAttrs (_: f: f.enable && f.file != null) cfg.files);

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
      pkgs.age-plugin-fido2-hmac
    ];

    # FIDO2 device access (Titan, Yubikey, etc.)
    # libfido2 udev rules cover most known FIDO2 keys.
    # The Titan v2 (18d1:9470) is not yet in the upstream list so we add it explicitly.
    # TAG+="uaccess" grants access to the logged-in seat user without requiring a group.
    services.udev.packages = [ pkgs.libfido2 ];
    services.udev.extraRules = ''
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9470", TAG+="uaccess"
    '';
  };
}
