# Passwords (hydrix.passwords): one frontend over a choice of backends.
#
#   backend = "vm"    the vault VM's agent over vsock (hydrix.vault.agent); KeePassXC and the
#                     decrypted database never run in the host session
#   backend = "host"  keepassxc-cli on the host against `database`
#   backend = "none"  nothing installed (bring your own password manager)
#
# Both backends speak the same protocol (shared/vault/backend.py), so the frontends only
# differ in where `vault_call` sends a request:
#   vault        fzf TUI (no arguments) and scriptable subcommands
#   vault-pick   the same TUI in a floating terminal (Mod+P); copies after it closes, into
#                the window that was focused (see vaultPick)
# Copies go to the host clipboard with wl-copy --sensitive and are cleared after
# clipboardClear seconds if the clipboard still holds them (compared by hash, so the
# background clearer never holds the secret).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.passwords;
  backend = import ../shared/vault/package.nix {inherit pkgs;};
  user = config.hydrix.username;

  # Shared shell library (inlined into both scripts so shellcheck sees it): the
  # request/reply protocol and clipboard handling.
  libText = ''
    VAULT_BACKEND=${cfg.backend}
    VAULT_CID=${toString cfg.vmCid}
    VAULT_PORT=${toString config.hydrix.networking.vsockPorts.vaultAgent}
    VAULT_DB=${lib.escapeShellArg cfg.database}
    VAULT_TIMEOUT=${toString cfg.lockTimeout}
    VAULT_CLEAR=${toString cfg.clipboardClear}

    vault_b64() { printf '%s' "$1" | base64 -w0; }
    # "-" is an empty field.
    vault_unb64() { [ "$1" = - ] || printf '%s' "$1" | base64 -d 2>/dev/null; }

    # vault_call VERB [ARG...]: one request, reply on stdout (first line OK or ERROR ...).
    vault_call() {
      local req="$1" a
      shift
      for a in "$@"; do req+=" $(vault_b64 "$a")"; done
      if [ "$VAULT_BACKEND" = vm ]; then
        local out
        out=$(printf '%s\n' "$req" | socat -t60 -T60 - "VSOCK-CONNECT:$VAULT_CID:$VAULT_PORT" 2>/dev/null) || true
        case "''${out%%$'\n'*}" in
          "") out="ERROR vault VM unreachable (shard -s vault)" ;;
          OK | "ERROR "*) ;;
          *) out="ERROR the vault VM runs an older agent (shard -bR vault)" ;;
        esac
        printf '%s\n' "$out"
      else
        [ -d "''${XDG_RUNTIME_DIR:?}/hydrix-vault" ] || mkdir -m 700 "$XDG_RUNTIME_DIR/hydrix-vault"
        printf '%s\n' "$req" | hydrix-vault-backend --db "$VAULT_DB" \
          --session-file "$XDG_RUNTIME_DIR/hydrix-vault/session" --timeout "$VAULT_TIMEOUT"
      fi
    }

    # fzf colours from the wal palette, the same mapping as fish's FZF_DEFAULT_OPTS
    # (Hydrix theming/programs/fish.nix); set here because floating TUIs start without fish.
    wal_fzf_colors() {
      [ -n "''${FZF_DEFAULT_OPTS:-}" ] && return 0
      local c="$HOME/.cache/wal/colors.json"
      [ -r "$c" ] || return 0
      FZF_DEFAULT_OPTS=$(jq -r '.colors | "--color=fg:\(.color7),bg:-1,hl:\(.color4),fg+:\(.color7),bg+:\(.color8),hl+:\(.color4),info:\(.color6),prompt:\(.color4),pointer:\(.color5),marker:\(.color3),spinner:\(.color6),header:\(.color8),border:\(.color8),label:\(.color4)"' "$c" 2>/dev/null) || FZF_DEFAULT_OPTS=""
      export FZF_DEFAULT_OPTS
    }

    # vault_copy VALUE LABEL: copy, notify, clear later if unchanged.
    vault_copy() {
      local val="$1" label="$2" sum
      # wl-copy forks a server for the clipboard; detach it from the caller's pipes.
      printf '%s' "$val" | wl-copy --sensitive >/dev/null 2>&1
      sum=$(printf '%s' "$val" | sha256sum | cut -d' ' -f1)
      notify-send -a vault -t 2000 "Vault" "$label copied (clears in ''${VAULT_CLEAR}s)" 2>/dev/null || true
      # timeout: an unresponsive clipboard owner is not our wl-copy, so leave it alone.
      setsid -f bash -c 'sleep "$1"; cur=$(timeout 2 wl-paste -n 2>/dev/null | sha256sum | cut -d" " -f1)
        [ "$cur" = "$2" ] && wl-copy --clear' _ "$VAULT_CLEAR" "$sum" >/dev/null 2>&1
    }
  '';

  runtime = with pkgs; [socat wl-clipboard libnotify coreutils util-linux gnugrep fzf jq bash] ++ lib.optional (cfg.backend == "host") backend;

  vault = pkgs.writeShellApplication {
    name = "vault";
    runtimeInputs = runtime;
    excludeShellChecks = ["SC2016"];
    text =
      libText
      + ''
        self=$(readlink -f "$0")

        die() { echo "vault: $*" >&2; exit 1; }
        # reply_ok REPLY: fail on ERROR, print the data lines.
        reply_ok() {
          local first rest
          first=''${1%%$'\n'*}
          [ "$first" = OK ] || die "''${first#ERROR }"
          rest=''${1#OK}
          rest=''${rest#$'\n'}
          [ -z "$rest" ] || printf '%s\n' "$rest"
        }

        ensure_unlocked() {
          local st pw pw2 r
          st=$(vault_call STATUS)
          [ "''${st%%$'\n'*}" = OK ] || die "''${st#ERROR }"
          case "$st" in *UNLOCKED*) return 0 ;; esac
          read -rsp "Master password: " pw; echo >&2
          r=$(vault_call UNLOCK "$pw")
          if [ "''${r%%$'\n'*}" != OK ] && [[ "$r" == *"no database yet"* ]]; then
            read -rsp "No database yet. Repeat the password to create one: " pw2; echo >&2
            [ "$pw" = "$pw2" ] || die "passwords differ"
            r=$(vault_call INIT "$pw")
          fi
          unset pw pw2
          reply_ok "$r" >/dev/null
        }

        rows() {
          local out path title user url
          out=$(reply_ok "$(vault_call LIST)") || exit 1
          while read -r path title user url; do
            [ -n "$path" ] || continue
            printf '%s\t%s\t%s\n' "$(vault_unb64 "$path")" "$(vault_unb64 "$user")" "$(vault_unb64 "$url")"
          done <<< "$out"
          : "$title"
        }

        # Failures must stop here: an error inside "$(...)" as an argument would not.
        get() {
          local r
          r=$(reply_ok "$(vault_call GET "$1" "''${2:-password}")") || exit 1
          vault_unb64 "$r"
        }

        prompt() { local v; read -rp "$1" v; printf '%s' "$v"; }

        usage() {
          cat <<USAGE
        usage: vault                     interactive (fzf)
               vault status|unlock|lock
               vault ls
               vault get PATH [FIELD]    print a field (password username url notes totp)
               vault copy PATH [FIELD]   copy a field, cleared after ''${VAULT_CLEAR}s
               vault add [PATH]          prompts; empty password = generated
               vault edit PATH [FIELD]
               vault mv PATH NEWPATH     rename or move to another group
               vault rm PATH             to the recycle bin
               vault gen [LENGTH]
        USAGE
        }

        cmd=''${1:-}
        [ $# -gt 0 ] && shift
        case "$cmd" in
          "" | --pick)
            # --pick FILE (vault-pick): write the chosen entry path and field, not the
            # secret, to FILE and quit; vault-pick refocuses the previous window and copies.
            pick=""
            [ "$cmd" = --pick ] && pick=''${1:?usage: vault --pick FILE}
            ensure_unlocked
            SHELL=$(command -v bash)
            export SHELL
            wal_fzf_colors
            help='enter password · ctrl-u username · ctrl-o url · esc quit
          ctrl-a add · ctrl-e edit · ctrl-r move · ctrl-d delete · ctrl-g generate · ctrl-l lock'
            out=$(rows | fzf --delimiter '\t' --with-nth 1,2,3 --layout reverse --border=rounded \
              --border-label=' vault ' --prompt='> ' --info=hidden --pointer='>' --cycle \
              --header="$help" --header-first \
              --expect=enter,ctrl-u,ctrl-o \
              --bind "ctrl-a:execute($self add)+reload($self _rows)" \
              --bind "ctrl-e:execute($self edit {1})+reload($self _rows)" \
              --bind "ctrl-r:execute($self mv {1})+reload($self _rows)" \
              --bind "ctrl-d:execute($self rm {1})+reload($self _rows)" \
              --bind "ctrl-g:execute-silent($self gen | wl-copy --sensitive >/dev/null 2>&1; $self _note 'Generated password copied')" \
              --bind "ctrl-l:execute-silent($self lock)+abort" \
              --bind 'esc:abort,ctrl-c:abort') || exit 0
            # fzf prints the key, then the selected line; no line means nothing matched.
            [[ "$out" == *$'\n'* ]] || exit 0
            key=''${out%%$'\n'*}
            line=''${out#*$'\n'}
            path=''${line%%$'\t'*}
            [ -n "$path" ] || exit 0
            case "$key" in
              ctrl-u) field=username ;;
              ctrl-o) field=url ;;
              *) field=password ;;
            esac
            if [ -n "$pick" ]; then
              printf '%s\n%s\n' "$path" "$field" > "$pick"
            else
              "$self" copy "$path" "$field"
            fi
            ;;
          _rows) rows ;;
          _note) notify-send -a vault -t 2000 Vault "$1" 2>/dev/null || true ;;
          status) reply_ok "$(vault_call STATUS)" ;;
          unlock) ensure_unlocked ;;
          lock) reply_ok "$(vault_call LOCK)" ;;
          ls) ensure_unlocked; rows ;;
          get)
            [ $# -ge 1 ] || die "usage: vault get PATH [FIELD]"
            ensure_unlocked
            val=$(get "$1" "''${2:-password}") || exit 1
            printf '%s\n' "$val"
            ;;
          copy)
            [ $# -ge 1 ] || die "usage: vault copy PATH [FIELD]"
            ensure_unlocked
            val=$(get "$1" "''${2:-password}") || exit 1
            [ -n "$val" ] || die "that field is empty"
            vault_copy "$val" "''${2:-password}"
            unset val
            ;;
          add)
            ensure_unlocked
            path=''${1:-$(prompt "Path (Group/Title): ")}
            username=$(prompt "Username: ")
            url=$(prompt "URL: ")
            notes=$(prompt "Notes: ")
            read -rsp "Password (empty = generate): " pw; echo
            out=$(reply_ok "$(vault_call ADD "$path" "$username" "$url" "$notes" "$pw")")
            unset pw
            if [ -n "$out" ]; then vault_copy "$(vault_unb64 "$out")" "generated password"; fi
            echo "Added $path"
            ;;
          edit)
            [ $# -ge 1 ] || die "usage: vault edit PATH [FIELD]"
            ensure_unlocked
            field=''${2:-$(printf 'password\nusername\nurl\nnotes\ntitle\n' | fzf --prompt "field> " --height 8)}
            [ -n "$field" ] || exit 0
            if [ "$field" = password ]; then
              read -rsp "New password: " val; echo
            else
              val=$(prompt "New $field: ")
            fi
            reply_ok "$(vault_call EDIT "$1" "$field" "$val")"
            unset val
            ;;
          mv)
            [ $# -ge 1 ] || die "usage: vault mv PATH NEWPATH"
            ensure_unlocked
            new=''${2:-$(prompt "New path for $1: ")}
            [ -n "$new" ] || exit 0
            reply_ok "$(vault_call MOVE "$1" "$new")"
            ;;
          rm)
            [ $# -ge 1 ] || die "usage: vault rm PATH"
            ensure_unlocked
            read -rp "Move '$1' to the recycle bin? [y/N] " a
            [[ "$a" == [yY]* ]] || exit 0
            reply_ok "$(vault_call RM "$1")"
            ;;
          gen)
            out=$(reply_ok "$(vault_call GEN "''${1:-32}")") || exit 1
            printf '%s\n' "$(vault_unb64 "$out")"
            ;;
          sync) die "sync is not set up yet (plans/vault-rework.md, Step 5)" ;;
          -h | --help | help) usage ;;
          *) usage; exit 1 ;;
        esac
      '';
  };

  # Mod+P: the vault TUI in a floating terminal. The copy happens after it closes and the
  # previously focused window has focus again, so hypr-clip-guard locks the secret to that
  # window's group (a copy made while the vault window has focus would lock to the host).
  vaultPick = pkgs.writeShellApplication {
    name = "vault-pick";
    runtimeInputs = [pkgs.jq pkgs.coreutils vault];
    # $1 in the bash -c string is the inner shell's argument, not this script's.
    excludeShellChecks = ["SC2016"];
    text = ''
      prev=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')
      sel=$(mktemp -p "''${XDG_RUNTIME_DIR:?}" vault-pick.XXXXXX)
      trap 'rm -f "$sel"' EXIT
      # On an error the window stays until a key is pressed, so the message can be read.
      alacritty --class hypr-float --title vault -e bash -c \
        'vault --pick "$1" || { echo; read -rsn1 -p "Press any key to close"; }' _ "$sel" || true
      [ -s "$sel" ] || exit 0
      { read -r path; read -r field; } < "$sel"
      rm -f "$sel"
      if [ -n "$prev" ]; then
        hyprctl dispatch focuswindow "address:$prev" >/dev/null 2>&1 || true
        for _ in $(seq 20); do
          [ "$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')" = "$prev" ] && break
          sleep 0.05
        done
      fi
      vault copy "$path" "$field"
    '';
  };
in {
  options.hydrix.passwords = {
    backend = lib.mkOption {
      type = lib.types.enum ["none" "host" "vm"];
      default = "none";
      description = ''
        Where the KeePassXC database is opened: "vm" (the vault VM, hydrix.vault.agent),
        "host" (keepassxc-cli in the host session) or "none" (no Hydrix password frontend).
      '';
    };
    database = lib.mkOption {
      type = lib.types.str;
      default = "/home/${user}/vault/Passwords.kdbx";
      description = "Database path for the host backend (the vault VM sees the same directory as /var/lib/vault).";
    };
    vmCid = lib.mkOption {
      type = lib.types.int;
      default = 213;
      description = "vsock CID of the vault VM (backend = \"vm\").";
    };
    lockTimeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds idle before the host backend's session is deleted (the vault VM has its own, hydrix.vault.agent.lockTimeout).";
    };
    clipboardClear = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Seconds before a copied secret is cleared from the clipboard, if still there.";
    };
  };

  config = lib.mkIf (cfg.backend != "none") {
    environment.systemPackages = [vault vaultPick];
    systemd.tmpfiles.rules = ["d /home/${user}/vault 0755 ${user} users -"];
  };
}
