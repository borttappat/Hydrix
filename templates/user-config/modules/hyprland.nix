# Hyprland user configuration - compositor settings, keybindings, window rules, lockscreen.
#
# Config files are written as plain writable files via home.activation.
# You can edit ~/.config/hypr/hyprland.conf and ~/.config/hypr/hyprlock.conf freely
# between rebuilds. Rebuild will overwrite them with the current values here.
#
# ~/.config/hypr/hydrix-generated.conf is managed by the framework (VM rules,
# keyboard, monitor) and always regenerated - do not edit it.
#
# Keyboard layout is set via hydrix.graphical.keyboard in machines/<serial>.nix:
#   hydrix.graphical.keyboard.layout = "us";          # simple layout
#   hydrix.graphical.keyboard.xkbOptions = "caps:ctrl_modifier"; # optional extras
#   hydrix.graphical.keyboard.xkbFile = pkgs.writeText "keymap" ''...xkb_keymap {...}...'';
#
# Set all compositor preferences, keybindings, and appearance here.
# Machine-specific overrides go in machines/<serial>.nix via lib.mkAfter on extraConfig.
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Used for programs.hyprland.package and every hyprctl invocation in this
  # file, so helper scripts always talk to the compositor's own IPC version.
  hyprlandPkg = pkgs.hyprland;

  username = config.hydrix.username;
  sc = config.hydrix.graphical.scaling.computed;
  ui = config.hydrix.graphical.ui;
  # Window shadow at ui.shadow.strength 1.0: range 4, 25% black (0x40), power 2.
  # Hyprland starts at full alpha at the window edge where a GTK box-shadow
  # starts at half, so this approximates the waybar pill and eww block falloff.
  shadowOn = ui.shadow.enable && ui.shadow.strength > 0;
  shadowRange = toString (builtins.floor (4 * ui.shadow.strength + 0.5));
  shadowAlpha = lib.fixedWidthString 2 "0" (lib.toHexString (lib.min 255 (builtins.floor (64 * ui.shadow.strength + 0.5))));
  # Layer-shell surfaces (eww, waybar, wofi, swaync) are only blurred when a
  # layerrule asks for it. ignore_alpha just below each app's overlay opacity
  # confines the blur to the panel fill, leaving transparent padding and
  # box-shadow halos unblurred.
  layerBlur = lib.concatStrings (lib.mapAttrsToList (app: namespaces: let
    o = ui.opacity.overlayOverrides.${app} or ui.opacity.overlay;
  in
    lib.optionalString (o < 1.0) (lib.concatMapStrings (ns: ''
        layerrule = blur 1, match:namespace ^(${ns})$
        layerrule = ignore_alpha ${toString (o - 0.05)}, match:namespace ^(${ns})$
      '')
      namespaces)) {
    eww = ["eww-dashboard"];
    waybar = ["waybar"];
    wofi = ["wofi"];
    notifications = ["swaync-notification-window" "swaync-control-center"];
  });
  gaps = ui.gaps or 10;
  barType = config.hydrix.graphical.waybar.barType or "monobar";
  # Bottom gap: dualbar's bottom bar provides it via exclusive zone, monobar needs gaps_out.
  gapsOutBottom =
    if barType == "monobar"
    then gaps
    else 0;
  # Round rather than floor: plain `gaps / 2` truncates (5 -> 2), visibly
  # undersizing the inner gap relative to gaps_out for odd values.
  gapsIn = (gaps + 1) / 2;
  borderSize = toString (sc.border or 2);
  rounding = toString (sc.cornerRadius or 0);
  lkRounding = toString (
    if (ui.cornerRadius or 0) > 0
    then ui.cornerRadius * 2
    else 2
  );

  lk = config.hydrix.graphical.lockscreen;
  idleTimeout = toString (lk.idleTimeout or 300);
  configDir = config.hydrix.paths.configDir;
  kb = config.hydrix.graphical.keyboard;

  # Remembers monitor position/scale per monitor identity (EDID-based `description`,
  # stable across ports/docks/cables - unlike `name` which is just DP-1/HDMI-A-1 and
  # can shift), and re-applies it on connect. Also the single place that restarts
  # waybar after a manual `hyprctl keyword monitor` reposition, since that command
  # alone fires neither monitoradded nor monitorremoved (see waybarMonitorWatch below).
  #
  # Some Hyprland builds embed the port name in `description` (e.g. "... (DP-1)");
  # stripped defensively so identity stays port-independent either way.
  monitorLayout = pkgs.writeShellScriptBin "monitor-layout" ''
    set -eu
    _dir="$HOME/.local/state/hyprland"
    _state="$_dir/monitor-layout.json"
    _hyprconf="$HOME/.config/hypr/monitor-layout.conf"
    mkdir -p "$_dir" "$(dirname "$_hyprconf")"
    [ -f "$_state" ] || echo '{}' > "$_state"

    _monitors_json() { ${hyprlandPkg}/bin/hyprctl monitors -j; }
    _strip_port() { ${pkgs.gnused}/bin/sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//'; }
    _restart_waybar() {
      systemctl --user stop waybar 2>/dev/null || true
      sleep 0.3
      systemctl --user start waybar
    }

    # Regenerates the sourced Hyprland config snippet from the JSON state, so
    # saved positions are part of the config Hyprland re-reads on every
    # `hyprctl reload` (colour changes, VM-registry regen, etc.) and on every
    # new monitor connect - not just something applied once at runtime and
    # silently overwritten by the framework's wildcard `monitor = ,preferred,auto,1`
    # fallback rule the next time anything reloads.
    _write_conf() {
      {
        echo "# Generated by monitor-layout - do not edit, regenerated on set/capture/forget."
        ${pkgs.jq}/bin/jq -r \
          'to_entries[] | "monitor = desc:\(.key),preferred,\(.value.x)x\(.value.y),\(.value.scale)"' \
          "$_state"
      } > "$_hyprconf.new"
      mv "$_hyprconf.new" "$_hyprconf"
    }

    cmd_apply() {
      _restart=1
      [ "''${1:-}" = "--no-restart" ] && _restart=0
      _write_conf
      ${hyprlandPkg}/bin/hyprctl reload
      [ "$_restart" = 1 ] && _restart_waybar
    }

    cmd_capture() {
      _tmp=$(mktemp)
      _monitors_json | ${pkgs.jq}/bin/jq 'map({(.description | gsub("[[:space:]]*\\([^)]*\\)[[:space:]]*$"; "")): {x: .x, y: .y, scale: .scale}}) | add' > "$_tmp"
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$_state" "$_tmp" > "$_state.new"
      mv "$_state.new" "$_state"
      rm -f "$_tmp"
      _write_conf
      echo "Captured layout for $(${pkgs.jq}/bin/jq 'length' "$_state") monitor(s)."
    }

    cmd_set() {
      _pos="''${1:?usage: monitor-layout set <left|right|top|bottom|above|below|auto|WxH> [monitor-name]}"
      _name="''${2:-}"
      case "$_pos" in
        left | right) _pos="auto-$_pos" ;;
        top | above) _pos="auto-up" ;;
        bottom | below) _pos="auto-down" ;;
        auto | auto-up | auto-down | auto-left | auto-right) ;;
        [0-9]*x[0-9]*) ;;
        *)
          echo "monitor-layout: unrecognized position '$_pos' (use left/right/top/bottom/above/below/auto/WxH)" >&2
          exit 1
          ;;
      esac
      [ -n "$_name" ] || _name=$(_monitors_json | ${pkgs.jq}/bin/jq -r '[.[] | select(.focused)][0].name')
      # hyprctl always exits 0 - success is the literal "ok" response, anything
      # else (e.g. "invalid auto direction") is an error text on the same stdout.
      # Checked explicitly so a rejected command can never save/persist a stale
      # or unrelated position under the requested one.
      # Keep the monitor's current scale: a hardcoded 1 here would be saved into
      # the desc: rule and override hyprInternalScale for the internal panel.
      _cur_scale=$(_monitors_json | ${pkgs.jq}/bin/jq -r --arg n "$_name" '.[] | select(.name==$n) | .scale')
      _result=$(${hyprlandPkg}/bin/hyprctl keyword monitor "$_name,preferred,$_pos,$_cur_scale")
      if [ "$_result" != "ok" ]; then
        echo "monitor-layout: hyprctl rejected '$_pos' for $_name: $_result" >&2
        exit 1
      fi
      sleep 0.2
      _desc=$(_monitors_json | ${pkgs.jq}/bin/jq -r --arg n "$_name" '.[] | select(.name==$n) | .description' | _strip_port)
      _x=$(_monitors_json | ${pkgs.jq}/bin/jq -r --arg n "$_name" '.[] | select(.name==$n) | .x')
      _y=$(_monitors_json | ${pkgs.jq}/bin/jq -r --arg n "$_name" '.[] | select(.name==$n) | .y')
      _scale=$(_monitors_json | ${pkgs.jq}/bin/jq -r --arg n "$_name" '.[] | select(.name==$n) | .scale')
      ${pkgs.jq}/bin/jq --arg d "$_desc" --argjson x "$_x" --argjson y "$_y" --argjson s "$_scale" \
        '.[$d] = {x: $x, y: $y, scale: $s}' "$_state" > "$_state.new" && mv "$_state.new" "$_state"
      _write_conf
      _restart_waybar
      echo "Saved position for $_desc ($_name): $_x,$_y @ ''${_scale}x"
    }

    cmd_gui() {
      ${pkgs.nwg-displays}/bin/nwg-displays
      cmd_capture
      _restart_waybar
    }

    cmd_list() {
      ${pkgs.jq}/bin/jq -r 'to_entries[] | "\(.key): \(.value.x),\(.value.y) @ \(.value.scale)x"' "$_state"
    }

    cmd_forget() {
      _match="''${1:?usage: monitor-layout forget <description-substring>}"
      ${pkgs.jq}/bin/jq --arg m "$_match" 'with_entries(select(.key | contains($m) | not))' "$_state" > "$_state.new" && mv "$_state.new" "$_state"
      _write_conf
    }

    case "''${1:-}" in
      set) shift; cmd_set "$@" ;;
      apply) shift; cmd_apply "''${1:-}" ;;
      capture) cmd_capture ;;
      gui) cmd_gui ;;
      list) cmd_list ;;
      forget) shift; cmd_forget "$@" ;;
      *)
        echo "usage: monitor-layout {set <left|right|top|bottom|above|below|auto|WxH> [name]|apply|capture|gui|list|forget <match>}" >&2
        exit 1
        ;;
    esac
  '';

  # Restarts waybar (via systemd) on monitor plug/unplug. Positioning itself needs
  # no action here: monitor-layout's saved positions live as desc:-matched rules in
  # ~/.config/hypr/monitor-layout.conf (sourced into hyprland.conf), so Hyprland
  # applies them to a reconnecting monitor on its own, same as any other config rule.
  # Waybar picks up the transient reconfiguration state and doesn't recover once
  # Hyprland settles - a systemctl restart after the monitors stabilise fixes it.
  #
  # configreloaded is intentionally NOT handled: hypr-apply-colors calls
  # hyprctl reload on every colour change, which would restart waybar constantly.
  # Monitor displacement fires monitoradded/monitorremoved anyway, so those suffice.
  waybarMonitorWatch = pkgs.writeShellScript "waybar-monitor-watch" ''
    _sock="''${XDG_RUNTIME_DIR}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
    [ -S "$_sock" ] || exit 1
    # Grace period: ignore startup monitoradded events fired for already-connected monitors.
    _boot=$(${pkgs.coreutils}/bin/date +%s)
    _grace=10
    # Debounce: burst of events (monitorremoved + monitoradded) each increment a counter.
    # Only the subshell whose counter still matches at wake-up proceeds.
    _seq="''${XDG_RUNTIME_DIR}/waybar-monitor-watch-seq"
    echo 0 > "$_seq"
    ${pkgs.socat}/bin/socat -u "UNIX-CONNECT:$_sock" - | while IFS= read -r line; do
      case "$line" in
        monitoradded*|monitorremoved*)
          [ "$(( $(${pkgs.coreutils}/bin/date +%s) - _boot ))" -lt "$_grace" ] && continue
          # Stop immediately so waybar doesn't auto-spawn bars for the new output.
          systemctl --user stop waybar 2>/dev/null || true
          _n=$(( $(cat "$_seq") + 1 ))
          echo "$_n" > "$_seq"
          _my=$_n
          ( sleep 1
            [ "$(cat "$_seq" 2>/dev/null)" = "$_my" ] || exit 0
            systemctl --user start waybar
          ) &
          ;;
      esac
    done
  '';

  dockRight = pkgs.writeShellScript "dock-right" ''
    ${hyprlandPkg}/bin/hyprctl dispatch togglefloating active
    floating=$(${hyprlandPkg}/bin/hyprctl activewindow -j | ${pkgs.jq}/bin/jq '.floating')
    if [ "$floating" = "true" ]; then
      # monitors -j: width/height are physical pixels (divide by scale for logical
      # coords, matching resizeactive/moveactive); x/y and reserved[] are already
      # logical. reserved is [left, top, right, bottom] - the layer-shell exclusive
      # zone waybar reserves.
      #
      # gaps_out/gaps_in/border_size are read live rather than from the nix-baked
      # defaults: hyprland-gaps-adjust persists interactive gap changes straight via
      # `hyprctl keyword`, bypassing the generated config, so the build-time values
      # can be stale. A tiled window's actual on-screen box also sits border_size
      # further in than gaps_out/reserved alone would suggest (the border is drawn
      # outside the box), and the gap between two adjacent tiles is 2*gaps_in from
      # each window's own margin plus 2*border_size from their facing borders.
      read -r mx my w h rl rt rr rb <<< "$(${hyprlandPkg}/bin/hyprctl monitors -j | ${pkgs.jq}/bin/jq -r \
        '[.[] | select(.focused)][0] | "\(.x) \(.y) \((.width/.scale)|floor) \((.height/.scale)|floor) \(.reserved[0]) \(.reserved[1]) \(.reserved[2]) \(.reserved[3])"')"
      read -r gt gr gb gl <<< "$(${hyprlandPkg}/bin/hyprctl getoption general:gaps_out -j | ${pkgs.jq}/bin/jq -r '.custom')"
      gin=$(${hyprlandPkg}/bin/hyprctl getoption general:gaps_in -j | ${pkgs.jq}/bin/jq -r '.custom' | ${pkgs.gawk}/bin/awk '{print $1}')
      border=$(${hyprlandPkg}/bin/hyprctl getoption general:border_size -j | ${pkgs.jq}/bin/jq -r '.int')
      left=$((rl + gl + border))
      top=$((rt + border))
      right=$((rr + gr + border))
      bottom=$((rb + gb + border))
      usable_w=$((w - left - right))
      usable_h=$((h - top - bottom))
      mid=$(( gin * 2 + border * 2 ))
      half=$(( (usable_w - mid) / 2 ))
      ${hyprlandPkg}/bin/hyprctl dispatch resizeactive exact "$half" "$usable_h"
      ${hyprlandPkg}/bin/hyprctl dispatch moveactive exact "$((mx + w - right - half))" "$((my + top))"
    fi
  '';

  toggleMouseFocus = pkgs.writeShellScript "toggle-mouse-focus" ''
    cur=$(${hyprlandPkg}/bin/hyprctl getoption input:follow_mouse -j | ${pkgs.jq}/bin/jq -r '.int')
    if [ "$cur" = "0" ]; then
      ${hyprlandPkg}/bin/hyprctl keyword input:follow_mouse 1
      ${pkgs.libnotify}/bin/notify-send -t 1500 "Mouse focus: on"
    else
      ${hyprlandPkg}/bin/hyprctl keyword input:follow_mouse 0
      ${pkgs.libnotify}/bin/notify-send -t 1500 "Mouse focus: off"
    fi
  '';

  # Two races in hyprlock's async resources that leave a widget waiting on a
  # finished render for good: the finished listener is attached after the
  # gatherer thread may already be done (hyprwm/hyprlock#1071), and unload()
  # of a widget's null texture (the block images before their first render)
  # releases another widget's in-flight resource, such as the clock's.
  hyprlockPkg = pkgs.hyprlock.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./hyprlock-async-resources.patch];
  });

  blocks = config.hydrix.hyprland.hyprlockBlocks;
  # Shared bottom edge of the lockscreen blocks, below the password field
  # (center 0, -80, height 55) and the battery block's height above it.
  blocksBottom = -250;
  # Square canvas every block is drawn on. hyprlock scales an image so its
  # shorter side equals `size`; a fixed square keeps that scale at exactly 1.
  blockCanvas = 40 * 4 / 3 * lib.foldl' lib.max 1 (lib.mapAttrsToList (_: b: b.fontSize) blocks);

  # Renders the lockscreen blocks while hyprlock runs, into
  # $XDG_RUNTIME_DIR/hyprlock: every block command's pango markup becomes a
  # PNG with a rounded color0 background (hyprlock labels cannot have one).
  # Exits with the lock session that started it.
  lockWidgetsConfig = pkgs.writeText "hyprlock-widgets.json" (builtins.toJSON {
    canvas = blockCanvas;
    radius = lk.rounding;
    font = config.hydrix.graphical.font.family or "Iosevka";
    blocks = lib.mapAttrs (_: b: {inherit (b) command fontSize opacity group;}) blocks;
  });
  lockWidgetsPy = pkgs.writeText "hyprlock-widgets.py" ''
    import json, os, signal, subprocess, sys, threading
    import gi
    gi.require_version("Pango", "1.0")
    gi.require_version("PangoCairo", "1.0")
    from gi.repository import GLib, Pango, PangoCairo
    import cairo

    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    out = sys.argv[2]
    parent = os.getppid()
    stop = threading.Event()


    def colors():
        try:
            with open(os.path.expanduser("~/.cache/wal/colors.json")) as f:
                w = json.load(f)
            return w["colors"]["color0"], w["special"]["foreground"]
        except (OSError, ValueError, KeyError):
            return "#101010", "#dfdfdf"


    def rgb(h):
        h = h.lstrip("#")
        return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


    def replace(path, write):
        write(path + ".tmp")
        os.replace(path + ".tmp", path)


    def layout_for(ctx, block, markup):
        layout = PangoCairo.create_layout(ctx)
        font = Pango.FontDescription.from_string(cfg["font"])
        font.set_size(block["fontSize"] * Pango.SCALE)
        layout.set_font_description(font)
        try:
            layout.set_markup(markup, -1)
        except GLib.Error:
            layout.set_text(markup, -1)
        em = block["fontSize"] * 4 / 3
        return layout, round(em * 1.2), round(em * 0.8)


    def measure(block, markup):
        ctx = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))
        layout, px, py = layout_for(ctx, block, markup)
        _, text = layout.get_pixel_extents()
        return text.width + 2 * px, text.height + 2 * py


    # Draws the block bottom-centered on the canvas, so hyprlock positions it
    # by its bottom edge, at size w x h (its group's largest block).
    def render(path, block, markup, w, h, bg, fg):
        size = cfg["canvas"]
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        if markup:
            ctx = cairo.Context(surface)
            layout, px, py = layout_for(ctx, block, markup)
            _, text = layout.get_pixel_extents()
            scale = min(1, size / max(w, h))
            ctx.translate((size - w * scale) / 2, size - h * scale)
            ctx.scale(scale, scale)
            r = min(cfg["radius"], w / 2, h / 2)
            ctx.new_sub_path()
            ctx.arc(w - r, r, r, -1.5708, 0)
            ctx.arc(w - r, h - r, r, 0, 1.5708)
            ctx.arc(r, h - r, r, 1.5708, 3.1416)
            ctx.arc(r, r, r, 3.1416, 4.7124)
            ctx.close_path()
            ctx.set_source_rgba(*rgb(bg), block["opacity"])
            ctx.fill()
            ctx.set_source_rgb(*rgb(fg))
            ctx.move_to(px - text.x, py - text.y)
            PangoCairo.show_layout(ctx, layout)
        replace(path, surface.write_to_png)


    def run(command):
        try:
            return subprocess.run(["/bin/sh", "-c", command], capture_output=True,
                                  text=True, timeout=10).stdout.rstrip("\n")
        except (OSError, subprocess.TimeoutExpired):
            return ""


    def blocks():
        last = {}
        while not stop.is_set():
            bg, fg = colors()
            markups = {name: run(block["command"]) for name, block in cfg["blocks"].items()}
            sizes = {name: measure(cfg["blocks"][name], m) for name, m in markups.items() if m.strip()}
            # Shown blocks sharing a group take the group's widest and tallest size.
            own = dict(sizes)
            for name in sizes:
                group = cfg["blocks"][name]["group"]
                if group is not None:
                    peers = [own[n] for n in own if cfg["blocks"][n]["group"] == group]
                    sizes[name] = (max(w for w, _ in peers), max(h for _, h in peers))
            for name, block in cfg["blocks"].items():
                markup = markups[name] if name in sizes else ""
                w, h = sizes.get(name, (0, 0))
                if last.get(name) != (markup, w, h, bg, fg):
                    last[name] = (markup, w, h, bg, fg)
                    render(os.path.join(out, name + ".png"), block, markup, w, h, bg, fg)
            stop.wait(5)



    def quit(*_):
        stop.set()
        sys.exit(0)


    signal.signal(signal.SIGTERM, quit)
    signal.signal(signal.SIGINT, quit)
    threading.Thread(target=blocks, daemon=True).start()
    while os.getppid() == parent:
        stop.wait(1)
    quit()
  '';
  lockWidgets = pkgs.writeShellScript "hyprlock-widgets" ''
    export GI_TYPELIB_PATH=${lib.makeSearchPath "lib/girepository-1.0" [pkgs.pango.out pkgs.glib.out pkgs.harfbuzz pkgs.gobject-introspection]}
    exec ${pkgs.python3.withPackages (ps: [ps.pygobject3 ps.pycairo])}/bin/python3 ${lockWidgetsPy} ${lockWidgetsConfig} "$@"
  '';
  # BATTERY block: charge bar, status and time to empty/full, from the first
  # BAT* power supply. Prints nothing without one, which hides the block.
  hyprlockBattery = pkgs.writeShellApplication {
    name = "hyprlock-battery";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      bat=$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' | sort | head -n1)
      [ -n "$bat" ] || exit 0
      read_() { cat "$bat/$1" 2>/dev/null || echo 0; }
      cap=$(read_ capacity)
      status=$(read_ status)
      now=$(read_ energy_now); full=$(read_ energy_full); rate=$(read_ power_now)
      if [ "$now" = 0 ]; then now=$(read_ charge_now); full=$(read_ charge_full); rate=$(read_ current_now); fi
      wal="$HOME/.cache/wal/colors.json"
      [ -f "$wal" ] || wal=/dev/null
      jq -rn --argjson cap "$cap" --arg status "$status" --argjson now "$now" --argjson full "$full" \
        --argjson rate "$rate" --argjson w 32 --slurpfile wal "$wal" '
        def color($col): "<span color=\"\($col)\">\(.)</span>";
        def rep($n): if $n > 0 then . * $n else "" end;
        def hm: (. * 60 | floor) as $m | "\($m / 60 | floor)h \($m % 60 | tostring | if length < 2 then "0" + . else . end)m";
        ($wal[0] // {}) as $p
        | {fg: ($p.special.foreground // "#dfdfdf"), title: ($p.colors.color4 // "#7aa2f7"),
           on: ($p.colors.color2 // "#9ece6a"), dim: ($p.colors.color8 // "#808080"),
           warn: ($p.colors.color1 // "#f7768e")} as $c
        | (($cap | tostring) + "%") as $aside
        | ([$cap * $w / 100 | round, $w] | min) as $fill
        | (if $rate <= 0 then ""
           elif $status == "Discharging" then " · " + ($now / $rate | hm) + " left"
           elif $status == "Charging" then " · " + (($full - $now) / $rate | hm) + " to full"
           else "" end) as $eta
        | [ ("<b>" + ("BATTERY" | color($c.title)) + (" " * ($w - 7 - ($aside | length))) + ($aside | color($c.fg)) + "</b>"),
            (("█" | rep($fill) | color(if $status == "Discharging" and $cap <= 20 then $c.warn else $c.on end))
              + ("░" | rep($w - $fill) | color($c.dim))),
            ((if $status == "Not charging" then "plugged in · held at \($cap)%" else ($status | ascii_downcase) end) + $eta | color($c.dim)) ]
        | join("\n")' 2>/dev/null || true
    '';
  };

  # Idempotent lock script: flock prevents duplicate hyprlock instances.
  # Non-blocking (-n): if hyprlock already holds the lock, exits immediately.
  # The widget renderer lives exactly as long as hyprlock. hyprlock.conf
  # reads the rendered images through ~/.cache/hydrix/hyprlock, since its
  # paths cannot expand $XDG_RUNTIME_DIR.
  lockSession = pkgs.writeShellScript "hypr-lock-session" ''
    dir="$XDG_RUNTIME_DIR/hyprlock"
    rm -rf "$dir" && mkdir -p "$dir" "$HOME/.cache/hydrix"
    ln -sfn "$dir" "$HOME/.cache/hydrix/hyprlock"
    ${lockWidgets} "$dir" &
    widgets=$!
    trap 'kill $widgets 2>/dev/null; rm -rf "$dir"' EXIT
    ${hyprlockPkg}/bin/hyprlock
  '';
  lockScreen = pkgs.writeShellScript "hypr-lock" ''
    exec ${pkgs.util-linux}/bin/flock -n "$XDG_RUNTIME_DIR/hyprlock.lock" ${lockSession}
  '';

  # Idle dimming of the internal panel (brightnessctl via logind, no root).
  # `dim on` saves the current level and dims; `dim off` restores it only
  # after an actual dim, so a panel already darker than the target is kept.
  idleDim = pkgs.writeShellScript "hydrix-idle-dim" ''
    marker="$XDG_RUNTIME_DIR/hydrix-idle-dimmed"
    bctl=${pkgs.brightnessctl}/bin/brightnessctl
    case "$1" in
      on)
        cur=$($bctl -m -c backlight info | cut -d, -f4 | tr -d %)
        [ "''${cur:-0}" -gt ${toString lk.dim.brightness} ] || exit 0
        $bctl -q -c backlight -s set ${toString lk.dim.brightness}% && touch "$marker" ;;
      off)
        [ -e "$marker" ] || exit 0
        $bctl -q -c backlight -r; rm -f "$marker" ;;
    esac
  '';

  # Writes ~/.config/hypr/hypridle.conf with the current timeout then starts hypridle.
  # hypridle uses a config file rather than CLI args, so we regenerate it each time.
  startHypridle = pkgs.writeShellScript "start-hypridle" ''
        _t=$(cat "$HOME/.local/state/lock-timeout" 2>/dev/null || echo "${idleTimeout}")
        mkdir -p "$HOME/.config/hypr"
        cat > "$HOME/.config/hypr/hypridle.conf" <<EOF
    general {
      lock_cmd = ${lockScreen}
    }

    listener {
      timeout = $_t
      on-timeout = ${pkgs.systemd}/bin/loginctl lock-session
    }
    ${lib.optionalString (lk.dim.timeout != null) ''

      listener {
        timeout = ${toString lk.dim.timeout}
        on-timeout = ${idleDim} on
        on-resume = ${idleDim} off
      }''}
    EOF
        exec ${pkgs.hypridle}/bin/hypridle
  '';

  # lock-timeout [seconds] -- read or adjust the idle lock timeout at runtime.
  # Persists across Hyprland restarts via ~/.local/state/lock-timeout.
  # Compile-time default: ${idleTimeout}s. Run without args to show current value.
  lockTimeout = pkgs.writeShellScriptBin "lock-timeout" ''
    state="$HOME/.local/state/lock-timeout"
    if [ -z "$1" ]; then
      t=$(cat "$state" 2>/dev/null || echo "${idleTimeout}")
      echo "Lock timeout: ''${t}s"
      exit 0
    fi
    mkdir -p "$(dirname "$state")"
    echo "$1" > "$state"
    pkill -x hypridle 2>/dev/null || true
    sleep 0.1
    nohup ${startHypridle} >/dev/null 2>&1 &
    disown
    ${pkgs.libnotify}/bin/notify-send -t 2000 "Lock timeout" "''${1}s"
  '';

  hyprlandConf = pkgs.writeText "hyprland.conf" ''
    # ── Framework layer ────────────────────────────────────────────────────────
    # Colors, monitor, keyboard, VM routing - always regenerated on rebuild.
    source = ~/.config/hypr/hydrix-generated.conf
    # monitor-layout's saved positions (desc:-matched rules) - regenerated by
    # monitor-layout itself on set/capture/forget, not by rebuild. Loaded after
    # the framework layer's wildcard `monitor = ,preferred,auto,1` so a monitor
    # with a saved position is no longer an unmatched case for that fallback.
    source = ~/.config/hypr/monitor-layout.conf

    # ── Startup ────────────────────────────────────────────────────────────────
    exec-once = systemctl --user set-environment WAYLAND_DISPLAY=$WAYLAND_DISPLAY
    exec-once = systemctl --user start hyprland-session.target
    exec-once = sh -c 'wal -Rnq; hypr-apply-colors'
    exec-once = sh -c 'sleep 2 && hypr-apply-colors'
    exec-once = ${startHypridle}

    # ── General ────────────────────────────────────────────────────────────────
    general {
      gaps_in  = ${toString gapsIn}
      # top=0,right=gaps,bottom=?,left=gaps - comma-separated (Hyprland CSS-like format).
      # Top gap comes from the bar's exclusive zone + pill margin, not gaps_out.
      # Bottom gap: dualbar bottom bar provides it via exclusive zone; monobar needs gaps_out.
      gaps_out = 0, ${toString gaps}, ${toString gapsOutBottom}, ${toString gaps}
      border_size  = ${borderSize}
      col.active_border   = $activeBorder
      col.inactive_border = $inactiveBorder
      layout = dwindle
    }

    # ── Decoration ─────────────────────────────────────────────────────────────
    decoration {
      rounding         = ${rounding}
      rounding_power   = 4
      active_opacity   = ${toString ui.opacity.active}
      inactive_opacity = ${toString ui.opacity.inactive}

      blur {
        enabled  = true
        passes   = 1
        size     = 3
        vibrancy = 0.1696
      }

      shadow {
        enabled      = ${lib.boolToString shadowOn}
        range        = ${shadowRange}
        render_power = 2
        color        = rgba(000000${shadowAlpha})
      }
    }

    # ── Animations ─────────────────────────────────────────────────────────────
    animations {
      enabled = true
      bezier = easeOut, 0.25, 0.1, 0.25, 1.0
      animation = windows,    1, 3, easeOut
      animation = border,     1, 10, default
      animation = fade,       1, 2, easeOut
      animation = workspaces, 1, 4, easeOut
    }

    # ── Input ──────────────────────────────────────────────────────────────────
    # Keyboard: xkbFile (custom keymap written by home.activation.hyprlandKeymap)
    # takes precedence when set in machines/<serial>.nix; otherwise layout/variant
    # from hydrix.graphical.keyboard (populated from @XKB_LAYOUT@ by the installer).
    input {
      ${
      if kb.xkbFile != null
      then "kb_file     = ~/.config/hypr/keymap.xkb"
      else ''
        kb_layout   = ${kb.layout}
        ${lib.optionalString (kb.variant != "") "kb_variant  = ${kb.variant}"}
        ${lib.optionalString (kb.xkbOptions != "") "kb_options  = ${kb.xkbOptions}"}
      ''
    }
      follow_mouse   = 1
      sensitivity    = -0.2
      natural_scroll = false

      touchpad {
        natural_scroll = false
      }
    }

    # ── Cursor ─────────────────────────────────────────────────────────────────
    cursor {
      inactive_timeout = 3
    }

    # ── Layout ─────────────────────────────────────────────────────────────────
    dwindle {
      preserve_split = true
      force_split    = 2
    }

    # ── Misc ───────────────────────────────────────────────────────────────────
    misc {
      disable_hyprland_logo    = true
      disable_splash_rendering = true
      focus_on_activate        = true
    }

    ecosystem {
      no_update_news = true
    }

    # ── Variables ──────────────────────────────────────────────────────────────
    $mod = SUPER

    # ── Keybindings ────────────────────────────────────────────────────────────
    # Terminal
    bind = $mod,       Return, exec, hypr-ws-app alacritty
    bind = $mod SHIFT, Return, exec, alacritty
    bind = $mod,       S,      exec, hypr-float-terminal

    # Launcher / Focus
    bind = $mod, Q, killactive,
    bind = $mod,       D, exec, wofi-launcher
    bind = $mod SHIFT, D, exec, wofi-launcher --host
    bind = $mod, F4, exec, focus-wofi
    bind = $mod SHIFT, N, exec, swaync-client --skip-wait --toggle-panel

    # Browser (via VM)
    bind = $mod, B, exec, hypr-ws-app firefox

    # Applications
    bind = $mod,       M, exec, alacritty -e hydrix-tui
    bind = $mod SHIFT, M, exec, vm-select
    bind = $mod,       Z, exec, zathura

    # Vault credential picker
    bind = $mod,       P, exec, vault-pick

    # Cross-VM clipboard bridge (one-shot)
    bind = $mod SHIFT, P, exec, vm-clip-bridge

    # Brightness / Vibrancy
    bind = $mod,       F7, exec, hydrix-brightness-hypr -
    bind = $mod,       F8, exec, hydrix-brightness-hypr +
    bind = $mod SHIFT, F7, exec, hydrix-vibrancy-hypr -
    bind = $mod SHIFT, F8, exec, hydrix-vibrancy-hypr +

    # Monitor arrangement (drag-and-drop GUI; position is captured and remembered on exit)
    bind = $mod, F9, exec, monitor-layout gui

    # Audio (the `audio` command, modules/audio.nix)
    bind = $mod, F1, exec, audio mute
    bind = $mod, F2, exec, audio volume -
    bind = $mod, F3, exec, audio volume +

    # Toggle mouse focus follow
    bind = $mod CTRL, M, exec, ${toggleMouseFocus}

    # Screenshot
    bind = $mod, F12, exec, grim -g "$(slurp)" ~/screenshots/$(date +%Y%m%d_%H%M%S).png

    # System monitors
    bind = $mod SHIFT, U, exec, hypr-ws-app alacritty -e htop

    # Bluetooth TUI / router console (floating)
    bind = $mod SHIFT, B, exec, alacritty --class hypr-float -e bluetui
    bind = $mod SHIFT, R, exec, alacritty --class hypr-float -e shard -c router

    # File manager / file finder (via VM)
    bind = $mod SHIFT, F, exec, hypr-ws-app alacritty -e joshuto
    bind = $mod SHIFT, O, exec, file-finder

    # Git status in hydrix-config
    bind = $mod SHIFT, G, exec, alacritty -e fish -c 'clear && cd ${configDir} && git status && exec fish'

    # Wallpaper
    bind = $mod,       W, exec, randomwalrgb
    bind = $mod SHIFT, W, exec, wallpaper-black

    # Lock / Suspend / Exit
    bind = $mod SHIFT,      E, exec, ${lockScreen}
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
    bind = $mod SHIFT, SPACE, exec, ${dockRight}
    bind = $mod,       SPACE, cyclenext,
    bind = $mod,       R,     submap, resize

    # Gaps
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

    # Mouse - move/resize windows
    bindm = $mod, mouse:272, movewindow
    bindm = $mod, mouse:273, resizewindow

    # Mouse - scroll through workspaces
    bind = $mod, mouse_down, workspace, e+1
    bind = $mod, mouse_up,   workspace, e-1

    # ── Resize submap ────────────────────────────────────────────────────────
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

    # ── Window rules ─────────────────────────────────────────────────────────
    windowrule = float 1, match:class ^(pavucontrol)$
    windowrule = float 1, match:class ^(lxappearance)$
    windowrule = float 1, match:class ^(nm-connection-editor)$
    # hypr-float-terminal ($mod+S) - float + fixed size; position set by script
    windowrule = float 1, match:class ^(hypr-float)$
    windowrule = size 800 550, match:class ^(hypr-float)$
    # Alacritty manages its own opacity
    windowrule = opacity 1.0 override, match:class ^(Alacritty)$
    windowrule = opacity 1.0 override, match:class ^(alacritty)$
    windowrule = opacity 1.0 override, match:class ^(hypr-float)$
    windowrule = rounding ${lkRounding}, match:class ^(wofi)$
    windowrule = no_anim 1,             match:class ^(wofi)$
    layerrule = no_anim 1, match:namespace ^(wofi)$
    ${layerBlur}

    ${lib.optionalString config.hydrix.hyprland.hideBorderOnSingleWindow ''
      # Hide the border when a workspace has exactly one tiled window.
      windowrule = border_size 0, match:float 0, match:workspace w[tv1]
    ''}

    # VM windows forwarded via waypipe - titles start with [vm-name].
    # Blur and alpha compositing are recomputed on every frame during scrolling;
    # disabling them removes GPU overhead that causes scroll jank.
    windowrule = no_blur 1,                          match:title ^\[
    windowrule = opacity 1.0 override 1.0 override, match:title ^\[
    windowrule = no_anim 1,                          match:title ^\[

    ${config.hydrix.hyprland.extraBinds}
  '';

  hyprlock_conf = pkgs.writeText "hyprlock.conf" ''
    source = /home/${username}/.config/hypr/colors-lock.conf

    general {
      disable_loading_bar = false
      grace = 5
      hide_cursor = true
    }

    background {
      path = screenshot
      blur_passes = 2
      blur_size = 5
      brightness = 0.5
      vibrancy = 0.2
    }

    input-field {
      size = 300, 55
      position = 0, -80
      monitor =
      dots_center = true
      fade_on_empty = false
      placeholder_text = ${lk.text}
      fail_text = ${lk.wrongText}
      rounding = ${toString lk.rounding}
      outline_thickness = ${borderSize}
      font_family = ${lk.font}
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

    ${lib.concatStrings (lib.mapAttrsToList (name: b: ''
        image {
          monitor =
          path = ~/.cache/hydrix/hyprlock/${name}.png
          reload_time = 1
          size = ${toString blockCanvas}
          rounding = 0
          border_size = 0
          position = ${b.x}, ${toString (blocksBottom + blockCanvas / 2)}
          halign = center
          valign = center
        }
      '')
      blocks)}
  '';
in {
  options.hydrix.hyprland.hyprlockBlocks = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        command = lib.mkOption {
          type = lib.types.str;
          description = "Prints the block's pango markup, run every 5s while locked. Empty output hides the block.";
        };
        x = lib.mkOption {
          type = lib.types.str;
          description = "hyprlock x position of the block's center, relative to the screen center (px or %). Every block's bottom edge sits on one line below the password field.";
        };
        group = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Blocks in the same group are drawn at the size of the largest one shown.";
        };
        fontSize = lib.mkOption {
          type = lib.types.ints.positive;
          default = (config.hydrix.graphical.font.size or 10) * 3 / 2;
          description = "Font size in hyprlock's units (pt at 96 dpi on the output's native pixels).";
        };
        opacity = lib.mkOption {
          type = lib.types.numbers.between 0 1;
          default = 0.6;
          description = "Opacity of the rounded color0 background.";
        };
      };
    });
    default = {};
    description = "Lockscreen blocks: text panels with rounded backgrounds, for other modules to add lockscreen widgets.";
  };

  config = lib.mkIf config.hydrix.hyprland.enable {
    programs.hyprland.package = hyprlandPkg;

    # Centered below the password field.
    hydrix.hyprland.hyprlockBlocks.battery = lib.mkIf lk.battery.enable {
      command = "${hyprlockBattery}/bin/hyprlock-battery";
      x = "0";
    };

    environment.systemPackages = [lockTimeout monitorLayout pkgs.nwg-displays];
    security.pam.services.hyprlock = {};

    # Qt apps default to xcb unless told otherwise, which fails outright when
    # no XWayland client has started an X server yet. Prefer the native
    # wayland platform plugin, falling back to xcb only if unavailable.
    environment.variables.QT_QPA_PLATFORM = "wayland;xcb";

    # Allow wheel users to suspend from Hyprland keybinds (exec runs outside logind session context).
    # suspend-multiple-sessions covers the common case where VMs are running as separate sessions.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if ((action.id == "org.freedesktop.login1.suspend" ||
             action.id == "org.freedesktop.login1.suspend-multiple-sessions") &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';

    # Send Lock signal to all sessions before the system goes to sleep.
    # hypridle's lock_cmd fires in response and starts hyprlock.
    # The 2s pause gives hyprlock time to grab input before suspend completes.
    systemd.services."lock-before-sleep" = {
      description = "Lock screen before sleep";
      before = ["sleep.target" "suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target"];
      wantedBy = ["sleep.target" "suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "lock-before-sleep" ''
          ${pkgs.systemd}/bin/loginctl lock-sessions
          sleep 2
        '';
        TimeoutSec = 15;
      };
    };

    home-manager.users.${username} = {lib, ...}: {
      # Blue light filter, wlroots-native, works directly with Hyprland.
      # Override per-machine with plain assignment.
      services.wlsunset = {
        enable = lib.mkDefault true;
        sunrise = lib.mkDefault "07:00";
        sunset = lib.mkDefault "20:00";
        temperature.day = lib.mkDefault 6500;
        temperature.night = lib.mkDefault 3500;
      };

      # Files Hyprland reads are only rewritten when their content changed, and
      # set hydrixHyprReload so the framework's reloadHyprland step applies them.
      home.activation.hyprlandKeymap = lib.hm.dag.entryBetween ["reloadHyprland"] ["writeBoundary"] ''
        _dir="$HOME/.config/hypr"
        mkdir -p "$_dir"
        ${lib.optionalString (kb.xkbFile != null) ''
          if ! cmp -s ${kb.xkbFile} "$_dir/keymap.xkb"; then
            rm -f "$_dir/keymap.xkb"
            cat ${kb.xkbFile} > "$_dir/keymap.xkb"
            hydrixHyprReload=1
          fi
        ''}
        # monitor-layout owns this file after first run; only seed it so the
        # `source` line in hyprland.conf doesn't fail before that first run.
        [ -f "$_dir/monitor-layout.conf" ] || echo "# monitor-layout: no saved positions yet" > "$_dir/monitor-layout.conf"
      '';

      home.activation.hyprlandConfig = lib.hm.dag.entryBetween ["reloadHyprland"] ["hyprlandKeymap"] ''
        _dir="$HOME/.config/hypr"
        # Remove stale symlink if HM previously managed this file
        [ -L "$_dir/hyprland.conf" ] && rm -f "$_dir/hyprland.conf"
        # Skip write when content unchanged: the nix store path is a content hash.
        _stamp="$_dir/.hyprland-conf-stamp"
        if [ "$(cat "$_stamp" 2>/dev/null)" != "${hyprlandConf}" ]; then
          cat ${hyprlandConf} > "$_dir/hyprland.conf"
          echo "${hyprlandConf}" > "$_stamp"
          hydrixHyprReload=1
        fi
      '';

      home.activation.hyprlandLockConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/hypr"
        mkdir -p "$_dir"
        [ -L "$_dir/hyprlock.conf" ] && rm -f "$_dir/hyprlock.conf"
        cat ${hyprlock_conf} > "$_dir/hyprlock.conf"
      '';

      # Target activated by Hyprland exec-once; waybar and other services WantedBy this.
      systemd.user.targets.hyprland-session = {
        Unit = {
          Description = "Hyprland compositor session";
          BindsTo = ["graphical-session.target"];
          After = ["graphical-session-pre.target"];
          Wants = ["graphical-session-pre.target"];
        };
      };

      # Systemd user service - starts automatically with hyprland-session.target,
      # restartable immediately after rebuild without a Hyprland restart.
      systemd.user.services.waybar-monitor-watch = {
        Unit = {
          Description = "Restart waybar on Hyprland monitor/config events";
          After = ["hyprland-session.target"];
          PartOf = ["hyprland-session.target"];
        };
        Service = {
          Type = "simple";
          ExecStart = "${waybarMonitorWatch}";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = ["hyprland-session.target"];
      };
    };
  };
}
