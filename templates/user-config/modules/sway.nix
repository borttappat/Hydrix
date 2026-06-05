# Sway Keybindings and Lockscreen — Shared across all machines
#
# Mirrors shared/i3.nix — same layout, same VM routing via sway-ws-app.
# Machine-specific overrides go in machines/<serial>.nix.
#
# Sway differences vs i3:
#   - No --no-startup-id (Wayland handles this natively)
#   - No alacritty-dpi (Wayland handles DPI natively)
#   - app_id instead of instance= for floating rules
#
{ config, lib, pkgs, ... }:
let
  username = config.hydrix.username;
  lk = config.hydrix.graphical.lockscreen;
  mod = "Mod4";

  # sway-lock: blurred screenshot lockscreen using swaylock-effects.
  # Mirrors i3's lock/lock-instant: wal colors, clock, ring indicator.
  swayLock = pkgs.writeShellScriptBin "sway-lock" ''
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      color0="#0c0c0c"; color1="#bf616a"
      color3="#ebcb8b"; color4="#7aa2f7"
      color7="#d8dee9"
    fi
    BG="''${color0#\#}"
    WRONG="''${color1#\#}"
    KEY="''${color3#\#}"

    FONT="${lk.font}"
    CLOCK_SIZE=${toString lk.clockSize}
    FONT_SIZE=${toString lk.fontSize}
    LOCK_TEXT="${lk.text}"

    SHOT=/tmp/sway-lock-shot.png
    BLUR=/tmp/sway-lock-blur.png
    FINAL=/tmp/sway-lock-final.png

    ${pkgs.grim}/bin/grim "$SHOT" 2>/dev/null || true

    COMMON_ARGS=(
      --clock
      --timestr         "%H:%M:%S"
      --datestr         "%A, %Y-%m-%d"
      --font            "$FONT"
      --font-size       "$CLOCK_SIZE"
      --inside-color    "00000000"
      --ring-color      "00000000"
      --line-color      "00000000"
      --separator-color "00000000"
      --key-hl-color    "''${KEY}ff"
      --bs-hl-color     "''${WRONG}ff"
      --text-color      "''${KEY}ff"
      --inside-wrong-color "''${WRONG}33"
      --ring-wrong-color   "''${WRONG}ff"
      --inside-ver-color   "''${BG}aa"
      --ring-ver-color     "''${KEY}aa"
      --indicator
      --indicator-radius 60
      --indicator-thickness 5
    )

    if [ -f "$SHOT" ]; then
      # Blur then burn lock text into image (same approach as i3lock scripts)
      ${pkgs.imagemagick}/bin/magick "$SHOT" -scale 20% -scale 500% "$BLUR" 2>/dev/null || cp "$SHOT" "$BLUR"
      if ! ${pkgs.imagemagick}/bin/magick "$BLUR" -gravity NorthWest \
          -pointsize "$FONT_SIZE" -font "$FONT" -fill "$color1" \
          -annotate +50+50 "$LOCK_TEXT" "$FINAL" 2>/dev/null; then
        cp "$BLUR" "$FINAL"
      fi
      ${pkgs.swaylock-effects}/bin/swaylock \
        --image "$FINAL" \
        --color "''${BG}ff" \
        "''${COMMON_ARGS[@]}"
    else
      ${pkgs.swaylock-effects}/bin/swaylock \
        --color "''${BG}ff" \
        "''${COMMON_ARGS[@]}"
    fi

    rm -f "$SHOT" "$BLUR" "$FINAL"
  '';
in lib.mkIf config.hydrix.sway.enable {
  environment.systemPackages = [ swayLock pkgs.swaylock-effects pkgs.swayidle pkgs.grim pkgs.imagemagick ];
  # Required for swaylock to authenticate via PAM
  security.pam.services.swaylock = {};

  home-manager.users.${username} = { lib, ... }: {
    wayland.windowManager.sway.config.startup = [
      # Lock on idle (10 min) and before suspend
      { command = "swayidle -w timeout 600 'sway-lock' before-sleep 'sway-lock'"; }
    ];

    wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
      # === Terminal ===
      "${mod}+Return"       = "exec sway-ws-app alacritty";
      "${mod}+Shift+Return" = "exec alacritty";

      # === Launcher ===
      "${mod}+q"       = "kill";
      "${mod}+d"       = "exec wofi-launcher";
      "${mod}+Shift+d" = null;

      # === Applications ===
      "${mod}+o"       = "exec obsidian";
      "${mod}+z"       = "exec zathura";
      "${mod}+Shift+p" = "exec vault-pick";

      # === Volume ===
      # Customise for your audio setup (zenaudio for ASUS cs42l43, pactl for PulseAudio, etc.)
      # "${mod}+F1" = "exec pactl set-sink-mute @DEFAULT_SINK@ toggle";
      # "${mod}+F2" = "exec pactl set-sink-volume @DEFAULT_SINK@ -5%";
      # "${mod}+F3" = "exec pactl set-sink-volume @DEFAULT_SINK@ +5%";

      # === Screenshot ===
      "${mod}+F12" = "exec grim -g \"$(slurp)\" ~/screenshots/$(date +%Y%m%d_%H%M%S).png";

      # === Brightness / Vibrancy ===
      "${mod}+F7"       = "exec hydrix-brightness-sway -";
      "${mod}+F8"       = "exec hydrix-brightness-sway +";
      "${mod}+Shift+F7" = "exec hydrix-vibrancy-sway -";
      "${mod}+Shift+F8" = "exec hydrix-vibrancy-sway +";

      # === Lock / Suspend ===
      "${mod}+Shift+e"       = "exec sway-lock";
      "${mod}+Shift+s"       = "exec systemctl suspend";
      "${mod}+ctrl+Shift+e"  = "exec exit-wayland";

      # === Wallpaper ===
      "${mod}+w"       = "exec randomwalrgb";
      "${mod}+Shift+w" = "exec swaybg -i ~/wallpapers/Black.jpg -m fill";

      # === Navigation (hjkl) ===
      "${mod}+h" = "focus left";
      "${mod}+j" = "focus down";
      "${mod}+k" = "focus up";
      "${mod}+l" = "focus right";

      # === Move (hjkl) ===
      "${mod}+Shift+h" = "move left";
      "${mod}+Shift+j" = "move down";
      "${mod}+Shift+k" = "move up";
      "${mod}+Shift+l" = "move right";

      # === Layout ===
      "${mod}+c"           = "split v";
      "${mod}+v"           = "split h";
      "${mod}+f"           = "fullscreen toggle";
      "${mod}+Shift+space" = "floating toggle";
      "${mod}+space"       = "focus mode_toggle";
      "${mod}+r"           = "mode resize";

      # === Quick resize ===
      "${mod}+ctrl+h" = "resize shrink width 5 ppt";
      "${mod}+ctrl+j" = "resize grow height 5 ppt";
      "${mod}+ctrl+k" = "resize shrink height 5 ppt";
      "${mod}+ctrl+l" = "resize grow width 5 ppt";

      # === Gaps ===
      "${mod}+Shift+Up"    = "gaps inner current plus 5";
      "${mod}+Shift+Down"  = "gaps inner current minus 5";
      "${mod}+Shift+Right" = "gaps outer current plus 5";
      "${mod}+Shift+Left"  = "gaps outer current minus 5";

      # === Scratchpad ===
      "${mod}+Shift+minus" = "move scratchpad";
      "${mod}+minus"       = "scratchpad show";

      # === Workspaces ===
      "${mod}+1" = "workspace number 1";
      "${mod}+2" = "workspace number 2";
      "${mod}+3" = "workspace number 3";
      "${mod}+4" = "workspace number 4";
      "${mod}+5" = "workspace number 5";
      "${mod}+6" = "workspace number 6";
      "${mod}+7" = "workspace number 7";
      "${mod}+8" = "workspace number 8";
      "${mod}+9" = "workspace number 9";
      "${mod}+0" = "workspace number 10";
      "${mod}+Shift+1" = "move container to workspace number 1";
      "${mod}+Shift+2" = "move container to workspace number 2";
      "${mod}+Shift+3" = "move container to workspace number 3";
      "${mod}+Shift+4" = "move container to workspace number 4";
      "${mod}+Shift+5" = "move container to workspace number 5";
      "${mod}+Shift+6" = "move container to workspace number 6";
      "${mod}+Shift+7" = "move container to workspace number 7";
      "${mod}+Shift+8" = "move container to workspace number 8";
      "${mod}+Shift+9" = "move container to workspace number 9";
      "${mod}+Shift+0" = "move container to workspace number 10";
    };
  };
}
