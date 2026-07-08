# Sops-nix Secrets Management for Hydrix
#
# This module configures sops-nix for secure secrets management.
#
# Two key sources, in priority order:
#   1. Master key  — /var/lib/sops-nix/master-age-key.txt
#      Written by 'hydrix-sops-setup --unlock' (password-protected, portable).
#      Survives reinstalls and works across machines without sops updatekeys.
#      Generate once with 'hydrix-sops-setup --gen-master-key'.
#   2. SSH host key — /etc/ssh/ssh_host_ed25519_key (derived to age key)
#      Automatic fallback when no master key is present.
#      Changes on reinstall — needs sops updatekeys for each new machine.
#
# Decrypt services are non-fatal: they create empty /run/secrets/<name>/
# directories and log a warning instead of failing. VMs start normally without
# secrets until the correct key is available.
#
# Quick start (fresh install):
#   1. Enable: hydrix.secrets.enable = true;
#   2. Rebuild to generate age key: rebuild
#   3. Run: hydrix-sops-setup               (creates secrets/.sops.yaml)
#   4. (Optional, recommended) Run: hydrix-sops-setup --gen-master-key
#   5. Create secrets: sops secrets/github.yaml
#   6. Set githubSecretsFile and rebuild
#
# Multi-machine / reinstall (with master key):
#   New machine: hydrix-sops-setup --unlock   (enter passphrase, secrets decrypt immediately)
#
{ config, lib, pkgs, ... }:

let
  cfg      = config.hydrix.secrets;
  username = config.hydrix.username;

  # Path where age key will be stored (active key used by sops services)
  ageKeyPath = "/var/lib/sops-nix/age-key.txt";

  # Path where the password-unlocked master key lives (written by hydrix-sops-setup --unlock)
  # This file is never in the Nix store and survives rebuilds.
  masterKeyPath = "/var/lib/sops-nix/master-age-key.txt";

  # SSH host key to derive age key from (fallback when no master key is present)
  sshHostKeyPath = "/etc/ssh/ssh_host_ed25519_key";

in {
  config = lib.mkIf cfg.enable {
    # Ensure SSH host key exists before we try to derive age key
    services.openssh.enable = lib.mkDefault true;

    # Activation script: prefer master key over SSH-derived key.
    # Master key is written by 'hydrix-sops-setup --unlock' and persists
    # across rebuilds at /var/lib/sops-nix/master-age-key.txt.
    # When present it takes priority so secrets survive machine reinstalls
    # and multi-machine setups without needing 'sops updatekeys'.
    system.activationScripts.sops-age-key = {
      text = ''
        mkdir -p /var/lib/sops-nix
        chmod 700 /var/lib/sops-nix

        if [ -f "${masterKeyPath}" ]; then
          # Master key unlocked by user — use it as the active key
          cp "${masterKeyPath}" "${ageKeyPath}"
          chmod 600 "${ageKeyPath}"
        elif [ -f "${sshHostKeyPath}" ]; then
          # No master key — fall back to SSH host key derivation
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
        MASTER_KEY="${masterKeyPath}"
        SSH_KEY="${sshHostKeyPath}"
        AGE_KEY="${ageKeyPath}"

        if [ -f "$AGE_KEY" ]; then
          if [ -f "$MASTER_KEY" ]; then
            echo "# source: master key (hydrix-sops-setup --unlock)" >&2
          else
            echo "# source: SSH host key (machine-specific)" >&2
          fi
          ${pkgs.age}/bin/age-keygen -y "$AGE_KEY" 2>/dev/null
        elif [ -f "$SSH_KEY" ]; then
          echo "# source: SSH host key (age-key.txt not yet generated, run rebuild)" >&2
          ${pkgs.ssh-to-age}/bin/ssh-to-age -i "$SSH_KEY.pub" 2>/dev/null
        else
          echo "Error: no age key available. Run 'rebuild' first." >&2
          exit 1
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
