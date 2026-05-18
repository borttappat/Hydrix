# Hyprland Window Manager Module
#
# NixOS-level Hyprland setup: enables compositor, portals, packages.
# Gated on hydrix.hyprland.enable.
#
# Hyprland config (keybindings, rules, aesthetics) lives in:
#   modules/graphical/programs/hyprland.nix
#
# Use `hyprland-session` instead of `Hyprland` to start Hyprland — it cleans
# up WAYLAND_DISPLAY from the systemd user environment on exit, allowing
# picom to restart correctly when returning to i3/X11.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;
  lk = config.hydrix.graphical.lockscreen;

  hyprlandSession = pkgs.writeShellScriptBin "hyprland-session" ''
    Hyprland "$@"
    EXIT=$?
    # Remove Wayland env vars from the persistent systemd user environment.
    # Without this, picom refuses to start (ConditionEnvironment=!WAYLAND_DISPLAY).
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY 2>/dev/null || true
    # Restart picom so i3 gets compositing back immediately.
    systemctl --user restart picom 2>/dev/null || true
    exit $EXIT
  '';

  # hyprlock script - mirrors sway-lock with blurred wallpaper and wal colors
  hyprLock = pkgs.writeShellScriptBin "hypr-lock" ''
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

    SHOT=/tmp/hypr-lock-shot.png
    BLUR=/tmp/hypr-lock-blur.png
    FINAL=/tmp/hypr-lock-final.png

    ${pkgs.grim}/bin/grim "$SHOT" 2>/dev/null || true

    if [ -f "$SHOT" ]; then
      # Blur then burn lock text into image (same as sway-lock)
      ${pkgs.imagemagick}/bin/magick "$SHOT" -scale 20% -scale 500% "$BLUR" 2>/dev/null || cp "$SHOT" "$BLUR"
      if ! ${pkgs.imagemagick}/bin/magick "$BLUR" -gravity NorthWest \
          -pointsize "$FONT_SIZE" -font "$FONT" -fill "$color1" \
          -annotate +50+50 "$LOCK_TEXT" "$FINAL" 2>/dev/null; then
        cp "$BLUR" "$FINAL"
      fi
      ${pkgs.hyprlock}/bin/hyprlock --force-focus --image "$FINAL"
    else
      ${pkgs.hyprlock}/bin/hyprlock --force-focus
    fi

    rm -f "$SHOT" "$BLUR" "$FINAL"
  '';
in {
  config = lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;   # needed for XWayland apps (electron, etc.)
    };

    # XDG portal for screen sharing, file pickers, etc.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
      config.hyprland.default = [ "hyprland" "gtk" ];
    };

    # Required by home-manager's xdg.portal with useUserPackages enabled
    environment.pathsToLink = [ "/share/applications" "/share/xdg-desktop-portal" ];

    environment.systemPackages = with pkgs; [
      hyprlandSession    # Use this instead of bare `Hyprland` — cleans up on exit
      hyprlock           # Screen locker
      hyprLock           # hypr-lock script (blurred screenshot, wal colors)
      hyprpicker         # Color picker (Wayland-native)
      wl-clipboard       # wl-copy / wl-paste
      wlr-randr          # xrandr equivalent for wlroots
      grim               # Screenshot
      slurp              # Region select (for grim)
      dunst              # Notifications (Wayland-native since v1.7)
      libnotify
      waybar             # Status bar
      wofi               # Launcher (replaces rofi)

      # Waypipe + socat for VM app forwarding
      waypipe
      socat
    ];

    # Polkit agent (needed by Hyprland for auth dialogs)
    security.polkit.enable = true;

    # PAM for hyprlock authentication
    security.pam.services.hyprlock.enable = true;
  };
}
