# Sops-nix Secrets Management for Hydrix
#
# This module configures sops-nix for secure secrets management.
#
# One key: the repo's master key. secrets/master-age-key.age holds it,
# passphrase-encrypted, and 'hydrix-sops-setup --unlock' (or the installer)
# decrypts it to /var/lib/sops-nix/master-age-key.txt on the host. It is the
# only recipient in secrets/.sops.yaml and the only key sops services use, on
# every machine. It never leaves the host: VMs only receive decrypted files
# through /run/hydrix-secrets.
#
# There is no fallback key. Until the master key is unlocked, decrypt
# services create empty /run/secrets/<name>/ directories and log a warning
# instead of failing, so VMs still start without secrets.
#
# Quick start (fresh repo):
#   1. Enable: hydrix.secrets.enable = true;
#   2. Run: hydrix-sops-setup               (generates master key, .sops.yaml)
#   3. Create secrets: sops secrets/github.yaml
#   4. Set githubSecretsFile and rebuild
#
# New machine or reinstall: hydrix-sops-setup --unlock
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.secrets;
  username = config.hydrix.username;

  # Path where age key will be stored (active key used by sops services)
  ageKeyPath = "/var/lib/sops-nix/age-key.txt";

  # Path where the password-unlocked master key lives (written by hydrix-sops-setup --unlock)
  # This file is never in the Nix store and survives rebuilds.
  masterKeyPath = "/var/lib/sops-nix/master-age-key.txt";
in {
  config = lib.mkIf cfg.enable {
    # The unlocked master key is the only active key. Without it, any
    # previously active key (e.g. one derived from the SSH host key before the
    # single-key model) is removed so it can no longer decrypt anything.
    system.activationScripts.sops-age-key = {
      text = ''
        mkdir -p /var/lib/sops-nix
        chmod 700 /var/lib/sops-nix

        SOPS_AGE_DIR="/home/${username}/.config/sops/age"
        PLUGIN_IDS="$SOPS_AGE_DIR/plugin-identities.txt"
        KEYS_FILE="$SOPS_AGE_DIR/keys.txt"

        if [ -f "${masterKeyPath}" ]; then
          install -m 600 "${masterKeyPath}" "${ageKeyPath}"

          # ~/.config/sops/age/keys.txt (sops' default search path) lets the
          # user edit secrets with the same key. FIDO2 plugin identities are
          # kept for a future hardware-key replacement of the master key;
          # plain AGE-SECRET-KEY lines from plugin-identities.txt are not.
          install -d -o ${username} -m 700 "$SOPS_AGE_DIR"
          install -o ${username} -m 600 "${ageKeyPath}" "$KEYS_FILE"
          if [ -f "$PLUGIN_IDS" ]; then
            grep '^AGE-PLUGIN-' "$PLUGIN_IDS" >> "$KEYS_FILE" || true
          fi
        else
          rm -f "${ageKeyPath}" "$KEYS_FILE"
        fi
      '';
      deps = ["etc" "users"];
    };

    # Auto-wire convenience shorthands into hydrix.secrets.files.
    # lib.mkDefault means explicit files.github / files.wifi in user config take priority.
    hydrix.secrets.files = lib.mkMerge [
      (lib.mkIf (cfg.githubSecretsFile != null) {
        github = lib.mkDefault {
          file = cfg.githubSecretsFile;
          vmDir = "ssh";
          keys = {
            "id_ed25519" = {
              outFile = "id_ed25519";
              mode = "0600";
            };
            "id_ed25519_pub" = {
              outFile = "id_ed25519.pub";
              mode = "0644";
            };
          };
        };
      })
      (lib.mkIf (cfg.wifiSecretsFile != null) {
        wifi = lib.mkDefault {
          file = cfg.wifiSecretsFile;
          vmDir = "wifi";
          keys = {
            "networks" = {
              outFile = "networks.json";
              mode = "0600";
            };
          };
        };
      })
    ];

    # Generate one decryption service per files entry.
    # Replaces the old hardcoded hydrix-github-secrets.service.
    # All services are non-fatal: exit 0 with a warning on decryption failure
    # so fresh-install / wrong-key machines can still boot and start VMs.
    systemd.services = lib.mapAttrs' (
      name: fileCfg: let
        wholeFile = fileCfg.keys == {};
        outFileName =
          if fileCfg.outFile != ""
          then fileCfg.outFile
          else builtins.baseNameOf (toString fileCfg.file);
      in
        lib.nameValuePair "hydrix-sops-decrypt-${name}" {
          description = "Decrypt sops ${name} secrets";
          wantedBy = ["multi-user.target"];
          after = ["local-fs.target"];
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
              echo "Master key not unlocked, ${name} secrets unavailable (run hydrix-sops-setup --unlock)"
              exit 0
            fi

            ${
              if wholeFile
              then ''
                # Whole-file mode: decrypt entire sops file as-is
                if SOPS_AGE_KEY_FILE="$AGE_KEY" \
                   ${pkgs.sops}/bin/sops --decrypt "${fileCfg.file}" \
                   > "$OUT/${outFileName}" 2>/dev/null; then
                  chmod 0600 "$OUT/${outFileName}"
                else
                  echo "Warning: could not decrypt ${name} secrets"
                fi
              ''
              else ''
                # Per-key mode: extract individual YAML keys
                ${lib.concatStringsSep "" (lib.mapAttrsToList (keyName: keyCfg: ''
                    if SOPS_AGE_KEY_FILE="$AGE_KEY" \
                       ${pkgs.sops}/bin/sops --decrypt --extract '["${keyName}"]' "${fileCfg.file}" \
                       > "$OUT/${keyCfg.outFile}" 2>/dev/null; then
                      chmod ${keyCfg.mode} "$OUT/${keyCfg.outFile}"
                    else
                      echo "Warning: could not extract ${keyName} from ${name} secrets"
                    fi
                  '')
                  fileCfg.keys)}
              ''
            }
          '';
        }
    ) (lib.filterAttrs (_: f: f.enable && f.file != null) cfg.files);

    # Helper script to get age public key
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "sops-age-pubkey" ''
        # Prints the master key's public key: the one recipient every secret
        # is encrypted to. /var/lib/sops-nix is root-only, so an unprivileged
        # caller could not tell "missing" from "unreadable"; refuse instead.
        if [ "$(id -u)" -ne 0 ]; then
          echo "Error: sops-age-pubkey must be run with sudo (reads root-only /var/lib/sops-nix/)." >&2
          exit 1
        fi

        if [ ! -f "${masterKeyPath}" ]; then
          echo "Error: master key not unlocked. Run 'hydrix-sops-setup --unlock'." >&2
          exit 1
        fi
        ${pkgs.age}/bin/age-keygen -y "${masterKeyPath}"
      '')

      pkgs.sops
      pkgs.age
      pkgs.age-plugin-fido2-hmac
    ];

    # FIDO2 device access (Titan, Yubikey, etc.)
    # libfido2 udev rules cover most known FIDO2 keys.
    # The Titan v2 (18d1:9470) is not yet in the upstream list so we add it explicitly.
    # TAG+="uaccess" grants access to the logged-in seat user without requiring a group.
    services.udev.packages = [pkgs.libfido2];
    services.udev.extraRules = ''
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9470", TAG+="uaccess"
    '';
  };
}
