# Sway Window Manager Module
#
# NixOS-level Sway setup: enables compositor, portals, packages.
# Gated on hydrix.sway.enable.
#
# Sway config (keybindings, input, aesthetics) lives in:
#   modules/wm/sway/sway.nix
# waypipe host scripts live in:
#   modules/wm/sway/waypipe.nix
#
# Commands provided:
#   sway-session   — start sway; kills waypipe + cleans up env on exit
#   exit-wayland   — gracefully exit sway/Hyprland from any terminal;
#                    kills waypipe sessions + restores i3/picom
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;

  # sway-lock: Wayland equivalent of the i3 'lock' script.
  # Uses swaylock with wal colors — same binding (Mod+Shift+e) as i3.
  # For suspend, systemd runs this via swayidle before-sleep hook.
  swayLock = pkgs.writeShellScriptBin "sway-lock" ''
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      color0="#0c0c0c"; color1="#bf616a"
      color3="#ebcb8b"; color4="#7aa2f7"
      color7="#d8dee9"
    fi

    # Strip leading '#' for swaylock (it expects RRGGBB, not #RRGGBB)
    BG="''${color0#\#}"
    RING="''${color4#\#}"
    TEXT="''${color7#\#}"
    WRONG="''${color1#\#}"
    KEY="''${color3#\#}"

    exec ${pkgs.swaylock}/bin/swaylock \
      --color         "$BG" \
      --inside-color  "''${BG}00" \
      --ring-color    "''${RING}ff" \
      --key-hl-color  "''${KEY}ff" \
      --bs-hl-color   "''${WRONG}ff" \
      --text-color    "''${TEXT}ff" \
      --inside-wrong-color "''${WRONG}33" \
      --ring-wrong-color   "''${WRONG}ff" \
      --inside-ver-color   "''${BG}aa" \
      --ring-ver-color     "''${RING}aa" \
      --clock \
      --timestr "%H:%M:%S" \
      --datestr "%A, %Y-%m-%d"
  '';

  # sway-session: start sway and clean up on exit.
  # Kills waypipe sessions and unsets WAYLAND_DISPLAY from the systemd user
  # environment so picom (ConditionEnvironment=!WAYLAND_DISPLAY) starts cleanly
  # when i3 is launched from TTY next.
  #
  # NOTE: does NOT call vm-push-display-mode stop — that is exit-wayland's job.
  # If the user exits via exit-wayland (normal path), VMs are already in neutral
  # state before sway quits, so a second mode push here would just time out on
  # every VM and block the TTY for ~5s each.
  # On a crash/unexpected exit, killing waypipe is sufficient — VMs notice the
  # vsock disconnect and the next WM start pushes the correct mode.
  swaySession = pkgs.writeShellScriptBin "sway-session" ''
    sway "$@"
    EXIT=$?
    pkill -f "waypipe-connect" 2>/dev/null || true
    pkill -f "waypipe.*--vsock.*client" 2>/dev/null || true
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY 2>/dev/null || true
    exit $EXIT
  '';
in {
  imports = [ ./sway.nix ./waypipe.nix ];

  config = lib.mkIf (cfg.enable && config.hydrix.sway.enable) {
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = lib.mkDefault true;  # GTK env vars for apps launched from sway
    };

    # XDG portal for screen sharing, file pickers, etc.
    xdg.portal = {
      enable = lib.mkDefault true;
      wlr.enable = lib.mkDefault true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    };

    environment.systemPackages = with pkgs; [
      swaySession      # Use instead of bare `sway` — tears down cleanly on exit
      swayLock         # Wayland lock (Mod+Shift+e) — mirrors i3's lock binding
      # exitWayland is provided by waypipe.nix (wm/sway/waypipe.nix)
      swaylock         # swaylock binary (used by sway-lock script)
      swayidle         # Idle/suspend lock daemon (replaces xss-lock)
      swaybg           # Wallpaper setter
      wl-clipboard     # wl-copy / wl-paste
      grim             # Screenshot
      slurp            # Region select (for grim)
      dunst            # Notifications (Wayland-native since v1.7)
      libnotify
      wmenu            # Minimal launcher (dmenu-compatible)
      wofi             # App launcher for Wayland
      waybar           # Status bar (user config in shared/waybar.nix)

      # Waypipe + socat for VM app forwarding
      waypipe
      socat
    ];

    # Polkit agent (needed for auth dialogs)
    security.polkit.enable = true;

    # Required for Wayland rendering
    hardware.graphics.enable = true;
  };
}
