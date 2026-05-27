# vault-pick — Wayland-native KeepassXC credential picker
#
# Opens a floating Alacritty (class: vault-pick) that drives the vault VM
# over vsock. Credentials are copied to the Wayland clipboard by wl-copy on
# the host — they never enter any VM's display pipeline.
#
# Auto-clears clipboard after 30 seconds.
# Session: unlock once per session, auto-locked after 5 min idle in vault VM.
#
# Keybind: Mod+Shift+P → vault-pick
# Hyprland rule: float + fixed size for class vault-pick
{ config, lib, pkgs, ... }:
let
  cfg = config.hydrix.vault;

  vaultPickTui = pkgs.writeShellApplication {
    name = "vault-pick-tui";
    runtimeInputs = with pkgs; [ socat wofi wl-clipboard libnotify coreutils gnugrep gnused jq ];
    text = ''
      CID="${toString cfg.vsockCid}"
      PORT="${toString cfg.vsockPort}"
      CLEAR_DELAY=30
      SCALING_JSON="$HOME/.config/hydrix/scaling.json"
      WAL_JSON="$HOME/.cache/wal/colors.json"

      vsend() {
        echo "$1" | socat -T10 - "VSOCK-CONNECT:$CID:$PORT" 2>/dev/null
      }

      notify() {
        notify-send "Vault" "$1" -u "''${2:-normal}" -t "''${3:-3000}" 2>/dev/null || true
      }

      scaling_val() {
        local key="$1" default="$2"
        if [ -f "$SCALING_JSON" ]; then
          val=$(jq -r "$key // empty" "$SCALING_JSON" 2>/dev/null)
          echo "''${val:-$default}"
        else
          echo "$default"
        fi
      }

      wal_color() {
        local key="$1" fallback="$2"
        if [ -f "$WAL_JSON" ]; then
          val=$(jq -r "$key // empty" "$WAL_JSON" 2>/dev/null)
          echo "''${val:-$fallback}"
        else
          echo "$fallback"
        fi
      }

      build_theme() {
        local radius font_size font_name bg fg accent
        radius=$(scaling_val '.sizes.corner_radius' '8')
        font_size=$(scaling_val '.fonts.wofi' '13')
        font_name=$(scaling_val '.font_names.wofi' "$(scaling_val '.font_name' 'monospace')")
        bg=$(wal_color '.colors.color0' '#0e0f17')
        fg=$(wal_color '.colors.color7' '#e4d1ef')
        accent=$(wal_color '.colors.color4' '#f09ea2')
        cat <<EOF
* { font-family: ''${font_name}; font-size: ''${font_size}px; color: ''${fg}; }
#window { background-color: ''${bg}; border-radius: ''${radius}px; border: 0px solid transparent; }
#outer-box { padding: 8px; }
#input { background-color: transparent; border: none; border-bottom: 1px solid ''${accent}; border-radius: 0; padding: 4px 8px; margin-bottom: 4px; color: ''${fg}; }
#entry { padding: 6px 8px; border-radius: ''${radius}px; }
#entry:selected { background-color: ''${accent}; }
#text { color: ''${fg}; }
#text:selected { color: ''${bg}; }
EOF
      }

      THEME=$(mktemp /tmp/vault-pick-XXXXXX.css)
      trap 'rm -f "$THEME"' EXIT
      build_theme > "$THEME"

      wofi_dmenu() {
        wofi --show dmenu --style="$THEME" "$@" 2>/dev/null || true
      }

      # Quick reachability check before showing any UI
      if ! echo "PING" | socat -T5 - "VSOCK-CONNECT:$CID:$PORT" 2>/dev/null | grep -q "PONG"; then
        notify "Vault not configured — run: microvm start vault" critical 5000
        exit 1
      fi

      # Try LIST directly — handles locked/unreachable inline (avoids pre-flight PING+STATUS)
      unlock_and_list() {
        password=$(echo | wofi_dmenu \
          --password \
          --prompt "Vault password:" \
          --width 380 \
          --lines 0 \
          --hide-scroll)
        [ -z "$password" ] && exit 0

        result=$(printf '%s' "UNLOCK $password" | socat -T15 - "VSOCK-CONNECT:$CID:$PORT" 2>/dev/null)
        case "$result" in
          OK)     notify "Vault unlocked" low 2000 ;;
          ERROR*) notify "''${result#ERROR }" critical 4000; exit 1 ;;
          *)      notify "Vault VM unreachable" critical 4000; exit 1 ;;
        esac
        vsend "LIST"
      }

      raw=$(vsend "LIST")
      first=$(echo "$raw" | head -1)
      case "$first" in
        OK) ;;
        "ERROR vault is locked")
          raw=$(unlock_and_list)
          first=$(echo "$raw" | head -1)
          [ "$first" != "OK" ] && { notify "''${raw#ERROR }" normal 3000; exit 1; }
          ;;
        "")
          notify "Vault VM unreachable" critical 4000; exit 1 ;;
        *)
          notify "''${raw#ERROR }" normal 3000; exit 1 ;;
      esac
      entries=$(echo "$raw" | tail -n +2 | grep -v '^$')
      if [ -z "$entries" ]; then
        notify "Vault is empty" normal 3000; exit 1
      fi

      # Pick entry via wofi
      selected=$(echo "$entries" | wofi_dmenu --prompt "Entry:" --insensitive --width 500)
      [ -z "$selected" ] && exit 0

      # Pick action
      action=$(printf 'Copy Password\nCopy Username\nCopy URL\nCopy Notes' \
        | wofi_dmenu --prompt "$selected:" --width 300 --lines 4)
      [ -z "$action" ] && exit 0

      case "$action" in
        "Copy Password") field="password" ;;
        "Copy Username") field="username" ;;
        "Copy URL")      field="url"      ;;
        "Copy Notes")    field="notes"    ;;
        *) exit 0 ;;
      esac

      result=$(vsend "GET $selected $field")
      case "$result" in
        "OK "*) val="''${result#OK }" ;;
        OK)     notify "Field is empty" normal 2000; exit 0 ;;
        ERROR*) notify "''${result#ERROR }" normal 3000; exit 1 ;;
        *)      notify "Unexpected response" normal 3000; exit 1 ;;
      esac

      # Copy to Wayland clipboard — host side only, never touches VM clipboard
      printf '%s' "$val" | wl-copy
      notify "Copied to clipboard (clears in ${toString 30}s)" low 2000

      # Auto-clear in background after 30 seconds
      (
        sleep "$CLEAR_DELAY"
        current=$(wl-paste 2>/dev/null || true)
        if [ "$current" = "$val" ]; then
          wl-copy --clear 2>/dev/null || true
        fi
      ) &
      disown
    '';
  };

  vaultPick = pkgs.writeShellScriptBin "vault-pick" ''
    exec vault-pick-tui
  '';

in {
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ vaultPick vaultPickTui pkgs.wl-clipboard ];
  };
}
