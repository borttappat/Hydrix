# Hyprland Home Manager Configuration
#
# Configures Hyprland compositor via home-manager.
# Keybindings mirror the i3 setup. Workspace border colors
# identify which VM type is on each workspace.
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
{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  cfg = config.hydrix.graphical;
  sc = config.hydrix.graphical.scaling.computed;

  # Gap / border values from scaling (same source as i3)
  gaps = toString (config.hydrix.graphical.ui.gaps or 8);
  borderSize = toString (sc.border_size or 2);
  rounding = toString (sc.corner_radius or 8);
in lib.mkIf (config.hydrix.graphical.enable && config.hydrix.hyprland.enable) {
  home-manager.users.${username} = { pkgs, config, ... }: {
    wayland.windowManager.hyprland = {
      enable = true;

      settings = {
        # ── Monitor ─────────────────────────────────────────────────────────
        # "preferred" = use preferred resolution/refresh; position auto
        monitor = [ ",preferred,auto,1" ];

        # ── General ─────────────────────────────────────────────────────────
        general = {
          gaps_in = gaps;
          gaps_out = 0;
          border_size = borderSize;
          "col.active_border" = "rgba(7aa2f7ff)";    # Updated by hypr-focus-daemon
          "col.inactive_border" = "rgba(1a1b26aa)";
          layout = "dwindle";
        };

        # ── Decoration ──────────────────────────────────────────────────────
        decoration = {
          rounding = rounding;
          blur.enabled = false;     # CPU savings — enable if GPU present
          shadow.enabled = false;
        };

        # ── Animations ──────────────────────────────────────────────────────
        animations = {
          enabled = false;    # Disable for minimal CPU; enable in Step 2 config
        };

        # ── Input ───────────────────────────────────────────────────────────
        input = {
          kb_layout = "se";   # Swedish layout — override in machine config
          follow_mouse = 1;
          touchpad.natural_scroll = true;
        };

        # ── Dwindle layout ──────────────────────────────────────────────────
        dwindle = {
          pseudotile = false;
          preserve_split = true;
        };

        # ── Misc ────────────────────────────────────────────────────────────
        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          focus_on_activate = true;
        };

        # ── Keybindings ─────────────────────────────────────────────────────
        "$mod" = "SUPER";

        bind = [
          # Terminal
          "$mod, Return, exec, ws-app alacritty"
          "$mod SHIFT, Return, exec, alacritty"

          # Quit / kill
          "$mod, Q, killactive"

          # Launcher
          "$mod, D, exec, wofi --show drun"

          # Browser
          "$mod, B, exec, ws-app firefox"
          "$mod, A, exec, ws-app firefox https://claude.ai"
          "$mod, T, exec, ws-app firefox https://borttappat.github.io/links.html"
          "$mod, G, exec, ws-app firefox https://github.com/borttappat/Hydrix"
          "$mod, N, exec, ws-app firefox https://search.nixos.org/packages?channel=unstable"

          # Applications
          "$mod, O, exec, obsidian"
          "$mod, Z, exec, zathura"

          # Screenshot
          "$mod, F12, exec, grim -g \"$(slurp)\" ~/screenshots/$(date +%Y%m%d_%H%M%S).png"

          # Volume (zenaudio)
          "$mod, F1, exec, zenaudio mute"
          "$mod, F2, exec, zenaudio volume -"
          "$mod, F3, exec, zenaudio volume +"

          # Brightness
          "$mod, F7, exec, brightnessctl set 10%-"
          "$mod, F8, exec, brightnessctl set +10%"

          # Lock / suspend
          "$mod SHIFT, E, exec, hyprlock"
          "$mod SHIFT, S, exec, systemctl suspend"

          # Fullscreen / float
          "$mod, F, fullscreen, 0"
          "$mod SHIFT, SPACE, togglefloating"

          # Layout splits
          "$mod, C, layoutmsg, preselect d"
          "$mod, V, layoutmsg, preselect r"

          # Focus (hjkl + arrows)
          "$mod, H, movefocus, l"
          "$mod, J, movefocus, d"
          "$mod, K, movefocus, u"
          "$mod, L, movefocus, r"
          "$mod, left, movefocus, l"
          "$mod, down, movefocus, d"
          "$mod, up, movefocus, u"
          "$mod, right, movefocus, r"

          # Move windows
          "$mod SHIFT, H, movewindow, l"
          "$mod SHIFT, J, movewindow, d"
          "$mod SHIFT, K, movewindow, u"
          "$mod SHIFT, L, movewindow, r"

          # Workspaces
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

          # Move to workspace
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

        # Mouse bindings
        bindm = [
          "$mod, mouse:272, movewindow"
          "$mod, mouse:273, resizewindow"
        ];

        # ── Window rules ─────────────────────────────────────────────────────
        # Workspace border colors identify VM type — updated by hypr-focus-daemon
        # Static fallbacks here; the daemon overrides with wal colors at runtime.
        windowrulev2 = [
          # Floating windows
          "float, class:^(pavucontrol)$"
          "float, class:^(lxappearance)$"
          "float, class:^(nm-connection-editor)$"
        ];

        # ── Startup ──────────────────────────────────────────────────────────
        exec-once = [
          "dunst"
          "${pkgs.procps}/bin/pkill waybar; waybar"
        ];
      };
    };
  };
}
