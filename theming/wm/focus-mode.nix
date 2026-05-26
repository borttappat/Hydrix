# Focus Mode
#
# Locks all VM keybindings to a single VM type regardless of workspace.
# Workspaces 1 (host) and 10 (router) are never overridden.
#
{ config, lib, pkgs, ... }:
let
  VM_REGISTRY = "/etc/hydrix/vm-registry.json";

  # Read valid VM types from registry at runtime; fall back to built-in list
  getValidTypes = ''
    VM_REGISTRY="${VM_REGISTRY}"
    if [[ -f "$VM_REGISTRY" ]]; then
      VALID_TYPES=$(${pkgs.jq}/bin/jq -r 'keys[]' "$VM_REGISTRY" 2>/dev/null | tr '\n' ' ')
    else
      VALID_TYPES="browsing pentest dev comms lurking"
    fi
  '';

  focus = pkgs.writeShellScriptBin "focus" ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    ${getValidTypes}

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

  buildMenu = ''
    FOCUS_FILE="$HOME/.cache/hydrix/focus-mode"
    current=""
    [[ -f "$FOCUS_FILE" ]] && current=$(cat "$FOCUS_FILE")
    ${getValidTypes}

    options=""
    for t in $VALID_TYPES off; do
        if [[ "$t" == "$current" ]] || { [[ "$t" == "off" ]] && [[ -z "$current" ]]; }; then
            options="''${options}★ $t\n"
        else
            options="''${options}  $t\n"
        fi
    done
  '';

  stripMarker = "${pkgs.gnused}/bin/sed 's/^★ //; s/^  //'";

  focus-rofi = pkgs.writeShellScriptBin "focus-rofi" ''
    ${buildMenu}
    selected=$(echo -e "$options" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "Focus" -theme-str 'window { width: 200px; }')
    [[ -z "$selected" ]] && exit 0
    selected=$(echo "$selected" | ${stripMarker})
    exec ${focus}/bin/focus "$selected"
  '';

  focus-wofi = pkgs.writeShellScriptBin "focus-wofi" ''
    ${buildMenu}
    selected=$(echo -e "$options" | ${pkgs.wofi}/bin/wofi --dmenu --insensitive --prompt "Focus" --width 200)
    [[ -z "$selected" ]] && exit 0
    selected=$(echo "$selected" | ${stripMarker})
    exec ${focus}/bin/focus "$selected"
  '';
in {
  config = lib.mkMerge [
    (lib.mkIf config.hydrix.i3.enable {
      environment.systemPackages = [ focus focus-rofi ];
    })
    (lib.mkIf config.hydrix.sway.enable {
      environment.systemPackages = [ focus focus-wofi ];
    })
    (lib.mkIf config.hydrix.hyprland.enable {
      environment.systemPackages = [ focus focus-wofi ];
    })
  ];
}
