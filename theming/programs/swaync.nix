# swaync (SwayNotificationCenter): notification popups plus a panel with
# history and do-not-disturb (swaync-client -t).
#
# Files in ~/.config/swaync:
# - config.json, style.css: layout, written by home.activation on every
#   rebuild and hand-editable in between (swaync-client -R / -rs to reload).
#   style.css @imports colors.css.
# - colors.css: wal colors and borders, written by swaync-apply-colors on
#   rebuild, colorscheme changes (refresh-colors) and hydrix-focus toggles, so
#   it must never carry hand edits.
#
# Borders follow the sender, with the same gradients as windows
# (theming/wm/hyprland/border-colors.nix): the host gradient by default, and a
# VM's own gradient for notifications the vsock relay (waypipe.nix) tags with
# category hydrix-vm-<vm>. Stock swaync gives every card the same CSS classes,
# hence the patch adding a category-<category> class. The ring is built from
# background layers rather than border-image so it keeps the rounded corners.
#
# Placement: top-right, X = gaps + notifications.offset from the screen edge,
# Y = notifications.offset under the bar's exclusive zone, so both axes leave
# the same clearance past a tiled window's edge. The panel's bottom edge keeps
# that clearance above the bottom window edge too. offsetCompensation is a
# per-machine fudge on top for fractional-scale rounding.
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  cfg = config.hydrix.graphical;
  ui = cfg.ui;
  n = ui.notifications;
  sc = cfg.scaling.computed;

  package = pkgs.swaynotificationcenter.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./swaync-category-class.patch];
  });
  client = "${package}/bin/swaync-client";
  borderColors = import ../wm/hyprland/border-colors.nix {inherit config lib pkgs;};

  shadow = sc.shadow {
    blur = 2;
    alpha = 0.9;
  };
  offsetX = ui.gaps + n.offset + n.offsetCompensation.x;
  offsetY = n.offset + n.offsetCompensation.y;
  # Panel bottom: offsetY past the bottom window edge, which sits gaps_out
  # above the screen on monobar and on the bottom bar's exclusive zone on dualbar.
  barType = config.hydrix.graphical.waybar.barType or "monobar";
  panelBottom =
    offsetY
    + (
      if barType == "monobar"
      then ui.gaps
      else 0
    );
  # px equivalent of the pt size eww and alacritty use (14px, waybar's size, at
  # the 11pt default).
  fontSize = builtins.floor (cfg.font.size * (cfg.font.relations.notifications or 1.0) * 4 / 3);
  opacity = toString (ui.opacity.overlayOverrides.notifications or ui.opacity.overlay);

  swayncConfig = pkgs.writeText "swaync-config.json" (builtins.toJSON ({
      "ignore-gtk-theme" = true;
      positionX = "right";
      positionY = "top";
      layer = "overlay";
      "control-center-layer" = "top";
      "layer-shell" = true;
      "layer-shell-cover-screen" = false;
      cssPriority = "user";
      "control-center-margin-top" = offsetY;
      "control-center-margin-right" = offsetX;
      "control-center-margin-bottom" = panelBottom;
      "control-center-margin-left" = 0;
      "control-center-width" = n.width + 100;
      # Card plus its padding: offsetX on the right, shadow room on the left.
      "notification-window-width" = n.width + offsetX + shadow.room;
      timeout = n.timeout.normal;
      "timeout-low" = n.timeout.low;
      "timeout-critical" = n.timeout.critical;
      "fit-to-screen" = true;
      "relative-timestamps" = true;
      "keyboard-shortcuts" = true;
      "notification-grouping" = false;
      "image-visibility" = "never";
      "transition-time" = 150;
      "hide-on-clear" = true;
      "hide-on-action" = true;
      "text-empty" = "No notifications";
      widgets = ["title" "dnd" "notifications"];
      "widget-config" = {
        notifications.vexpand = true;
        title = {
          text = "Notifications";
          "clear-all-button" = true;
          "button-text" = "Clear";
        };
        dnd.text = "Do not disturb";
      };
    }
    # Popups off: every notification goes straight to the panel.
    // lib.optionalAttrs (!n.popups) {
      "notification-visibility".all = {
        state = "muted";
        "app-name" = ".*";
      };
    }
    // lib.optionalAttrs (n.sound != null && n.sound != "") {
      "script-fail-notify" = false;
      scripts.sound = {
        exec = "${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -f ${n.sound}";
        "app-name" = ".*";
      };
    }));

  swayncStyle = pkgs.writeText "swaync-style.css" ''
    @import url("file:///home/${username}/.config/swaync/colors.css");

    :root {
      --noti-bg-alpha: ${opacity};
      --border-radius: ${toString sc.panelRadius}px;
      --border: ${toString ui.border}px solid transparent;
      --font-size-body: ${toString fontSize}px;
      --font-size-summary: ${toString fontSize}px;
    }

    /* Same font as eww and alacritty, sized in px like waybar. */
    * {
      font-family: "${cfg.font.family}", monospace;
      font-size: ${toString fontSize}px;
    }

    /* Text only: no notification image or app icon. */
    .notification-row .notification-background .notification .notification-default-action .notification-content .image,
    .notification-row .notification-background .notification .notification-default-action .notification-content .app-icon {
      min-width: 0;
      min-height: 0;
      margin: 0;
      opacity: 0;
      -gtk-icon-size: 0;
    }

    /* offsetY above and below each card (cards sit 2 * offsetY apart),
       offsetX to the screen edge, shadow room on the left. */
    .notification-row .notification-background {
      padding: ${toString offsetY}px ${toString offsetX}px ${toString (lib.max offsetY shadow.roomBottom)}px ${toString shadow.room}px;
    }

    /* Border: GTK cannot round a border-image, so the gradient ring is drawn
       as four edge strips in the background (backgrounds follow
       border-radius) around the translucent fill, all in one layer stack.
       colors.css sets the images; the layout here is shared by all of them. */
    .notification-row .notification-background .notification,
    .control-center {
      border: ${toString ui.border}px solid transparent;
      background-color: transparent;
      background-position: top, left, right, bottom, center;
      background-size: 100% ${toString ui.border}px, ${toString ui.border}px 100%, ${toString ui.border}px 100%, 100% ${toString ui.border}px, auto;
      background-repeat: no-repeat;
      background-clip: border-box, border-box, border-box, border-box, padding-box;
      background-origin: border-box, border-box, border-box, border-box, padding-box;
      box-shadow: ${shadow.css};
    }

    .notification-row .notification-background .notification .notification-default-action .notification-content .text-box .summary {
      color: var(--hydrix-summary);
      font-weight: bold;
    }

    .notification-row .notification-background .notification .notification-default-action .notification-content .text-box .body {
      color: var(--text-color);
    }

  '';

  swayncApplyColors = pkgs.writeShellScriptBin "swaync-apply-colors" ''
    source ${borderColors}
    out="$HOME/.config/swaync/colors.css"
    mkdir -p "$(dirname "$out")"

    _hex() { ${pkgs.jq}/bin/jq -r "$1 // empty" "$BORDER_WAL" 2>/dev/null; }
    bg=$(_hex '.special.background // .colors.color0'); bg="''${bg:-#101116}"
    fg=$(_hex '.special.foreground // .colors.color7'); fg="''${fg:-#c0caf5}"
    summary=$(_hex '.colors.color3'); summary="''${summary:-#e0af68}"
    rgb=$(printf '%d, %d, %d' "0x''${bg:1:2}" "0x''${bg:3:2}" "0x''${bg:5:2}")
    base=$(_border_base)
    # Background layers matching style.css: top, left, right, bottom edge
    # strips, then the fill. Each edge runs toward the far corner, so the ring
    # goes from the first stop (top-left) through the midpoint to baseColor
    # (bottom-right), like the window gradient.
    _ring() {
      local a="$1" b="$base" m
      m=$(printf '%02x%02x%02xff' $(( (0x''${a:0:2} + 0x''${b:0:2}) / 2 )) \
        $(( (0x''${a:2:2} + 0x''${b:2:2}) / 2 )) $(( (0x''${a:4:2} + 0x''${b:4:2}) / 2 )))
      printf 'background-image: linear-gradient(to right, #%s, #%s), linear-gradient(to bottom, #%s, #%s), ' "$a" "$m" "$a" "$m"
      printf 'linear-gradient(to bottom, #%s, #%s), linear-gradient(to right, #%s, #%s), ' "$m" "$b" "$m" "$b"
      printf 'linear-gradient(rgba(%s, ${opacity}), rgba(%s, ${opacity}));' "$rgb" "$rgb"
    }
    card='.notification-row .notification-background .notification'

    {
      printf ':root {\n  --noti-bg: %s;\n  --cc-bg: rgba(%s, ${opacity});\n  --text-color: %s;\n  --hydrix-summary: %s;\n}\n' \
        "$rgb" "$rgb" "$fg" "$summary"
      printf '%s, .control-center { %s }\n' "$card" "$(_ring "$(_border_host)")"
      ${pkgs.jq}/bin/jq -r 'keys[]' "$BORDER_REGISTRY" 2>/dev/null | while read -r vm; do
        printf '%s.category-hydrix-vm-%s { %s }\n' "$card" "$vm" "$(_ring "$(_border_vm "$vm")")"
      done
    } > "$out.tmp" && mv "$out.tmp" "$out"

    # swaync-client waits forever for the daemon when it is not on the bus
    # (--skip-wait does not cover that), e.g. during boot-time activation.
    ${pkgs.coreutils}/bin/timeout 2 ${client} --skip-wait --reload-css >/dev/null 2>&1 || true
  '';
in {
  config = lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
    environment.systemPackages = [
      package
      pkgs.libnotify
      swayncApplyColors
    ];

    home-manager.users.${username} = {lib, ...}: {
      home.activation.writeSwaync = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/swaync"
        mkdir -p "$_dir"
        cp ${swayncConfig} "$_dir/config.json" && chmod 644 "$_dir/config.json"
        cp ${swayncStyle} "$_dir/style.css" && chmod 644 "$_dir/style.css"
        ${swayncApplyColors}/bin/swaync-apply-colors

        # try-restart is a no-op when swaync is not running yet (first boot).
        ${pkgs.systemd}/bin/systemctl --user try-restart swaync.service 2>/dev/null || true
      '';

      systemd.user.services.swaync = {
        Unit = {
          Description = "swaync notification daemon (Hydrix)";
          PartOf = ["graphical-session.target"];
          # Not graphical-session-pre: swaync queries the Settings portal on
          # startup, the portal activates xdph, and xdph is ordered after
          # graphical-session.target. Holding the target on swaync deadlocks
          # until two 25s D-Bus timeouts expire, delaying waybar ~50s.
          After = ["graphical-session.target"];
        };
        Service = {
          Type = "dbus";
          BusName = "org.freedesktop.Notifications";
          ExecStart = "${package}/bin/swaync";
          # GTK4's default renderer draws text heavier than the GTK3 surfaces
          # (eww, waybar, wofi); cairo matches them.
          Environment = ["GSK_RENDERER=cairo"];
          ExecReload = "${client} --reload-config --reload-css";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    };
  };
}
