# Hyprland user configuration — compositor settings, keybindings, window rules, lockscreen.
#
# Config files are written as plain writable files via home.activation.
# You can edit ~/.config/hypr/hyprland.conf and ~/.config/hypr/hyprlock.conf freely
# between rebuilds. Rebuild will overwrite them with the current values here.
#
# ~/.config/hypr/hydrix-generated.conf is managed by the framework (VM rules,
# keyboard, monitor) and always regenerated — do not edit it.
#
# Keyboard layout is set via hydrix.graphical.keyboard in machines/<serial>.nix:
#   hydrix.graphical.keyboard.layout = "us";          # simple layout
#   hydrix.graphical.keyboard.xkbOptions = "caps:ctrl_modifier"; # optional extras
#   hydrix.graphical.keyboard.xkbFile = pkgs.writeText "keymap" ''...xkb_keymap {...}...'';
#
# Set all compositor preferences, keybindings, and appearance here.
# Machine-specific overrides go in machines/<serial>.nix via lib.mkAfter on extraConfig.
#
{ config, lib, pkgs, ... }:
let
  username    = config.hydrix.username;
  sc          = config.hydrix.graphical.scaling.computed;
  ui          = config.hydrix.graphical.ui;
  gaps        = ui.gaps or 10;
  borderSize  = toString (sc.border or 2);
  rounding    = toString (sc.cornerRadius or 0);
  lkRounding  = toString (if (ui.cornerRadius or 0) > 0 then ui.cornerRadius * 2 else 2);

  lk          = config.hydrix.graphical.lockscreen;
  idleTimeout = toString (lk.idleTimeout or 600);
  configDir   = config.hydrix.paths.configDir;
  kb          = config.hydrix.graphical.keyboard;

  # Restarts waybar (via systemd) on monitor plug/unplug.
  # Waybar picks up the transient reconfiguration state and doesn't recover once
  # Hyprland settles — a systemctl restart after the monitors stabilise fixes it.
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

  hyprlandConf = pkgs.writeText "hyprland.conf" ''
    # ── Framework layer ────────────────────────────────────────────────────────
    # Colors, monitor, keyboard, VM routing — always regenerated on rebuild.
    source = ~/.config/hypr/hydrix-generated.conf

    # ── Startup ────────────────────────────────────────────────────────────────
    exec-once = systemctl --user set-environment WAYLAND_DISPLAY=$WAYLAND_DISPLAY
    exec-once = sh -c 'wal -Rnq; hypr-apply-colors'
    exec-once = sh -c 'WALL=$(cat "$HOME/.cache/wal/wal" 2>/dev/null); [ -n "$WALL" ] && swaybg -i "$WALL" -m fill'
    exec-once = ${pkgs.dunst}/bin/dunst
    exec-once = sh -c 'sleep 2 && hypr-apply-colors'
    exec-once = swayidle -w timeout ${idleTimeout} 'hyprlock --force-focus' before-sleep 'hyprlock --force-focus'

    # ── General ────────────────────────────────────────────────────────────────
    general {
      gaps_in  = ${toString (gaps / 2)}
      # top=0,right=gaps,bottom=0,left=gaps — comma-separated (Hyprland CSS-like format).
      # Top/bottom gap comes from the bar's exclusive zone + pill margin, not gaps_out.
      gaps_out = 0, ${toString gaps}, 0, ${toString gaps}
      border_size  = ${borderSize}
      col.active_border   = $activeBorder
      col.inactive_border = $inactiveBorder
      layout = dwindle
    }

    # ── Decoration ─────────────────────────────────────────────────────────────
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
      ${if kb.xkbFile != null
        then "kb_file     = ~/.config/hypr/keymap.xkb"
        else ''
          kb_layout   = ${kb.layout}
          ${lib.optionalString (kb.variant != "") "kb_variant  = ${kb.variant}"}
          ${lib.optionalString (kb.xkbOptions != "") "kb_options  = ${kb.xkbOptions}"}
        ''}
      follow_mouse   = 0
      sensitivity    = -0.2
      natural_scroll = true

      touchpad {
        natural_scroll = true
      }
    }

    # ── Layout ─────────────────────────────────────────────────────────────────
    dwindle {
      pseudotile     = false
      preserve_split = true
      force_split    = 2
    }

    # ── Misc ───────────────────────────────────────────────────────────────────
    misc {
      disable_hyprland_logo    = true
      disable_splash_rendering = true
      focus_on_activate        = true
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
    bind = $mod, D, exec, wofi-launcher
    bind = $mod SHIFT, D, exec, wofi-launcher --host
    bind = $mod, F4, exec, focus-wofi

    # Browser (via VM)
    bind = $mod, B, exec, hypr-ws-app firefox

    # Applications
    bind = $mod,       O, exec, obsidian
    bind = $mod,       M, exec, alacritty -e hydrix-tui
    bind = $mod,       Z, exec, zathura

    # Vault (Bitwarden)
    bind = $mod SHIFT, P, exec, vault-rofi

    # Brightness / Vibrancy
    bind = $mod,       F7, exec, hydrix-brightness-hypr -
    bind = $mod,       F8, exec, hydrix-brightness-hypr +
    bind = $mod SHIFT, F7, exec, hydrix-vibrancy-hypr -
    bind = $mod SHIFT, F8, exec, hydrix-vibrancy-hypr +

    # Volume — uncomment and adapt for your audio setup:
    # Standard PulseAudio/PipeWire:
    # bind = $mod, F1, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle
    # bind = $mod, F2, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%
    # bind = $mod, F3, exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
    # ASUS ZenBook cs42l43 (zenaudio):
    # bind = $mod, F1, exec, zenaudio mute
    # bind = $mod, F2, exec, zenaudio volume -
    # bind = $mod, F3, exec, zenaudio volume +

    # Screenshot
    bind = $mod, F12, exec, grim -g "$(slurp)" ~/screenshots/$(date +%Y%m%d_%H%M%S).png

    # System monitors
    bind = $mod SHIFT, U, exec, hypr-ws-app alacritty -e htop
    bind = $mod SHIFT, B, exec, alacritty -e btm

    # File manager / file finder (via VM)
    bind = $mod SHIFT, F, exec, hypr-ws-app alacritty -e joshuto
    bind = $mod SHIFT, O, exec, file-finder

    # Git status in hydrix-config
    bind = $mod SHIFT, G, exec, alacritty -e fish -c 'clear && cd ${configDir} && git status && exec fish'

    # Wallpaper
    bind = $mod,       W, exec, randomwalrgb
    bind = $mod SHIFT, W, exec, wallpaper-black

    # Lock / Suspend / Exit
    bind = $mod SHIFT,      E, exec, hyprlock
    bind = $mod SHIFT,      S, exec, hyprlock && systemctl suspend
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

    # Mouse — move/resize windows
    bindm = $mod, mouse:272, movewindow
    bindm = $mod, mouse:273, resizewindow

    # Mouse — scroll through workspaces
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
    windowrulev2 = float, class:^(pavucontrol)$
    windowrulev2 = float, class:^(lxappearance)$
    windowrulev2 = float, class:^(nm-connection-editor)$
    # hypr-float-terminal ($mod+S) — float + fixed size; position set by script
    windowrulev2 = float, class:^(hypr-float)$
    windowrulev2 = size 800 550, class:^(hypr-float)$
    # Alacritty manages its own opacity
    windowrulev2 = opacity 1.0 override, class:^(Alacritty)$
    windowrulev2 = opacity 1.0 override, class:^(alacritty)$
    windowrulev2 = opacity 1.0 override, class:^(hypr-float)$
    windowrulev2 = rounding ${lkRounding}, class:^(dunst)$
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
      rounding = ${lkRounding}
      border_size = ${borderSize}
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
in {
  home-manager.users.${username} = { lib, ... }: {
    home.activation.hyprlandKeymap = lib.hm.dag.entryAfter ["writeBoundary"] ''
      _dir="$HOME/.config/hypr"
      mkdir -p "$_dir"
      ${lib.optionalString (kb.xkbFile != null) ''
        rm -f "$_dir/keymap.xkb"
        cat ${kb.xkbFile} > "$_dir/keymap.xkb"
      ''}
    '';

    home.activation.hyprlandConfig = lib.hm.dag.entryAfter ["hyprlandKeymap"] ''
      _dir="$HOME/.config/hypr"
      # Remove stale symlink if HM previously managed this file
      [ -L "$_dir/hyprland.conf" ] && rm -f "$_dir/hyprland.conf"
      cat ${hyprlandConf} > "$_dir/hyprland.conf"
    '';

    home.activation.hyprlandLockConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
      _dir="$HOME/.config/hypr"
      mkdir -p "$_dir"
      [ -L "$_dir/hyprlock.conf" ] && rm -f "$_dir/hyprlock.conf"
      cat ${hyprlock_conf} > "$_dir/hyprlock.conf"
    '';

    # Systemd user service — starts automatically with hyprland-session.target,
    # restartable immediately after rebuild without a Hyprland restart.
    systemd.user.services.waybar-monitor-watch = {
      Unit = {
        Description = "Restart waybar on Hyprland monitor/config events";
        After = [ "hyprland-session.target" ];
        PartOf = [ "hyprland-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${waybarMonitorWatch}";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}
