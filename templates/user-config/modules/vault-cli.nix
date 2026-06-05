# vault-cli — vsock-backed KeepassXC CLI
#
# All operations go over vsock to microvm-vault (CID 213, port 14514).
# No local KeepassXC required on the host.
#
# Usage:
#   vault-cli unlock              Unlock vault (prompts for master password)
#   vault-cli lock                Lock vault
#   vault-cli status              Show LOCKED / UNLOCKED <count>
#   vault-cli list                List all entries
#   vault-cli get <entry> <field> Get field from entry (password/username/url/notes)
#   vault-cli sync                Commit + push vault DB to git via gitsync
#   vault-cli pull                Pull vault DB changes from git via gitsync
#   vault-cli ping                Check vault VM connectivity
{ config, lib, pkgs, ... }:
let
  cfg = config.hydrix.vault;

  vaultCli = pkgs.writeShellApplication {
    name = "vault-cli";
    runtimeInputs = with pkgs; [ socat coreutils ];
    text = ''
      CID="${toString cfg.vsockCid}"
      PORT="${toString cfg.vsockPort}"
      GITSYNC_CID="211"
      GITSYNC_PORT="14512"

      vsend() {
        echo "$1" | socat -T10 - "VSOCK-CONNECT:$CID:$PORT" 2>/dev/null
      }

      require_vault() {
        if ! echo "PING" | socat -T5 - "VSOCK-CONNECT:$CID:$PORT" 2>/dev/null | grep -q "PONG"; then
          echo "vault not configured — run: microvm start vault" >&2
          echo "See DOCUMENTATION.md §Vault VM for setup instructions." >&2
          exit 1
        fi
      }

      case "''${1:-}" in

        unlock)
          require_vault
          read -srp "Master password: " password
          echo
          result=$(printf '%s' "UNLOCK $password" | socat -T15 - "VSOCK-CONNECT:$CID:$PORT" 2>/dev/null)
          echo "$result"
          ;;

        lock)
          require_vault
          vsend "LOCK"
          ;;

        status)
          require_vault
          vsend "STATUS"
          ;;

        list)
          require_vault
          raw=$(vsend "LIST")
          first=$(echo "$raw" | head -1)
          if [ "$first" = "OK" ]; then
            echo "$raw" | tail -n +2
          else
            echo "$raw" >&2
            exit 1
          fi
          ;;

        get)
          require_vault
          if [ -z "''${2:-}" ] || [ -z "''${3:-}" ]; then
            echo "Usage: vault-cli get <entry> <password|username|url|notes>" >&2
            exit 1
          fi
          result=$(vsend "GET $2 $3")
          case "$result" in
            "OK "*)  echo "''${result#OK }" ;;
            OK)      echo "" ;;
            ERROR*)  echo "''${result#ERROR }" >&2; exit 1 ;;
            *)       echo "$result" >&2; exit 1 ;;
          esac
          ;;

        sync)
          echo "Syncing vault via gitsync VM..."
          echo "SYNC vault" | socat -T120 - "VSOCK-CONNECT:$GITSYNC_CID:$GITSYNC_PORT" 2>/dev/null
          ;;

        pull)
          echo "Pulling vault changes via gitsync VM..."
          echo "PULL vault" | socat -T120 - "VSOCK-CONNECT:$GITSYNC_CID:$GITSYNC_PORT" 2>/dev/null
          ;;

        ping)
          vsend "PING"
          ;;

        *)
          echo "Usage: vault-cli <command>"
          echo "Commands:"
          echo "  unlock            Unlock vault (prompts for master password)"
          echo "  lock              Lock vault"
          echo "  status            Show LOCKED / UNLOCKED <count>"
          echo "  list              List all entries"
          echo "  get <e> <field>   Get field (password|username|url|notes)"
          echo "  sync              Commit + push vault to git"
          echo "  pull              Pull vault from git"
          echo "  ping              Check vault VM connectivity"
          exit 1
          ;;
      esac
    '';
  };

in {
  options.hydrix.vault = {
    enable = lib.mkEnableOption "Vault VM credential integration";
    vsockCid = lib.mkOption {
      type    = lib.types.int;
      default = 213;
      description = "vsock CID of the vault VM";
    };
    vsockPort = lib.mkOption {
      type    = lib.types.int;
      default = 14514;
      description = "vsock port of the vault agent";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ vaultCli pkgs.socat ];
  };
}
