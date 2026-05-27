# Vault Infra VM — KeepassXC credential store
#
# Persistent KeepassXC DB stored in a virtiofs-backed host directory
# (/var/lib/microvms/microvm-vault/vault-export/ on host → /var/lib/vault in VM).
# Fully offline: no TAP interface — credentials cannot be exfiltrated over the network.
#
# Host communicates via vsock port 14514. Session managed in /run/vault-session/
# (tmpfs, cleared on reboot). Auto-locks after 5 minutes of inactivity.
#
# Protocol:
#   PING                        → PONG
#   UNLOCK <password>           → OK | ERROR <reason>
#   LOCK                        → OK
#   STATUS                      → LOCKED | UNLOCKED <count>
#   LIST                        → OK\n<entry>\n... | ERROR <reason>
#   GET <entry-path> <field>    → OK <value> | ERROR <reason>
#     fields: password, username, url, notes
#
# Sync: vault-cli sync triggers gitsync VM to commit + push vault repo.
{ config, lib, pkgs, ... }:
let
  meta         = import ./meta.nix;
  hostUsername = config.hydrix.username;
  sessionDir   = "/run/vault-session";
  sessionFile  = "${sessionDir}/token";
  lockFile     = "${sessionDir}/locked";
  vaultDir     = "/var/lib/vault";
  vaultDb      = "${vaultDir}/Passwords.kdbx";
  lockTimeout  = 300; # seconds idle before auto-lock

  vaultHandler = pkgs.writeShellScript "vault-agent-handler" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath (with pkgs; [ keepassxc coreutils gnugrep gnused ])}"

    SESSION_FILE="${sessionFile}"
    LOCK_FILE="${lockFile}"
    VAULT_DB="${vaultDb}"
    LOCK_TIMEOUT="${toString lockTimeout}"

    is_unlocked() {
      [ -f "$SESSION_FILE" ] && [ ! -f "$LOCK_FILE" ]
    }

    pipe_password() {
      cat "$SESSION_FILE"
    }

    touch_session() {
      touch "$SESSION_FILE"
    }

    auto_lock_if_stale() {
      if is_unlocked; then
        mtime=$(stat -c %Y "$SESSION_FILE" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$(( now - mtime ))
        if [ "$age" -gt "$LOCK_TIMEOUT" ]; then
          touch "$LOCK_FILE"
        fi
      fi
    }

    read -r CMD REST || true

    # Auto-lock check on every command except UNLOCK/PING
    case "$CMD" in
      UNLOCK|PING) ;;
      *) auto_lock_if_stale ;;
    esac

    case "$CMD" in

      PING)
        echo "PONG"
        ;;

      UNLOCK)
        PASSWORD="''${REST:-}"
        if [ -z "$PASSWORD" ]; then
          echo "ERROR no password provided"
          exit 0
        fi
        if ! [ -f "$VAULT_DB" ]; then
          echo "ERROR vault database not found at $VAULT_DB"
          exit 0
        fi
        # Test password by listing entries
        if printf '%s\n' "$PASSWORD" | keepassxc-cli ls "$VAULT_DB" >/dev/null 2>&1; then
          mkdir -p "${sessionDir}"
          printf '%s\n' "$PASSWORD" > "$SESSION_FILE"
          chmod 600 "$SESSION_FILE"
          rm -f "$LOCK_FILE"
          echo "OK"
        else
          echo "ERROR wrong password"
        fi
        ;;

      LOCK)
        touch "$LOCK_FILE"
        echo "OK"
        ;;

      STATUS)
        if is_unlocked; then
          count=$(pipe_password | keepassxc-cli ls --recursive "$VAULT_DB" 2>/dev/null \
            | grep -v '^\[' | grep -v '^$' | grep -c '.' || echo "0")
          echo "UNLOCKED $count"
        else
          echo "LOCKED"
        fi
        ;;

      LIST)
        if ! is_unlocked; then
          echo "ERROR vault is locked"
          exit 0
        fi
        touch_session
        echo "OK"
        pipe_password | keepassxc-cli ls --recursive "$VAULT_DB" 2>/dev/null \
          | grep -v '^\[' | grep -v '^$' | grep -v '/$' || true
        ;;

      GET)
        if ! is_unlocked; then
          echo "ERROR vault is locked"
          exit 0
        fi
        ENTRY=$(echo "$REST" | cut -d' ' -f1)
        FIELD=$(echo "$REST" | cut -d' ' -f2)
        if [ -z "$ENTRY" ] || [ -z "$FIELD" ]; then
          echo "ERROR usage: GET <entry> <password|username|url|notes>"
          exit 0
        fi
        touch_session
        case "$FIELD" in
          password)
            val=$(pipe_password | keepassxc-cli show --show-protected "$VAULT_DB" "$ENTRY" 2>/dev/null \
              | grep -i "^Password:" | sed 's/^[^:]*: //')
            ;;
          username)
            val=$(pipe_password | keepassxc-cli show "$VAULT_DB" "$ENTRY" 2>/dev/null \
              | grep -i "^UserName:" | sed 's/^[^:]*: //')
            ;;
          url)
            val=$(pipe_password | keepassxc-cli show "$VAULT_DB" "$ENTRY" 2>/dev/null \
              | grep -i "^URL:" | sed 's/^[^:]*: //')
            ;;
          notes)
            val=$(pipe_password | keepassxc-cli show "$VAULT_DB" "$ENTRY" 2>/dev/null \
              | grep -i "^Notes:" | sed 's/^[^:]*: //')
            ;;
          *)
            echo "ERROR unknown field: $FIELD (use: password, username, url, notes)"
            exit 0
            ;;
        esac
        echo "OK $val"
        ;;

      *)
        echo "ERROR unknown command: $CMD"
        echo "Commands: PING UNLOCK <pw> LOCK STATUS LIST GET <entry> <field>"
        ;;
    esac
  '';

  autoLockScript = pkgs.writeShellScript "vault-auto-lock" ''
    SESSION_FILE="${sessionFile}"
    LOCK_FILE="${lockFile}"
    LOCK_TIMEOUT="${toString lockTimeout}"
    if [ -f "$SESSION_FILE" ] && [ ! -f "$LOCK_FILE" ]; then
      mtime=$(stat -c %Y "$SESSION_FILE" 2>/dev/null || echo 0)
      now=$(date +%s)
      age=$(( now - mtime ))
      if [ "$age" -gt "$LOCK_TIMEOUT" ]; then
        touch "$LOCK_FILE"
        logger "vault: auto-locked after ''${age}s idle"
      fi
    fi
  '';

in {
  microvm.vsock.cid = meta.vsockCid;

  # No network interface — vault stays fully offline
  microvm.interfaces = lib.mkForce [];
  networking.useDHCP = lib.mkForce false;
  networking.firewall.enable = lib.mkForce false;

  microvm.mem = lib.mkForce 512;

  # Vault data dir: virtiofs share of ~/vault/ on the host.
  # ~/vault/ already exists (git repo), gitsync mounts the same path.
  # No manual /var/lib setup needed; vault-cli pull populates it on new machines.
  microvm.shares = [{
    tag        = "vault-data";
    source     = "/home/${hostUsername}/vault";
    mountPoint = "${vaultDir}";
    proto      = "virtiofs";
  }];

  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  # Session tmpfs: cleared on reboot, inaccessible to host
  systemd.mounts = [{
    what    = "tmpfs";
    where   = "${sessionDir}";
    type    = "tmpfs";
    options = "size=1m,mode=755";
    wantedBy = [ "local-fs.target" ];
  }];

  # Fix session dir ownership so the vault user can write to it
  systemd.services.vault-setup = {
    description = "Vault session directory setup";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "run-vault-session.mount" "local-fs.target" ];
    before      = [ "vault-agent.service" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      chown vault:vault "${sessionDir}"
      chmod 700 "${sessionDir}"
    '';
  };

  # Auto-lock: checked every minute
  systemd.timers.vault-auto-lock = {
    description = "Vault auto-lock timer";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "1min";
      OnUnitActiveSec = "1min";
    };
  };

  systemd.services.vault-auto-lock = {
    description = "Vault auto-lock checker";
    serviceConfig = {
      Type    = "oneshot";
      ExecStart = "${autoLockScript}";
    };
  };

  # Main vsock agent — each connection handled by vaultHandler as vault user
  systemd.services.vault-agent = {
    description = "Vault vsock agent (port 14514)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" "vault-setup.service" ];
    serviceConfig = {
      Type       = "simple";
      Restart    = "always";
      RestartSec = "2s";
      ExecStart  = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14514,reuseaddr,fork EXEC:${vaultHandler},su=vault";
    };
  };

  users.users.vault = {
    isSystemUser = true;
    group        = "vault";
    home         = "/var/lib/vault";
  };
  users.groups.vault = {};

  services.getty.autologinUser = "root";

  environment.systemPackages = with pkgs; [ socat keepassxc coreutils gnugrep gnused ];

  users.motd = ''

  +-------------------------------------------------+
  |  HYDRIX VAULT VM                                |
  +-------------------------------------------------+
  |  Credential store — KeepassXC                   |
  |  vsock port 14514                               |
  |                                                 |
  |  From host:                                     |
  |    vault-cli unlock    Unlock vault             |
  |    vault-cli status    Show status              |
  |    Mod+Shift+P         Interactive picker       |
  +-------------------------------------------------+

  '';
}
