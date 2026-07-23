# Hyprland Home Manager Configuration — Framework Layer
#
# Config files are written as plain writable files via home.activation so the
# user can edit them live between rebuilds. Rebuild always overwrites with the
# current Nix values.
#
# Split:
#   ~/.config/hypr/hydrix-generated.conf  — framework layer, always regenerated
#       colors preamble, monitor, keyboard (from options), framework exec-once, VM rules
#   ~/.config/hypr/hyprland.conf          — user layer, editable freely
#       sources hydrix-generated.conf; rest written by shared/hyprland.nix
#   ~/.config/hypr/hyprlock.conf          — lockscreen, editable freely
#       written by shared/hyprland.nix
#
# Keyboard layout is driven by hydrix.graphical.keyboard options — set in machines/<serial>.nix.
# VM window routing and border colors are generated from hydrix.networking.vmRegistry at build time.
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  cfg = config.hydrix.graphical;
  sc = config.hydrix.graphical.scaling.computed;

  gaps = config.hydrix.graphical.ui.gaps or 10;

  clipGuardPlugin = pkgs.hyprlandPlugins.mkHyprlandPlugin {
    pluginName = "hypr-clip-guard";
    version = "0.1.0";
    src = ./plugins/hypr-clip-guard;
    nativeBuildInputs = [ pkgs.cmake ];
    meta.description = "VM clipboard isolation for Hyprland";
    meta.license = lib.licenses.mit;
  };

  hyprMonitorLine = let
    out = cfg.scaling.hyprInternalOutput or "eDP-1";
    scale = cfg.scaling.hyprInternalScale or null;
  in
    lib.optionalString (scale != null)
    "monitor = ${out}, preferred, 0x0, ${toString scale}";

  vmRegistry = config.hydrix.networking.vmRegistry or {};
  vmWindowRules = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (key: v:
      lib.optionalString ((v.hasDisplay or true) && v.workspace != null)
      "windowrule = workspace ${toString v.workspace}, match:title ^\\[${key}\\]")
    vmRegistry
  );

  namedColorToRgba = name: let
    table = {
      "red" = "ff0000ff"; "orange" = "ff8c00ff"; "yellow" = "ffff00ff";
      "green" = "00ff00ff"; "cyan" = "00ffffff"; "blue" = "0000ffff";
      "purple" = "800080ff"; "pink" = "ffc0cbff"; "magenta" = "ff00ffff";
      "white" = "ffffffff"; "black" = "000000ff"; "gray" = "808080ff"; "grey" = "808080ff";
    };
  in
    table.${name} or "${lib.removePrefix "#" name}ff";

  vmBorderColorRules = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (key: v:
      lib.optionalString (
        (v.hasDisplay or true)
        && v.workspace != null
        && (v ? focusBorder)
        && v.focusBorder != null
      )
      "windowrule = border_color rgba(${namedColorToRgba (v.focusBorder or "")}), match:title ^\\[${key}\\]")
    vmRegistry
  );

  workspaceColors = config.hydrix.hyprland.workspaceColors;
  workspaceColorRules = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (ws: color:
      "windowrule = border_color rgba(${color}), match:workspace ${ws}")
    workspaceColors
  );

  dynamicColorMap = config.hydrix.vmThemeSync.focusDaemon.dynamicColorMap;
  dynamicMapCases = lib.concatStringsSep "\n      " (
    lib.mapAttrsToList (vm: colorKey: "${vm}) WAL_KEY=\"${colorKey}\" ;;") dynamicColorMap
  );

  xwaylandEnabled = config.hydrix.hyprland.xwayland.enable;

  # ── Generated config file (framework layer) ───────────────────────────────
  # Always regenerated on rebuild. User should not edit this file — edit hyprland.conf instead.
  hyprlandGeneratedConf = pkgs.writeText "hypr-hydrix-generated.conf" ''
    # ── Colors (written at runtime by hypr-apply-colors from wal) ────────────
    # Fallback values used on first boot before colors.conf exists.
    $activeBorder   = rgba(7aa2f7ff)
    $inactiveBorder = rgba(1a1b26aa)
    source = ~/.config/hypr/colors.conf

    # ── Monitor ──────────────────────────────────────────────────────────────
    ${hyprMonitorLine}
    monitor = ,preferred,auto,1

    # ── Clipboard isolation plugin ───────────────────────────────────────────
    plugin = ${clipGuardPlugin}/lib/hypr-clip-guard.so

    # ── Framework services (VM integration) ──────────────────────────────────
    # Export HYPRLAND_INSTANCE_SIGNATURE to systemd so hypr-vm-borders-init
    # and other WantedBy services can call hyprctl without needing exec-once.
    exec-once = systemctl --user set-environment HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE
    exec-once = hypr-focus-daemon
    exec-once = vm-push-display-mode
    exec-once = waypipe-connect-all

    # ── VM window routing (generated from vmRegistry) ─────────────────────────
    ${vmWindowRules}

    # ── Per-workspace active border color overrides ───────────────────────────
    ${workspaceColorRules}

    # ── Per-VM border colors at window creation (from vmRegistry.focusBorder) ──
    ${vmBorderColorRules}

    # ── Misc ───────────────────────────────────────────────────────────────────
    misc {
      disable_hyprland_logo    = true
      disable_splash_rendering = true
      background_color         = 0xff000000
    }

    ${lib.optionalString xwaylandEnabled ''
    # ── XWayland (hydrix.hyprland.xwayland.enable) ───────────────────────────
    # Render XWayland apps at physical resolution rather than logical resolution.
    # Needed for apps (Steam, games) that work better under XWayland — without
    # this, fractional scaling causes them to render at the lower logical size.
    xwayland {
      force_zero_scaling = true
    }

    # Disable blur and restore full opacity for Steam game windows and any
    # fullscreen surface — avoids compositor overhead on those frames.
    windowrule = no_blur 1, match:class ^(steam_app_.*)$
    windowrule = opacity 1.0 override, match:class ^(steam_app_.*)$
    windowrule = no_blur 1, match:fullscreen 1
    windowrule = opacity 1.0 override, match:fullscreen 1
    ''}
  '';

  # ── Scripts ──────────────────────────────────────────────────────────────────

  hyprlandGapsAdjust = pkgs.writeShellScriptBin "hyprland-gaps-adjust" ''
    TYPE="$1" DIR="$2" AMT="''${3:-5}"
    case "$TYPE" in
      inner) KEY="general:gaps_in"  ; STATE="$HOME/.config/hypr/gaps-inner" ;;
      outer) KEY="general:gaps_out" ; STATE="$HOME/.config/hypr/gaps-outer" ;;
      *) exit 1 ;;
    esac
    CURRENT=$(cat "$STATE" 2>/dev/null || echo "0")
    case "$DIR" in
      plus)  NEW=$((CURRENT + AMT)) ;;
      minus) NEW=$(( CURRENT - AMT < 0 ? 0 : CURRENT - AMT )) ;;
      *) exit 1 ;;
    esac
    echo "$NEW" > "$STATE"
    ${pkgs.hyprland}/bin/hyprctl keyword "$KEY" "$NEW"
  '';

  hyprApplyColors = pkgs.writeShellScriptBin "hypr-apply-colors" ''
    WAL="$HOME/.cache/wal/colors.sh"
    HYPR_OUT="$HOME/.config/hypr/colors.conf"
    BAR_OUT="$HOME/.config/waybar/colors.css"

    if [ -f "$WAL" ]; then
      . "$WAL"
    else
      color0="#0c0c0c"; color1="#bf616a"; color2="#88c0d0"; color4="#7aa2f7"; color6="#5e81ac"; color7="#d8dee9"; color8="#4c566a"
    fi

    mkdir -p "$(dirname "$HYPR_OUT")"
    printf '$activeBorder = rgba(%sff)\n$inactiveBorder = rgba(%s88)\n' \
      "''${color4#\#}" "''${color0#\#}" > "$HYPR_OUT"

    mkdir -p "$(dirname "$BAR_OUT")"
    printf '@define-color background %s;\n' "$color0" > "$BAR_OUT"
    printf '@define-color foreground %s;\n' "$color7" >> "$BAR_OUT"
    printf '@define-color accent     %s;\n' "$color4" >> "$BAR_OUT"
    printf '@define-color alert      %s;\n' "$color1" >> "$BAR_OUT"
    printf '@define-color color6     %s;\n' "$color6" >> "$BAR_OUT"
    printf '@define-color color8     %s;\n' "$color8" >> "$BAR_OUT"
    printf '@define-color color1     %s;\n' "$color1" >> "$BAR_OUT"
    printf '@define-color color2     %s;\n' "$color2" >> "$BAR_OUT"
    printf '@define-color color4     %s;\n' "$color4" >> "$BAR_OUT"

    LOCK_OUT="$HOME/.config/hypr/colors-lock.conf"
    mkdir -p "$(dirname "$LOCK_OUT")"
    printf '$lockBg = rgba(%sff)\n$lockFg = rgba(%sff)\n$lockAccent = rgba(%sff)\n$lockWrong = rgba(%sff)\n' \
      "''${color0#\#}" "''${color7#\#}" "''${color4#\#}" "''${color1#\#}" > "$LOCK_OUT"

    ${pkgs.hyprland}/bin/hyprctl reload 2>/dev/null || true
    ${pkgs.procps}/bin/pkill -SIGUSR2 waybar 2>/dev/null || true
  '';

  hydrixBrightnessHypr = pkgs.writeShellScriptBin "hydrix-brightness-hypr" ''
    STEP=10
    MONITOR=$(${pkgs.hyprland}/bin/hyprctl monitors -j \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .name')
    if [ -z "$MONITOR" ]; then exit 1; fi
    if [[ "$MONITOR" == eDP-* ]]; then
      case "$1" in
        +) ${pkgs.brightnessctl}/bin/brightnessctl set +''${STEP}% ;;
        -) ${pkgs.brightnessctl}/bin/brightnessctl set ''${STEP}%- ;;
        *) exit 1 ;;
      esac
    else
      DISPLAY_NUM=$(${pkgs.ddcutil}/bin/ddcutil detect --brief 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -E "^Display [0-9]+" \
        | while IFS= read -r line; do
            NUM=$(echo "$line" | grep -oE "[0-9]+")
            DRMSYS=$(ls /sys/class/drm/card*-"$MONITOR" 2>/dev/null | head -1 || true)
            [ -n "$DRMSYS" ] && echo "$NUM" && break
          done)
      if [ -z "$DISPLAY_NUM" ]; then exit 1; fi
      case "$1" in
        +) ${pkgs.ddcutil}/bin/ddcutil --display "$DISPLAY_NUM" setvcp 10 + $STEP ;;
        -) ${pkgs.ddcutil}/bin/ddcutil --display "$DISPLAY_NUM" setvcp 10 - $STEP ;;
        *) exit 1 ;;
      esac
    fi
  '';

  hydrixVibrancyHypr = pkgs.writeShellScriptBin "hydrix-vibrancy-hypr" ''
    STEP=5
    STATE_DIR="$HOME/.cache/hydrix"
    STATE_FILE="$STATE_DIR/vibrancy"
    SHADER_FILE="$STATE_DIR/vibrancy.glsl"
    MONITOR=$(${pkgs.hyprland}/bin/hyprctl monitors -j \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .name')
    [ -z "$MONITOR" ] && exit 1
    if [[ "$MONITOR" != eDP-* ]]; then
      DISPLAY_NUM=$(${pkgs.ddcutil}/bin/ddcutil detect --brief 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -E "^Display [0-9]+" \
        | while IFS= read -r line; do
            NUM=$(echo "$line" | grep -oE "[0-9]+")
            DRMSYS=$(ls /sys/class/drm/card*-"$MONITOR" 2>/dev/null | head -1 || true)
            [ -n "$DRMSYS" ] && echo "$NUM" && break
          done)
      if [ -n "$DISPLAY_NUM" ]; then
        case "$1" in
          +) ${pkgs.ddcutil}/bin/ddcutil --display "$DISPLAY_NUM" setvcp 8A + $STEP 2>/dev/null && exit 0 ;;
          -) ${pkgs.ddcutil}/bin/ddcutil --display "$DISPLAY_NUM" setvcp 8A - $STEP 2>/dev/null && exit 0 ;;
          *) exit 1 ;;
        esac
      fi
    fi
    mkdir -p "$STATE_DIR"
    CURRENT=$(cat "$STATE_FILE" 2>/dev/null); : "''${CURRENT:=100}"
    case "$1" in
      +) NEW=$(( CURRENT + STEP * 2 )) ;;
      -) NEW=$(( CURRENT - STEP * 2 )) ;;
      *) exit 1 ;;
    esac
    [ "$NEW" -lt 0 ] && NEW=0; [ "$NEW" -gt 200 ] && NEW=200
    echo "$NEW" > "$STATE_FILE"
    SAT=$(${pkgs.gawk}/bin/awk "BEGIN { printf \"%.4f\", $NEW / 100.0 }")
    cat > "$SHADER_FILE" <<'GLSL'
#version 300 es
precision mediump float;
in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;
void main() {
    vec4 col = texture(tex, v_texcoord);
    float luma = dot(col.rgb, vec3(0.299, 0.587, 0.114));
    col.rgb = mix(vec3(luma), col.rgb, SAT_VALUE);
    fragColor = col;
}
GLSL
    ${pkgs.gnused}/bin/sed -i "s/SAT_VALUE/$SAT/" "$SHADER_FILE"
    if [ "$NEW" -eq 100 ]; then
      ${pkgs.hyprland}/bin/hyprctl keyword decoration:screen_shader "" >/dev/null 2>&1
    else
      ${pkgs.hyprland}/bin/hyprctl keyword decoration:screen_shader "$SHADER_FILE" >/dev/null 2>&1
    fi
    ${pkgs.libnotify}/bin/notify-send "Vibrancy" "Saturation: $NEW%" --urgency=low
  '';

  hyprVmBorders = pkgs.writeShellScriptBin "hypr-vm-borders" ''
    REGISTRY=/etc/hydrix/vm-registry.json
    CONF=$HOME/.config/hypr/vm-borders.conf
    STATE=$HOME/.config/hypr/vm-borders-enabled
    _rgba() {
      case "$1" in
        red) echo "ff0000ff" ;; orange) echo "ff8c00ff" ;; yellow) echo "ffff00ff" ;;
        green) echo "00ff00ff" ;; cyan) echo "00ffffff" ;; blue) echo "0000ffff" ;;
        purple) echo "800080ff" ;; pink) echo "ffc0cbff" ;; magenta) echo "ff00ffff" ;;
        white) echo "ffffffff" ;; black) echo "000000ff" ;; gray|grey) echo "808080ff" ;;
        *) hex="''${1#\#}"; [[ "''${#hex}" -eq 6 ]] && echo "''${hex}ff" || echo "$hex" ;;
      esac
    }
    _generate() {
      while IFS=' ' read -r key color; do
        echo "windowrule = border_color rgba($(_rgba "$color")), match:tag vm-$key"
      done < <(${pkgs.jq}/bin/jq -r 'to_entries[] | select(.value.focusBorder != null) | "\(.key) \(.value.focusBorder)"' "$REGISTRY")
    }
    _apply_keyword() {
      while IFS= read -r rule; do
        ${pkgs.hyprland}/bin/hyprctl keyword windowrule "''${rule#windowrule = }" 2>/dev/null || true
      done < <(_generate)
    }
    _tag_existing() {
      while IFS=$'\t' read -r addr name; do
        ${pkgs.hyprland}/bin/hyprctl dispatch tagwindow "+vm-$name" "address:$addr" 2>/dev/null || true
      done < <(${pkgs.hyprland}/bin/hyprctl clients -j \
        | ${pkgs.jq}/bin/jq -r '.[] | select(.title | test("^\\[[a-z]")) | [.address, (.title | capture("^\\[(?<n>[^\\]]+)\\]").n)] | @tsv')
    }
    case "''${1:-toggle}" in
      init)
        mkdir -p "$(dirname "$CONF")"
        if [[ ! -f "$CONF" ]]; then _generate > "$CONF"; touch "$STATE"
        elif [[ -f "$STATE" ]]; then _generate > "$CONF"; fi
        if [[ -f "$STATE" ]]; then _tag_existing; _apply_keyword; fi ;;
      on)  mkdir -p "$(dirname "$CONF")"; _generate > "$CONF"; touch "$STATE"; _tag_existing; _apply_keyword ;;
      off) : > "$CONF"; rm -f "$STATE"; ${pkgs.hyprland}/bin/hyprctl reload 2>/dev/null || true ;;
      toggle) [[ -f "$STATE" ]] && exec "$0" off || exec "$0" on ;;
      status) [[ -f "$STATE" ]] && echo "on" || echo "off" ;;
      *) echo "Usage: hypr-vm-borders [on|off|toggle|status|init]" >&2; exit 1 ;;
    esac
  '';

  hyprFloatTerminal = pkgs.writeShellScriptBin "hypr-float-terminal" ''
    STATE_FILE="/tmp/hypr_float_state"
    X_OFFSET=50; Y_OFFSET=50; MAX_WINDOWS=5; WIN_W=800; WIN_H=550
    # Use the focused monitor -- more reliable for keybinds than cursor position.
    # hyprctl returns physical pixels for width/height; divide by scale for logical coords,
    # since movewindowpixel exact works in logical pixel space.
    MON_JSON=$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq '[.[] | select(.focused)] | .[0]')
    [ -z "$MON_JSON" ] || [ "$MON_JSON" = "null" ] && exit 1
    MON_X=$(printf '%s' "$MON_JSON" | ${pkgs.jq}/bin/jq '.x')
    MON_Y=$(printf '%s' "$MON_JSON" | ${pkgs.jq}/bin/jq '.y')
    MON_W=$(printf '%s' "$MON_JSON" | ${pkgs.jq}/bin/jq '(.width / .scale) | floor')
    MON_H=$(printf '%s' "$MON_JSON" | ${pkgs.jq}/bin/jq '(.height / .scale) | floor')
    INIT_X=$(( (MON_W - WIN_W) / 2 - MAX_WINDOWS * X_OFFSET / 2 ))
    INIT_Y=$(( (MON_H - WIN_H) / 2 - MAX_WINDOWS * Y_OFFSET / 2 ))
    [ "$INIT_X" -lt 50 ] && INIT_X=50; [ "$INIT_Y" -lt 50 ] && INIT_Y=50
    WS=$(${pkgs.hyprland}/bin/hyprctl activeworkspace -j 2>/dev/null | ${pkgs.jq}/bin/jq '.id')
    NFLOAT=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq --argjson ws "$WS" '[.[] | select(.workspace.id == $ws and .floating)] | length')
    # State file: saved_count MON_X MON_Y CUR_X CUR_Y -- reset when monitor changes
    if [ -f "$STATE_FILE" ]; then read -r saved_count SAVED_MON_X SAVED_MON_Y CUR_X CUR_Y < "$STATE_FILE"
    else saved_count=0 SAVED_MON_X="" SAVED_MON_Y=""; fi
    if [ "''${NFLOAT:-0}" -eq 0 ] || [ "''${SAVED_MON_X}" != "$MON_X" ] || [ "''${SAVED_MON_Y}" != "$MON_Y" ]; then
      saved_count=0 CUR_X=$((MON_X + INIT_X)) CUR_Y=$((MON_Y + INIT_Y))
    else
      saved_count=$(( saved_count + 1 ))
      NX=$(( CUR_X + X_OFFSET )); NY=$(( CUR_Y + Y_OFFSET ))
      MAX_X=$(( MON_X + MON_W - WIN_W - 50 )); MAX_Y=$(( MON_Y + MON_H - WIN_H - 50 ))
      if [ "$saved_count" -gt "$MAX_WINDOWS" ] || [ "$NX" -gt "$MAX_X" ] || [ "$NY" -gt "$MAX_Y" ]; then
        saved_count=1 CUR_X=$((MON_X + INIT_X)) CUR_Y=$((MON_Y + INIT_Y))
      else CUR_X=$NX CUR_Y=$NY; fi
    fi
    printf '%s %s %s %s %s\n' "$saved_count" "$MON_X" "$MON_Y" "$CUR_X" "$CUR_Y" > "$STATE_FILE"
    TITLE="hypr-float-$$"
    alacritty --class hypr-float --title "$TITLE" &
    for _ in $(seq 30); do
      sleep 0.1
      ADDR=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r --arg t "$TITLE" '.[] | select(.title == $t) | .address' | head -1)
      [ -n "$ADDR" ] && break
    done
    [ -n "$ADDR" ] && ${pkgs.hyprland}/bin/hyprctl dispatch movewindowpixel "exact $CUR_X $CUR_Y,address:$ADDR" >/dev/null 2>&1 || true
  '';

  clipTestHost = pkgs.writeShellScriptBin "clip-test-host" ''
    echo "=== Host Clipboard Test Runner ==="
    echo "Watching host compositor clipboard..."
    echo ""
    ${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.bash}/bin/bash -c '
      TS=$(date +%H:%M:%S.%3N)
      TITLE=$(${pkgs.hyprland}/bin/hyprctl activewindow -j 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r ".title // \"?\"" | head -c 60)
      CONTENT=$(${pkgs.wl-clipboard}/bin/wl-paste --no-newline 2>/dev/null | head -c 200)
      LEN=''${#CONTENT}
      echo "[$TS] focused=\"$TITLE\" ''${LEN}B content=\"''${CONTENT:0:80}\"..."
    '
  '';

  hyprFocusDaemon = pkgs.writeShellScriptBin "hypr-focus-daemon" ''
    REGISTRY=/etc/hydrix/vm-registry.json
    MARKER="$HOME/.cache/hydrix/focus-override-active"
    WAL_COLORS="$HOME/.cache/wal/colors.json"
    _rgba() {
      case "$1" in
        red) echo "ff0000ff" ;; orange) echo "ff8c00ff" ;; yellow) echo "ffff00ff" ;;
        green) echo "00ff00ff" ;; cyan) echo "00ffffff" ;; blue) echo "0000ffff" ;;
        purple) echo "800080ff" ;; pink) echo "ffc0cbff" ;; magenta) echo "ff00ffff" ;;
        white) echo "ffffffff" ;; black) echo "000000ff" ;; gray|grey) echo "808080ff" ;;
        *) hex="''${1#\#}"; [[ "''${#hex}" -eq 6 ]] && echo "''${hex}ff" || echo "$hex" ;;
      esac
    }
    _wal_color() {
      local c
      c=$(grep '^color4=' "$HOME/.cache/wal/colors.sh" 2>/dev/null \
        | sed "s/^color4='//;s/'$//;s/#//" | head -1)
      [ -n "$c" ] && echo "''${c}ff" || echo "7aa2f7ff"
    }
    _dynamic_color() {
      local profile="$1" WAL_KEY=""
      case "$profile" in
      ${dynamicMapCases}
      *) WAL_KEY="color4" ;;
      esac
      local c
      c=$(${pkgs.jq}/bin/jq -r --arg k "$WAL_KEY" '.colors[$k] // empty' "$WAL_COLORS" 2>/dev/null \
        | sed 's/#//')
      [ -n "$c" ] && echo "''${c}ff" || echo "7aa2f7ff"
    }
    _border_for_profile() {
      local profile="$1"
      if [ -f "$MARKER" ]; then
        local d; d=$(_dynamic_color "$profile")
        [ -n "$d" ] && { echo "$d"; return; }
      fi
      local c; c=$(${pkgs.jq}/bin/jq -r --arg p "$profile" '.[$p].focusBorder // empty' "$REGISTRY" 2>/dev/null)
      if [ -n "$c" ]; then _rgba "$c"; return; fi
      _wal_color
    }
    _apply() { ${pkgs.hyprland}/bin/hyprctl keyword general:col.active_border "rgba($1)" 2>/dev/null || true; }
    _reapply() {
      local title profile
      title=$(${pkgs.hyprland}/bin/hyprctl activewindow -j 2>/dev/null | ${pkgs.jq}/bin/jq -r '.title // empty')
      profile=$(echo "$title" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
      if [ -n "$profile" ]; then _apply "$(_border_for_profile "$profile")"
      else _apply "$(_wal_color)"; fi
    }
    _sig() {
      local sig="''${HYPRLAND_INSTANCE_SIGNATURE:-}"
      if [ -z "$sig" ]; then
        sig=$(ls "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/" 2>/dev/null | head -1)
      fi
      echo "$sig"
    }
    case "''${1:-}" in
      reapply) _reapply ;;
      *)
        SIG=$(_sig)
        [ -z "$SIG" ] && exit 1
        SOCKET="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$SIG/.socket2.sock"
        while true; do
          ${pkgs.socat}/bin/socat - "UNIX-CONNECT:$SOCKET" 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep --line-buffered '^activewindow>>' \
            | while IFS= read -r _line; do
                _payload="''${_line#activewindow>>}"
                _title="''${_payload#*,}"
                _profile=$(printf '%s' "$_title" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
                if [ -n "$_profile" ]; then _apply "$(_border_for_profile "$_profile")"
                else _apply "$(_wal_color)"; fi
              done
          sleep 1
        done ;;
    esac
  '';

in
  lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
    # Ensure ~/.config/hypr exists with correct ownership before home-manager runs.
    # On fresh machines the directory (or files within) can be created by root during
    # early system activation, causing home.activation.hyprlandGenerated to fail with EPERM.
    systemd.tmpfiles.rules = [
      "d /home/${username}/.config/hypr 0755 ${username} users -"
      "Z /home/${username}/.config/hypr - ${username} users -"
    ];

    environment.systemPackages = [
      hyprlandGapsAdjust
      hyprApplyColors
      hydrixBrightnessHypr
      hydrixVibrancyHypr
      hyprVmBorders
      hyprFloatTerminal
      hyprFocusDaemon
      clipTestHost
      pkgs.hypridle
      pkgs.swaybg
      pkgs.wl-clipboard
      pkgs.cliphist
    ];

    home-manager.users.${username} = {
      pkgs,
      config,
      lib,
      ...
    }: {
      # Enable Hyprland HM module for session/systemd integration.
      # Config file management is handled via home.activation below — not extraConfig.
      wayland.windowManager.hyprland = {
        enable = true;
        configType = "hyprlang";
        # Minimal comment suppresses HM's "no configuration" warning.
        # The actual config is written as a plain editable file by home.activation.
        extraConfig = "# config written by home.activation — edit ~/.config/hypr/hyprland.conf";
      };

      # Prevent HM from creating a read-only hyprland.conf symlink.
      # Our activation writes a plain editable file instead.
      xdg.configFile."hypr/hyprland.conf" = lib.mkForce { enable = false; };

      # Seed gap state files on first install / rebuild.
      home.activation.initHyprGaps = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/hypr"
        mkdir -p "$_dir"
        [[ -f "$_dir/gaps-inner" ]] || echo "${toString (gaps * 2)}" > "$_dir/gaps-inner"
        [[ -f "$_dir/gaps-outer" ]] || echo "${toString (gaps * 2)}" > "$_dir/gaps-outer"
      '';

      # Write the framework-generated config (VM routing, keyboard, monitor, colors source).
      # Skip write when content is unchanged — the nix store path is a content hash,
      # so comparing stamp → path avoids an inotify-triggered Hyprland reload on
      # every rebuild when nothing structural changed.
      home.activation.hyprlandGenerated = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/hypr"
        mkdir -p "$_dir"
        [ -L "$_dir/hydrix-generated.conf" ] && rm -f "$_dir/hydrix-generated.conf"
        _stamp="$_dir/.hydrix-generated-stamp"
        if [ "$(cat "$_stamp" 2>/dev/null)" != "${hyprlandGeneratedConf}" ]; then
          cp ${hyprlandGeneratedConf} "$_dir/hydrix-generated.conf"
          echo "${hyprlandGeneratedConf}" > "$_stamp"
          touch /tmp/hypr-gen-changed
        else
          rm -f /tmp/hypr-gen-changed
        fi
      '';

      # Reload Hyprland after rebuild — only when generated config actually changed.
      # Colors are reloaded separately by the colorscheme service; the activation
      # reload is only needed when VM routing, keyboard, or monitor config changed.
      home.activation.reloadHyprland = lib.hm.dag.entryAfter ["hyprlandGenerated"] ''
        if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && [ -f /tmp/hypr-gen-changed ]; then
          rm -f /tmp/hypr-gen-changed
          ${hyprApplyColors}/bin/hypr-apply-colors 2>/dev/null || true
        fi
      '';

      # VM window border rules — oneshot that seeds vm-borders.conf and applies
      # windowrule keywords for all VMs that have focusBorder set.
      systemd.user.services.hypr-vm-borders-init = {
        Unit = {
          Description = "Initialize Hyprland VM window border rules";
          After  = [ "hyprland-session.target" ];
          PartOf = [ "hyprland-session.target" ];
        };
        Service = {
          Type             = "oneshot";
          RemainAfterExit  = true;
          ExecStart        = "${hyprVmBorders}/bin/hypr-vm-borders init";
          Restart          = "on-failure";
          RestartSec       = 2;
        };
        Install.WantedBy = [ "hyprland-session.target" ];
      };
    };
  }
