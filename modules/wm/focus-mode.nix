# Focus Mode
#
# Locks all VM keybindings to a single VM type regardless of workspace.
# Workspaces 1 (host) and 10 (router) are never overridden.
#
{ pkgs, ... }:
let
  validTypes = "browsing pentest dev comms lurking";

  focus = pkgs.writeShellScriptBin "focus" ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    VALID_TYPES="${validTypes}"

    case "''${1:-status}" in
        off)
            rm -f "$FOCUS_FILE"
            ${pkgs.libnotify}/bin/notify-send -t 3000 "Focus Mode" "Disabled — normal workspace routing"
            ;;
        status)
            if [[ -f "$FOCUS_FILE" ]]; then
                echo "Focus mode: $(cat "$FOCUS_FILE")"
            else
                echo "Focus mode: off"
            fi
            ;;
        *)
            # Validate type
            valid=false
            for t in $VALID_TYPES; do
                if [[ "$1" == "$t" ]]; then
                    valid=true
                    break
                fi
            done
            if ! $valid; then
                echo "Unknown type: $1"
                echo "Valid types: $VALID_TYPES off"
                exit 1
            fi
            mkdir -p "$(dirname "$FOCUS_FILE")"
            echo "$1" > "$FOCUS_FILE"
            ${pkgs.libnotify}/bin/notify-send -t 3000 "Focus Mode" "Locked to: $1"
            ;;
    esac
  '';

  focus-rofi = pkgs.writeShellScriptBin "focus-rofi" ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    current=""
    [[ -f "$FOCUS_FILE" ]] && current=$(cat "$FOCUS_FILE")

    # Build menu with marker for active
    options=""
    for t in ${validTypes} off; do
        if [[ "$t" == "$current" ]] || { [[ "$t" == "off" ]] && [[ -z "$current" ]]; }; then
            options="''${options}★ $t\n"
        else
            options="''${options}  $t\n"
        fi
    done

    selected=$(echo -e "$options" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "Focus" -theme-str 'window { width: 200px; }')
    [[ -z "$selected" ]] && exit 0

    # Strip marker prefix
    selected=$(echo "$selected" | ${pkgs.gnused}/bin/sed 's/^★ //; s/^  //')

    exec ${focus}/bin/focus "$selected"
  '';
in {
  environment.systemPackages = [ focus focus-rofi ];
}
