# Hyprland Home Manager Configuration
#
# All compositor config lives in extraConfig (raw hyprland.conf syntax) so it's
# easy to read and tweak without understanding Nix attrset → conf translation.
# User additions in hydrix-config/shared/hyprland.nix use extraConfig lib.mkAfter.
#
# Color system:
#   hypr-apply-colors reads ~/.cache/wal/colors.sh → writes ~/.config/hypr/colors.conf
#   hyprland.conf sources colors.conf at runtime; no rebuild needed for color changes.
#
# VM window routing:
#   waypipe-connect sets --title-prefix "[<profile>] " on VM windows.
#   windowrulev2 rules route them to the correct workspace (same as sway for_window).
#   Generated from hydrix.networking.vmRegistry at build time.
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

  borderSize = toString (sc.border_size or 2);
  rounding   = toString (sc.cornerRadius or 0);
  fontFamily = cfg.font.family or "Iosevka";
  lk = config.hydrix.graphical.lockscreen;
  idleTimeout = toString (lk.idleTimeout or 600);
  configDir = config.hydrix.paths.configDir;
  hostname = config.hydrix.hostname;

  vmRegistry = config.hydrix.networking.vmRegistry or {};
  vmWindowRules = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (key: v:
      lib.optionalString ((v.hasDisplay or true) && v.workspace != null)
        "windowrulev2 = workspace ${toString v.workspace}, title:^\\[${key}\\]"
    ) vmRegistry
  );

  # Named color → RRGGBBAA (matches vm-theme-sync NAMED_COLORS table)
  namedColorToRgba = name: let
    table = {
      "red"     = "ff0000ff";
      "orange"  = "ff8c00ff";
      "yellow"  = "ffff00ff";
      "green"   = "00ff00ff";
      "cyan"    = "00ffffff";
      "blue"    = "0000ffff";
      "purple"  = "800080ff";
      "pink"    = "ffc0cbff";
      "magenta" = "ff00ffff";
      "white"   = "ffffffff";
      "black"   = "000000ff";
      "gray"    = "808080ff";
      "grey"    = "808080ff";
    };
  in table.${name} or "${lib.removePrefix "#" name}ff";

  # VM identity tags: assigned at window creation via title: matching.
  # title: works at creation time (where workspace routing also uses it), but NOT
  # for dynamic re-evaluation — Hyprland doesn't re-match title: on focus changes.
  # Tags ARE re-evaluated dynamically, so bordercolor rules use tag: instead.
  vmTagRules = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (key: v:
      lib.optionalString ((v.hasDisplay or true) && v.workspace != null)
        "windowrulev2 = tag +vm-${key}, title:^\\[${key}\\]"
    ) vmRegistry
  );

  workspaceColors = config.hydrix.hyprland.workspaceColors;
  workspaceColorRules = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (ws: color:
      "windowrulev2 = bordercolor rgba(${color}), workspace ${ws}"
    ) workspaceColors
  );

  # Gap adjuster: mirrors i3/sway — inner and outer adjusted independently.
  # Tracks current values in state files to avoid relying on hyprctl getoption
  # parsing (which varies across Hyprland versions).
  # Usage: hyprland-gaps-adjust inner|outer plus|minus [amount]
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

  # hypr-apply-colors: reads wal colors.sh → writes ~/.config/hypr/colors.conf
  #   and ~/.config/waybar/colors.css, then reloads both Hyprland and Waybar.
  # Called on startup (chained before waybar) and by randomwalrgb / refresh-colors.
  hyprApplyColors = pkgs.writeShellScriptBin "hypr-apply-colors" ''
    WAL="$HOME/.cache/wal/colors.sh"
    HYPR_OUT="$HOME/.config/hypr/colors.conf"
    BAR_OUT="$HOME/.config/waybar/colors.css"

    if [ -f "$WAL" ]; then
      . "$WAL"
    else
      color0="#0c0c0c"; color1="#bf616a"; color4="#7aa2f7"; color7="#d8dee9"; color8="#4c566a"
    fi

    mkdir -p "$(dirname "$HYPR_OUT")"
    printf '$activeBorder = rgba(%sff)\n$inactiveBorder = rgba(%s88)\n' \
      "''${color4#\#}" "''${color0#\#}" > "$HYPR_OUT"

    mkdir -p "$(dirname "$BAR_OUT")"
    printf '@define-color background %s;\n' "$color0" > "$BAR_OUT"
    printf '@define-color foreground %s;\n' "$color7" >> "$BAR_OUT"
    printf '@define-color accent     %s;\n' "$color4" >> "$BAR_OUT"
    printf '@define-color alert      %s;\n' "$color1" >> "$BAR_OUT"
    printf '@define-color color8     %s;\n' "$color8" >> "$BAR_OUT"

    LOCK_OUT="$HOME/.config/hypr/colors-lock.conf"
    mkdir -p "$(dirname "$LOCK_OUT")"
    printf '$lockBg = rgba(%sff)\n$lockFg = rgba(%sff)\n$lockAccent = rgba(%sff)\n$lockWrong = rgba(%sff)\n' \
      "''${color0#\#}" "''${color7#\#}" "''${color4#\#}" "''${color1#\#}" > "$LOCK_OUT"

    ${pkgs.hyprland}/bin/hyprctl reload 2>/dev/null || true
    ${pkgs.procps}/bin/pkill -SIGUSR2 waybar 2>/dev/null || true
    # Re-tag existing VM windows and re-apply bordercolor keywords.
    # hyprctl reload clears per-window tags, so VM border colors would revert
    # to the host wal color without this. VM colors are fixed (not wal-based).
    hypr-vm-borders init 2>/dev/null || true
  '';

  # hydrix-brightness-hypr: per-monitor brightness using hyprctl for monitor detection.
  # Internal (eDP-*): brightnessctl. External: ddcutil via DDC/CI.
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
            CONNECTOR=$(${pkgs.ddcutil}/bin/ddcutil capabilities --display "$NUM" 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -i "Model:" | head -1 || true)
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

  # hydrix-vibrancy-hypr: vibrancy (DDC VCP 8A) for external monitors under Hyprland
  hydrixVibrancyHypr = pkgs.writeShellScriptBin "hydrix-vibrancy-hypr" ''
    STEP=5
    MONITOR=$(${pkgs.hyprland}/bin/hyprctl monitors -j \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .name')
    [ -z "$MONITOR" ] && exit 1
    [[ "$MONITOR" == eDP-* ]] && exit 0
    DISPLAY_NUM=$(${pkgs.ddcutil}/bin/ddcutil detect --brief 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -E "^Display [0-9]+" \
      | while IFS= read -r line; do
          NUM=$(echo "$line" | grep -oE "[0-9]+")
          DRMSYS=$(ls /sys/class/drm/card*-"$MONITOR" 2>/dev/null | head -1 || true)
          [ -n "$DRMSYS" ] && echo "$NUM" && break
        done)
    [ -z "$DISPLAY_NUM" ] && exit 1
    case "$1" in
      +) ${pkgs.ddcutil}/bin/ddcutil --display "$DISPLAY_NUM" setvcp 8A + $STEP ;;
      -) ${pkgs.ddcutil}/bin/ddcutil --display "$DISPLAY_NUM" setvcp 8A - $STEP ;;
      *) exit 1 ;;
    esac
  '';

  # hypr-vm-borders: toggle VM-specific border colors on/off.
  #
  # Reads focusBorder and VM name from /etc/hydrix/vm-registry.json at runtime.
  # Generates tag-based bordercolor rules (tag:vm-<name>) — tags are assigned at
  # window creation via static title: rules in hyprland.conf and persist per-window,
  # making them suitable for dynamic re-evaluation (unlike title: matching itself).
  #
  # on     — generate rules from registry, write to vm-borders.conf, apply via keyword
  # off    — empty vm-borders.conf, reload (VM windows revert to global active border)
  # toggle — flip current state
  # status — print "on" or "off"
  # init   — called at Hyprland startup: initialize on first boot, refresh + re-apply rules
  hyprVmBorders = pkgs.writeShellScriptBin "hypr-vm-borders" ''
    REGISTRY=/etc/hydrix/vm-registry.json
    CONF=$HOME/.config/hypr/vm-borders.conf
    STATE=$HOME/.config/hypr/vm-borders-enabled

    # Named color or #RRGGBB → RRGGBBAA (matches Hydrix namedColorToRgba table)
    _rgba() {
      case "$1" in
        red)       echo "ff0000ff" ;;
        orange)    echo "ff8c00ff" ;;
        yellow)    echo "ffff00ff" ;;
        green)     echo "00ff00ff" ;;
        cyan)      echo "00ffffff" ;;
        blue)      echo "0000ffff" ;;
        purple)    echo "800080ff" ;;
        pink)      echo "ffc0cbff" ;;
        magenta)   echo "ff00ffff" ;;
        white)     echo "ffffffff" ;;
        black)     echo "000000ff" ;;
        gray|grey) echo "808080ff" ;;
        *) hex="''${1#\#}"; [[ "''${#hex}" -eq 6 ]] && echo "''${hex}ff" || echo "$hex" ;;
      esac
    }

    _generate() {
      while IFS=' ' read -r key color; do
        echo "windowrulev2 = bordercolor rgba($(_rgba "$color")), tag:vm-$key"
      done < <(${pkgs.jq}/bin/jq -r '
        to_entries[]
        | select(.value.focusBorder != null)
        | "\(.key) \(.value.focusBorder)"
      ' "$REGISTRY")
    }

    _apply_keyword() {
      while IFS= read -r rule; do
        ${pkgs.hyprland}/bin/hyprctl keyword windowrulev2 "''${rule#windowrulev2 = }" 2>/dev/null || true
      done < <(_generate)
    }

    # Tag already-open VM windows by their title prefix.
    # windowrulev2 tag rules only fire at window creation, so existing windows
    # (e.g. VMs that were running before Hyprland reloaded) need manual tagging.
    _tag_existing() {
      while IFS=$'\t' read -r addr name; do
        ${pkgs.hyprland}/bin/hyprctl dispatch tagwindow "+vm-$name" "address:$addr" 2>/dev/null || true
      done < <(${pkgs.hyprland}/bin/hyprctl clients -j \
        | ${pkgs.jq}/bin/jq -r '
            .[] | select(.title | test("^\\[[a-z]"))
            | [.address, (.title | capture("^\\[(?<n>[^\\]]+)\\]").n)]
            | @tsv
          ')
    }

    case "''${1:-toggle}" in
      init)
        mkdir -p "$(dirname "$CONF")"
        if [[ ! -f "$CONF" ]]; then
          _generate > "$CONF"
          touch "$STATE"
        elif [[ -f "$STATE" ]]; then
          _generate > "$CONF"
        fi
        if [[ -f "$STATE" ]]; then
          _tag_existing
          _apply_keyword
        fi
        ;;
      on)
        mkdir -p "$(dirname "$CONF")"
        _generate > "$CONF"
        touch "$STATE"
        _tag_existing
        _apply_keyword
        ;;
      off)
        : > "$CONF"
        rm -f "$STATE"
        ${pkgs.hyprland}/bin/hyprctl reload 2>/dev/null || true
        ;;
      toggle)
        [[ -f "$STATE" ]] && exec "$0" off || exec "$0" on
        ;;
      status)
        [[ -f "$STATE" ]] && echo "on" || echo "off"
        ;;
      *)
        echo "Usage: hypr-vm-borders [on|off|toggle|status]" >&2
        exit 1
        ;;
    esac
  '';

  # hypr-float-terminal: cascading floating alacritty windows, Hyprland-native.
  # Mirrors hydrix-float-terminal (i3) using hyprctl instead of xrandr/xdotool/i3-msg.
  # Tracks cascade position in /tmp/hypr_float_state; resets when no floating windows remain.
  # Window class hypr-float is caught by windowrulev2 rules (float + size).
  hyprFloatTerminal = pkgs.writeShellScriptBin "hypr-float-terminal" ''
    STATE_FILE="/tmp/hypr_float_state"
    X_OFFSET=50
    Y_OFFSET=50
    MAX_WINDOWS=5
    WIN_W=800
    WIN_H=550

    # Cursor position → active monitor bounds
    CURSOR=$(${pkgs.hyprland}/bin/hyprctl cursorpos -j 2>/dev/null)
    CX=$(printf '%s' "$CURSOR" | ${pkgs.jq}/bin/jq '.x')
    CY=$(printf '%s' "$CURSOR" | ${pkgs.jq}/bin/jq '.y')

    MON=$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r --argjson cx "$CX" --argjson cy "$CY" '
          .[] | select(.x <= $cx and $cx < (.x + .width)
                   and .y <= $cy and $cy < (.y + .height))
          | "\(.x) \(.y) \(.width) \(.height)"
        ' | head -1)
    read -r MON_X MON_Y MON_W MON_H <<< "''${MON:-0 0 1920 1080}"

    INIT_X=$(( (MON_W - WIN_W) / 2 - MAX_WINDOWS * X_OFFSET / 2 ))
    INIT_Y=$(( (MON_H - WIN_H) / 2 - MAX_WINDOWS * Y_OFFSET / 2 ))
    [ "$INIT_X" -lt 50 ] && INIT_X=50
    [ "$INIT_Y" -lt 50 ] && INIT_Y=50

    # Count floating windows on the focused workspace
    WS=$(${pkgs.hyprland}/bin/hyprctl activeworkspace -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq '.id')
    NFLOAT=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq --argjson ws "$WS" \
          '[.[] | select(.workspace.id == $ws and .floating)] | length')

    if [ -f "$STATE_FILE" ]; then
      read -r saved_count CUR_X CUR_Y < "$STATE_FILE"
    else
      saved_count=0 CUR_X=$((MON_X + INIT_X)) CUR_Y=$((MON_Y + INIT_Y))
    fi

    if [ "''${NFLOAT:-0}" -eq 0 ]; then
      saved_count=0 CUR_X=$((MON_X + INIT_X)) CUR_Y=$((MON_Y + INIT_Y))
    else
      saved_count=$(( saved_count + 1 ))
      NX=$(( CUR_X + X_OFFSET ))
      NY=$(( CUR_Y + Y_OFFSET ))
      MAX_X=$(( MON_X + MON_W - WIN_W - 50 ))
      MAX_Y=$(( MON_Y + MON_H - WIN_H - 50 ))
      if [ "$saved_count" -gt "$MAX_WINDOWS" ] || [ "$NX" -gt "$MAX_X" ] || [ "$NY" -gt "$MAX_Y" ]; then
        saved_count=1 CUR_X=$((MON_X + INIT_X)) CUR_Y=$((MON_Y + INIT_Y))
      else
        CUR_X=$NX CUR_Y=$NY
      fi
    fi
    printf '%s %s %s\n' "$saved_count" "$CUR_X" "$CUR_Y" > "$STATE_FILE"

    # Launch with a unique title so we can find the window to position it.
    # Float + size are handled by windowrulev2; we only need to move it here.
    TITLE="hypr-float-$$"
    alacritty --class hypr-float --title "$TITLE" &

    for _ in $(seq 30); do
      sleep 0.1
      ADDR=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r --arg t "$TITLE" '.[] | select(.title == $t) | .address' \
        | head -1)
      [ -n "$ADDR" ] && break
    done

    [ -n "$ADDR" ] && ${pkgs.hyprland}/bin/hyprctl dispatch \
      movewindowpixel "exact $CUR_X $CUR_Y,address:$ADDR" >/dev/null 2>&1 || true
  '';

in lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
  environment.systemPackages = [
    hyprlandGapsAdjust
    hyprApplyColors
    hydrixBrightnessHypr
    hydrixVibrancyHypr
    hyprVmBorders
    hyprFloatTerminal
    pkgs.swayidle
    pkgs.swaybg
  ];

  home-manager.users.${username} = {
    pkgs,
    config,
    lib,
    ...
  }: {
    # Ensure vm-borders.conf exists before Hyprland starts (source = requires the file).
    # If Hyprland is already running, reload it so config changes take effect immediately:
    #   writes colors.conf ($activeBorder = wal color4), hyprctl reload, re-tags VM windows.
    home.activation.initHyprVmBorders = lib.hm.dag.entryAfter ["writeBoundary"] ''
      CONF="$HOME/.config/hypr/vm-borders.conf"
      mkdir -p "$(dirname "$CONF")"
      [[ -f "$CONF" ]] || touch "$CONF"
      [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && \
        ${hyprApplyColors}/bin/hypr-apply-colors 2>/dev/null || true
    '';

    # Seed gap state files with configured values on first install / rebuild.
    # hyprland-gaps-adjust reads these instead of hyprctl getoption, which
    # returns unreliable results across Hyprland versions.
    home.activation.initHyprGaps = lib.hm.dag.entryAfter ["writeBoundary"] ''
      DIR="$HOME/.config/hypr"
      mkdir -p "$DIR"
      [[ -f "$DIR/gaps-inner" ]] || echo "${toString gaps}" > "$DIR/gaps-inner"
      [[ -f "$DIR/gaps-outer" ]] || echo "${toString gaps}" > "$DIR/gaps-outer"
    '';

    wayland.windowManager.hyprland = {
      enable = true;

      # All config as raw hyprland.conf — easy to read and tweak.
      # User additions in shared/hyprland.nix use extraConfig = lib.mkAfter.
      extraConfig = ''
        # ── Colors (written at runtime by hypr-apply-colors from wal) ────────
        # Fallback values in case colors.conf doesn't exist yet on first boot.
        $activeBorder   = rgba(7aa2f7ff)
        $inactiveBorder = rgba(1a1b26aa)
        source = ~/.config/hypr/colors.conf

        # ── Monitor ──────────────────────────────────────────────────────────
        monitor = ,preferred,auto,1

        # ── Startup ──────────────────────────────────────────────────────────
        # Export WAYLAND_DISPLAY to the systemd user environment first — required
        # so the i3 display-hotplug path unit (ConditionEnvironment=!WAYLAND_DISPLAY)
        # doesn't fire display-setup → polybar when X11 returns.
        exec-once = systemctl --user set-environment WAYLAND_DISPLAY=$WAYLAND_DISPLAY
        # hypr-vm-borders init writes vm-borders.conf before hypr-apply-colors reloads,
        # so the sourced bordercolor rules are populated on first load (not just keywords).
        exec-once = sh -c 'wal -Rnq; hypr-vm-borders init; hypr-apply-colors'
        exec-once = sh -c 'WALL=$(cat "$HOME/.cache/wal/wal" 2>/dev/null); [ -n "$WALL" ] && swaybg -i "$WALL" -m fill'
        exec-once = ${pkgs.dunst}/bin/dunst
        # Start waybar after a brief delay so the Hyprland socket is ready.
        exec-once = sh -c 'sleep 2 && hypr-apply-colors && waybar'
        exec-once = vm-push-display-mode
        exec-once = waypipe-connect-all
        exec-once = swayidle -w timeout ${idleTimeout} 'hyprlock --force-focus' before-sleep 'hyprlock --force-focus'

        # ── General ──────────────────────────────────────────────────────────
        general {
          gaps_in  = ${toString gaps}
          gaps_out = ${toString gaps}
          border_size  = ${borderSize}
          col.active_border   = $activeBorder
          col.inactive_border = $inactiveBorder
          layout = dwindle
        }

        # ── Decoration ───────────────────────────────────────────────────────
        decoration {
          rounding         = ${rounding}
          active_opacity   = 0.95
          inactive_opacity = 0.95

          blur {
            enabled  = true
            passes   = 1
            size     = 3
            vibrancy = 0.1696
          }

          shadow {
            enabled = true
            range   = 10
          }
        }

        # ── Animations ───────────────────────────────────────────────────────
        animations {
          enabled = true
          bezier = easeOut, 0.25, 0.1, 0.25, 1.0
          animation = windows,    1, 3, easeOut
          animation = border,     1, 10, default
          animation = fade,       1, 2, easeOut
          animation = workspaces, 1, 4, easeOut
        }

        # ── Input ────────────────────────────────────────────────────────────
        input {
          kb_layout     = us
          follow_mouse  = 0
          sensitivity   = -0.2
          natural_scroll = true

          touchpad {
            natural_scroll = true
          }
        }

        # ── Layout ───────────────────────────────────────────────────────────
        dwindle {
          pseudotile     = false
          preserve_split = true
          force_split    = 2
        }

        # ── Misc ─────────────────────────────────────────────────────────────
        misc {
          disable_hyprland_logo    = true
          disable_splash_rendering = true
          focus_on_activate        = true
        }

        # ── Variables ────────────────────────────────────────────────────────
        $mod = SUPER

        # ── Keybindings ──────────────────────────────────────────────────────
        # Terminal
        bind = $mod,       Return, exec, hypr-ws-app alacritty
        bind = $mod SHIFT, Return, exec, alacritty
        bind = $mod,       S,      exec, hypr-float-terminal

        # Launcher
        bind = $mod,       Q, killactive,
        bind = $mod,       D, exec, wofi-launcher
        bind = $mod,       F4, exec, focus-wofi

        # Browser (via VM)
        bind = $mod, B, exec, hypr-ws-app firefox
        bind = $mod, A, exec, hypr-ws-app firefox https://claude.ai
        bind = $mod, T, exec, hypr-ws-app firefox https://borttappat.github.io/links.html
        bind = $mod, G, exec, hypr-ws-app firefox https://github.com/borttappat/Hydrix
        bind = $mod, N, exec, hypr-ws-app firefox https://search.nixos.org/packages?channel=unstable

        # Applications
        bind = $mod,       O, exec, obsidian
        bind = $mod,       M, exec, alacritty -e hydrix-tui
        bind = $mod SHIFT, M, exec, vm-launch
        bind = $mod,       Z, exec, zathura

        # Vault (Bitwarden)
        bind = $mod SHIFT, P, exec, vault-rofi

        # Brightness / Vibrancy (Hyprland-native monitor detection)
        bind = $mod,       F7, exec, hydrix-brightness-hypr -
        bind = $mod,       F8, exec, hydrix-brightness-hypr +
        bind = $mod SHIFT, F7, exec, hydrix-vibrancy-hypr -
        bind = $mod SHIFT, F8, exec, hydrix-vibrancy-hypr +

        # Screenshot
        bind = $mod, F12, exec, grim -g "$(slurp)" ~/screenshots/$(date +%Y%m%d_%H%M%S).png

        # System monitors
        bind = $mod SHIFT, U, exec, hypr-ws-app alacritty -e htop
        bind = $mod SHIFT, B, exec, alacritty -e btm

        # File manager (via VM)
        bind = $mod SHIFT, F, exec, hypr-ws-app alacritty -e joshuto

        # Git status
        bind = $mod SHIFT, G, exec, alacritty -e fish -c 'clear && cd ${configDir} && git status && exec fish'

        # Wallpaper
        bind = $mod,       W, exec, randomwalrgb
        bind = $mod SHIFT, W, exec, wallpaper-black

        # Lock / Suspend / Exit
        bind = $mod SHIFT,      E, exec, hyprlock --force-focus
        bind = $mod SHIFT,      S, exec, systemctl suspend
        bind = $mod CTRL SHIFT, E, exec, exit-wayland

        # Focus (hjkl + arrows)
        bind = $mod, H,     movefocus, l
        bind = $mod, J,     movefocus, d
        bind = $mod, K,     movefocus, u
        bind = $mod, L,     movefocus, r
        bind = $mod, left,  movefocus, l
        bind = $mod, down,  movefocus, d
        bind = $mod, up,    movefocus, u
        bind = $mod, right, movefocus, r

        # Move windows (hjkl)
        bind = $mod SHIFT, H, movewindow, l
        bind = $mod SHIFT, J, movewindow, d
        bind = $mod SHIFT, K, movewindow, u
        bind = $mod SHIFT, L, movewindow, r

        # Layout
        bind = $mod,       C,     layoutmsg, preselect d
        bind = $mod,       V,     layoutmsg, preselect r
        bind = $mod,       F,     fullscreen, 0
        bind = $mod SHIFT, SPACE, togglefloating,
        bind = $mod,       SPACE, cyclenext,
        bind = $mod,       R,     submap, resize

        # Gaps (mirrors i3/sway: Up/Down = inner, Left/Right = outer)
        bind = $mod SHIFT, up,    exec, hyprland-gaps-adjust inner plus 5
        bind = $mod SHIFT, down,  exec, hyprland-gaps-adjust inner minus 5
        bind = $mod SHIFT, right, exec, hyprland-gaps-adjust outer plus 5
        bind = $mod SHIFT, left,  exec, hyprland-gaps-adjust outer minus 5

        # Scratchpad
        bind = $mod SHIFT, minus, movetoworkspace, special
        bind = $mod,       minus, togglespecialworkspace,

        # Workspaces
        bind = $mod, 1, workspace, 1
        bind = $mod, 2, workspace, 2
        bind = $mod, 3, workspace, 3
        bind = $mod, 4, workspace, 4
        bind = $mod, 5, workspace, 5
        bind = $mod, 6, workspace, 6
        bind = $mod, 7, workspace, 7
        bind = $mod, 8, workspace, 8
        bind = $mod, 9, workspace, 9
        bind = $mod, 0, workspace, 10

        # Move to workspace
        bind = $mod SHIFT, 1, movetoworkspace, 1
        bind = $mod SHIFT, 2, movetoworkspace, 2
        bind = $mod SHIFT, 3, movetoworkspace, 3
        bind = $mod SHIFT, 4, movetoworkspace, 4
        bind = $mod SHIFT, 5, movetoworkspace, 5
        bind = $mod SHIFT, 6, movetoworkspace, 6
        bind = $mod SHIFT, 7, movetoworkspace, 7
        bind = $mod SHIFT, 8, movetoworkspace, 8
        bind = $mod SHIFT, 9, movetoworkspace, 9
        bind = $mod SHIFT, 0, movetoworkspace, 10

        # Mouse — move/resize windows
        bindm = $mod, mouse:272, movewindow
        bindm = $mod, mouse:273, resizewindow

        # Mouse — scroll through workspaces
        bind = $mod, mouse_down, workspace, e+1
        bind = $mod, mouse_up,   workspace, e-1

        # ── Resize submap ────────────────────────────────────────────────────
        submap = resize
        binde = , H,      resizeactive, -10 0
        binde = , L,      resizeactive,  10 0
        binde = , K,      resizeactive,  0 -10
        binde = , J,      resizeactive,  0  10
        binde = , left,   resizeactive, -10 0
        binde = , right,  resizeactive,  10 0
        binde = , up,     resizeactive,  0 -10
        binde = , down,   resizeactive,  0  10
        bind  = , escape, submap, reset
        bind  = , Return, submap, reset
        submap = reset

        # ── Window rules ─────────────────────────────────────────────────────
        windowrulev2 = float, class:^(pavucontrol)$
        windowrulev2 = float, class:^(lxappearance)$
        windowrulev2 = float, class:^(nm-connection-editor)$
        # hypr-float-terminal windows ($mod+S) — float + fixed size; position set by script
        windowrulev2 = float, class:^(hypr-float)$
        windowrulev2 = size 800 550, class:^(hypr-float)$
        # Alacritty manages its own opacity
        windowrulev2 = opacity 1.0 override, class:^(Alacritty)$
        windowrulev2 = opacity 1.0 override, class:^(alacritty)$
        windowrulev2 = opacity 1.0 override, class:^(hypr-float)$

        # VM window routing + identity tagging.
        # title: matching works at window creation (one-shot): used for both workspace
        # assignment and tagging. Tags persist per-window and enable dynamic bordercolor
        # matching (tag: is re-evaluated on focus; title: is not).
        ${vmWindowRules}
        ${vmTagRules}

        # Per-workspace active border color overrides (hydrix.hyprland.workspaceColors)
        ${workspaceColorRules}

        # Per-VM border colors — managed by hypr-vm-borders (on/off/toggle).
        # Sourced from ~/.config/hypr/vm-borders.conf, initialized by hypr-vm-borders init.
        # VM rules come last so they override any workspace-wide color set above.
        source = ~/.config/hypr/vm-borders.conf
      '';
    };

    # hyprlock — blurred screenshot lockscreen via hypr-lock script (wm/hyprland.nix)
    # Colors sourced at runtime from ~/.config/hypr/colors-lock.conf (written by hypr-apply-colors).
    programs.hyprlock = {
      enable = true;
      settings = {
        general = {
          disable_loading_bar = true;
          grace = 5;
          hide_cursor = true;
        };
        background = [{
          path = "screenshot";
          blur_passes = 2;
          blur_size = 5;
          brightness = 0.5;
          vibrancy = 0.2;
        }];
      };
      # source must precede the sections that reference $lockXxx variables,
      # so input-field and label live here rather than in settings.
      # Full path used (no tilde) — hyprlock does not expand ~ in source paths.
      extraConfig = ''
        source = /home/${username}/.config/hypr/colors-lock.conf

        input-field {
          size = 300, 55
          position = 0, -80
          monitor =
          dots_center = true
          fade_on_empty = false
          placeholder_text = ${lk.text}
          fail_text = ${lk.wrongText}
          outer_color = $lockAccent
          inner_color = $lockBg
          font_color = $lockFg
          fail_color = $lockWrong
          check_color = $lockAccent
          halign = center
          valign = center
        }

        label {
          monitor =
          text = cmd[update:1000] echo "$(date +"%H:%M:%S")"
          color = $lockFg
          font_size = ${toString lk.clockSize}
          font_family = ${lk.font}
          position = 0, 180
          halign = center
          valign = center
        }

        label {
          monitor =
          text = cmd[update:1000] echo "$(date +"%A, %B %d, %Y")"
          color = $lockFg
          font_size = ${toString (lk.clockSize / 3)}
          font_family = ${lk.font}
          position = 0, 100
          halign = center
          valign = center
        }
      '';
    };
  };
}
