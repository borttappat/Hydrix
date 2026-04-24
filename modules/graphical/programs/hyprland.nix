# Hyprland Home Manager Configuration
#
# Configures Hyprland compositor via home-manager.
# Keybindings mirror the i3 setup (shared/i3.nix is the reference).
# Workspace border colors identify which VM type is on each workspace.
#
# Workspace → VM type mapping:
#   WS 1  = host
#   WS 2  = pentest
#   WS 3  = browsing
#   WS 4  = comms
#   WS 5  = dev
#   WS 6  = lurking
#   WS 10 = router (reserved)
#
# Notes on X11-only tools (kept as binds, no-op until ported):
#   hydrix-vibrancy  — uses xrandr, Wayland port needed
#   blugon-set       — uses xrandr gamma, use hyprsunset in future
#
{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  cfg = config.hydrix.graphical;
  sc = config.hydrix.graphical.scaling.computed;

  gaps      = toString (config.hydrix.graphical.ui.gaps or 8);
  borderSize = toString (sc.border_size or 2);
  rounding  = toString (sc.corner_radius or 8);

  configDir = config.hydrix.paths.configDir;
  hostname  = config.hydrix.hostname;

  # Gap adjuster: reads current hyprctl value, increments/decrements
  hyprlandGapsAdjust = pkgs.writeShellScriptBin "hyprland-gaps-adjust" ''
    TYPE="$1"   # inner | outer
    DIR="$2"    # plus  | minus
    AMT="''${3:-5}"

    case "$TYPE" in
      inner) KEY="general:gaps_in" ;;
      outer) KEY="general:gaps_out" ;;
      *) exit 1 ;;
    esac

    CURRENT=$(${pkgs.hyprland}/bin/hyprctl -j getoption "$KEY" \
      | ${pkgs.jq}/bin/jq '.int')
    case "$DIR" in
      plus)  NEW=$((CURRENT + AMT)) ;;
      minus) NEW=$(( CURRENT - AMT < 0 ? 0 : CURRENT - AMT )) ;;
      *) exit 1 ;;
    esac

    ${pkgs.hyprland}/bin/hyprctl keyword "$KEY" "$NEW"
  '';
in lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
  environment.systemPackages = [ hyprlandGapsAdjust ];

  home-manager.users.${username} = { pkgs, config, ... }: {
    wayland.windowManager.hyprland = {
      enable = true;

      settings = {
        # ── Monitor ──────────────────────────────────────────────────────────
        monitor = [ ",preferred,auto,1" ];

        # ── General ──────────────────────────────────────────────────────────
        general = {
          gaps_in   = gaps;
          gaps_out  = 0;
          border_size = borderSize;
          "col.active_border"   = "rgba(7aa2f7ff)";  # overridden by hypr-focus-daemon
          "col.inactive_border" = "rgba(1a1b26aa)";
          layout = "dwindle";
        };

        # ── Decoration ───────────────────────────────────────────────────────
        decoration = {
          rounding = rounding;
          blur.enabled   = false;
          shadow.enabled = false;
        };

        # ── Animations ───────────────────────────────────────────────────────
        animations.enabled = false;

        # ── Input ────────────────────────────────────────────────────────────
        input = {
          kb_layout = "se";
          follow_mouse = 1;
          touchpad.natural_scroll = true;
        };

        # ── Layout ───────────────────────────────────────────────────────────
        dwindle = {
          pseudotile     = false;
          preserve_split = true;
        };

        # ── Misc ─────────────────────────────────────────────────────────────
        misc = {
          disable_hyprland_logo    = true;
          disable_splash_rendering = true;
          focus_on_activate        = true;
          font_family              = cfg.font.family;
        };

        # ── Variables ────────────────────────────────────────────────────────
        "$mod" = "SUPER";

        # ── Keybindings ──────────────────────────────────────────────────────
        bind = [
          # === Terminal ===
          "$mod, Return,       exec, hypr-ws-app alacritty"
          "$mod SHIFT, Return, exec, alacritty"
          "$mod, S,            exec, hydrix-float-terminal"

          # === Launcher ===
          "$mod, Q,       killactive,"
          "$mod, D,       exec, host-rofi"

          # === Browser (via VM) ===
          "$mod, B, exec, hypr-ws-app firefox"
          "$mod, A, exec, hypr-ws-app firefox https://claude.ai"
          "$mod, T, exec, hypr-ws-app firefox https://borttappat.github.io/links.html"
          "$mod, G, exec, hypr-ws-app firefox https://github.com/borttappat/Hydrix"
          "$mod, N, exec, hypr-ws-app firefox https://search.nixos.org/packages?channel=unstable"

          # === Applications ===
          "$mod, O,       exec, obsidian"
          "$mod, M,       exec, alacritty -e hydrix-tui"
          "$mod SHIFT, M, exec, vm-launch"
          "$mod, Z,       exec, zathura"

          # === Focus mode ===
          "$mod, F4, exec, focus-rofi"

          # === Volume (zenaudio) ===
          "$mod, F1, exec, zenaudio mute"
          "$mod, F2, exec, zenaudio volume -"
          "$mod, F3, exec, zenaudio volume +"

          # === Brightness ===
          "$mod, F7,       exec, brightnessctl set 10%-"
          "$mod, F8,       exec, brightnessctl set +10%"

          # === Vibrancy / Blue light (X11-only tools — no-op until ported) ===
          "$mod SHIFT, F7, exec, hydrix-vibrancy -"
          "$mod SHIFT, F8, exec, hydrix-vibrancy +"
          "$mod, F5,       exec, blugon-set -"
          "$mod, F6,       exec, blugon-set +"
          "$mod SHIFT, F6, exec, blugon-set reset"

          # === Screenshot ===
          "$mod, F12, exec, grim -g \"$(slurp)\" ~/screenshots/$(date +%Y%m%d_%H%M%S).png"

          # === System monitors ===
          "$mod SHIFT, U, exec, alacritty -e htop"
          "$mod SHIFT, B, exec, alacritty -e btm"

          # === Config editing ===
          "$mod SHIFT, I,     exec, alacritty -e vim ${configDir}/shared/i3.nix"
          "$mod SHIFT, N,     exec, alacritty -e vim ${configDir}/flake.nix"
          "$mod SHIFT, comma, exec, alacritty -e vim ${configDir}/machines/${hostname}.nix"

          # === File manager / search ===
          "$mod SHIFT, F, exec, hypr-ws-app alacritty -e joshuto"
          "$mod SHIFT, O, exec, file-finder"

          # === Git status ===
          "$mod SHIFT, G, exec, alacritty -e fish -c 'clear && cd ${configDir} && git status && exec fish'"

          # === Wallpaper ===
          "$mod, W, exec, randomwalrgb"

          # === Lock / suspend ===
          "$mod SHIFT, E, exec, hyprlock"
          "$mod SHIFT, S, exec, systemctl suspend"

          # === Focus (hjkl + arrows) ===
          "$mod, H,     movefocus, l"
          "$mod, J,     movefocus, d"
          "$mod, K,     movefocus, u"
          "$mod, L,     movefocus, r"
          "$mod, left,  movefocus, l"
          "$mod, down,  movefocus, d"
          "$mod, up,    movefocus, u"
          "$mod, right, movefocus, r"

          # === Move windows (hjkl) ===
          "$mod SHIFT, H, movewindow, l"
          "$mod SHIFT, J, movewindow, d"
          "$mod SHIFT, K, movewindow, u"
          "$mod SHIFT, L, movewindow, r"

          # === Layout ===
          "$mod, C,           layoutmsg, preselect d"
          "$mod, V,           layoutmsg, preselect r"
          "$mod, F,           fullscreen, 0"
          "$mod SHIFT, SPACE, togglefloating,"
          "$mod, SPACE,       cyclenext,"
          "$mod, R,           submap, resize"

          # === Gaps (arrows — hjkl reserved for move) ===
          "$mod SHIFT, up,    exec, hyprland-gaps-adjust inner plus 5"
          "$mod SHIFT, down,  exec, hyprland-gaps-adjust inner minus 5"
          "$mod SHIFT, right, exec, hyprland-gaps-adjust outer plus 5"
          "$mod SHIFT, left,  exec, hyprland-gaps-adjust outer minus 5"

          # === Scratchpad ===
          "$mod SHIFT, minus, movetoworkspace, special"
          "$mod, minus,       togglespecialworkspace,"

          # === Workspaces ===
          "$mod, 1, workspace, 1"
          "$mod, 2, workspace, 2"
          "$mod, 3, workspace, 3"
          "$mod, 4, workspace, 4"
          "$mod, 5, workspace, 5"
          "$mod, 6, workspace, 6"
          "$mod, 7, workspace, 7"
          "$mod, 8, workspace, 8"
          "$mod, 9, workspace, 9"
          "$mod, 0, workspace, 10"

          # === Move to workspace ===
          "$mod SHIFT, 1, movetoworkspace, 1"
          "$mod SHIFT, 2, movetoworkspace, 2"
          "$mod SHIFT, 3, movetoworkspace, 3"
          "$mod SHIFT, 4, movetoworkspace, 4"
          "$mod SHIFT, 5, movetoworkspace, 5"
          "$mod SHIFT, 6, movetoworkspace, 6"
          "$mod SHIFT, 7, movetoworkspace, 7"
          "$mod SHIFT, 8, movetoworkspace, 8"
          "$mod SHIFT, 9, movetoworkspace, 9"
          "$mod SHIFT, 0, movetoworkspace, 10"
        ];

        # ── Mouse ─────────────────────────────────────────────────────────────
        bindm = [
          "$mod, mouse:272, movewindow"
          "$mod, mouse:273, resizewindow"
        ];

        # ── Window rules ──────────────────────────────────────────────────────
        windowrulev2 = [
          "float, class:^(pavucontrol)$"
          "float, class:^(lxappearance)$"
          "float, class:^(nm-connection-editor)$"
        ];

        # ── Startup ───────────────────────────────────────────────────────────
        exec-once = [
          "${pkgs.dunst}/bin/dunst"
          "${pkgs.waybar}/bin/waybar"
          "vm-push-display-mode"
        ];
      };

      # Resize submap — must be raw config (submap begin/end not representable as attrset)
      extraConfig = ''
        submap = resize
        binde = , H, resizeactive, -10 0
        binde = , L, resizeactive,  10 0
        binde = , K, resizeactive,  0 -10
        binde = , J, resizeactive,  0  10
        bind  = , escape, submap, reset
        bind  = , Return, submap, reset
        submap = reset
      '';
    };
  };
}
