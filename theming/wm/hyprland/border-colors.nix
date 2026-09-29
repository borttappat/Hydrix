# Active-border color logic shared by hypr-focus-daemon (window borders) and
# swaync (notification borders), so a notification from a VM carries the same
# gradient as that VM's windows.
#
# Sourced as a shell library. Every border is a gradient from a first stop to
# focusDaemon.baseColor at focusDaemon.gradientAngle:
#   host        -> hostColor
#   VM          -> its registry focusBorder, or its dynamicColorMap key when
#                  hydrix-focus is on (marker file present) or it has none
#   task slots  -> their base profile (pentest-task1 -> pentest)
# Colors are rrggbbaa without '#'.
{
  config,
  lib,
  pkgs,
}: let
  focusCfg = config.hydrix.vmThemeSync.focusDaemon;
  dynamicMapCases = lib.concatStringsSep "\n    " (
    lib.mapAttrsToList (vm: colorKey: "${vm}) key=\"${colorKey}\" ;;") focusCfg.dynamicColorMap
  );
in
  pkgs.writeText "hydrix-border-colors.sh" ''
    # shellcheck shell=bash disable=SC2034
    BORDER_REGISTRY=/etc/hydrix/vm-registry.json
    BORDER_MARKER="$HOME/.cache/hydrix/focus-override-active"
    BORDER_WAL="$HOME/.cache/wal/colors.json"
    BORDER_ANGLE="${toString focusCfg.gradientAngle}deg"

    _rgba() {
      case "$1" in
        red) echo "ff0000ff" ;; orange) echo "ff8c00ff" ;; yellow) echo "ffff00ff" ;;
        green) echo "00ff00ff" ;; cyan) echo "00ffffff" ;; blue) echo "0000ffff" ;;
        purple) echo "800080ff" ;; pink) echo "ffc0cbff" ;; magenta) echo "ff00ffff" ;;
        white) echo "ffffffff" ;; black) echo "000000ff" ;; gray|grey) echo "808080ff" ;;
        *) hex="''${1#\#}"; [[ "''${#hex}" -eq 6 ]] && echo "''${hex}ff" || echo "$hex" ;;
      esac
    }
    # Wal color key -> rrggbbaa, or the fallback when the key is missing.
    _wal() {
      local c
      c=$(${pkgs.jq}/bin/jq -r --arg k "$1" '.colors[$k] // empty' "$BORDER_WAL" 2>/dev/null \
        | ${pkgs.gnused}/bin/sed 's/#//')
      [ -n "$c" ] && echo "''${c}ff" || echo "''${2:-7aa2f7ff}"
    }
    _border_base() { _wal ${focusCfg.baseColor}; }
    _border_host() { _wal ${focusCfg.hostColor}; }
    _border_dynamic() {
      local key=""
      case "''${1%-task[0-9]*}" in
      ${dynamicMapCases}
      *) key="${focusCfg.baseColor}" ;;
      esac
      _wal "$key"
    }
    # First gradient stop for a VM (registry key).
    _border_vm() {
      local c
      if [ -f "$BORDER_MARKER" ]; then _border_dynamic "$1"; return; fi
      c=$(${pkgs.jq}/bin/jq -r --arg p "$1" '.[$p].focusBorder // empty' "$BORDER_REGISTRY" 2>/dev/null)
      if [ -n "$c" ]; then _rgba "$c"; else _border_dynamic "$1"; fi
    }
  ''
