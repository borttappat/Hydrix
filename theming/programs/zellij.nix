# zellij multiplexer, themed from wal colors.
#
# zellij loads its theme once at session start and has no live reload, so
# zellij-apply-colors regenerates ~/.config/zellij/config.kdl (options plus an
# inline `hydrix` theme built from ~/.cache/wal/colors.json), and refresh-colors
# calls it on every colorscheme change. Both `zellij` and `zj` read that config;
# `zj` additionally restarts its `main` session when the generated config changed,
# so a running server repaints (a live session otherwise keeps its start-time
# theme). Enable with hydrix.zellij.enable; the impl is gated on graphical too.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.zellij;
  username = config.hydrix.username;

  applyColors = pkgs.writeShellScriptBin "zellij-apply-colors" ''
    set -eu
    out="$HOME/.config/zellij/config.kdl"
    wal="$HOME/.cache/wal/colors.json"
    mkdir -p "$(dirname "$out")"
    tmp=$(${pkgs.coreutils}/bin/mktemp)
    printf '%s\n' \
      'show_startup_tips false' \
      'pane_frames false' \
      'mouse_mode true' \
      'copy_on_select true' \
      'copy_command "${pkgs.wl-clipboard}/bin/wl-copy"' \
      'scroll_buffer_size 100000' \
      'session_serialization true' \
      'serialize_pane_viewport true' \
      'scrollback_lines_to_serialize 10000' \
      'default_layout "compact"' > "$tmp"
    if [ -f "$wal" ] && theme=$(${pkgs.jq}/bin/jq -r '
          .special as $s | .colors as $c |
          "    bg \"\($s.background // $c.color0)\"",
          "    fg \"\($s.foreground // $c.color7)\"",
          "    black \"\($c.color0)\"",
          "    red \"\($c.color1)\"",
          "    green \"\($c.color2)\"",
          "    yellow \"\($c.color3)\"",
          "    blue \"\($c.color4)\"",
          "    magenta \"\($c.color5)\"",
          "    cyan \"\($c.color6)\"",
          "    white \"\($c.color7)\"",
          "    orange \"\($c.color3)\""
        ' "$wal" 2>/dev/null); then
      printf '\nthemes {\n  hydrix {\n%s\n  }\n}\ntheme "hydrix"\n' "$theme" >> "$tmp"
    fi
    ${pkgs.coreutils}/bin/install -m 0644 "$tmp" "$out"
    ${pkgs.coreutils}/bin/rm -f "$tmp"
  '';

  zj = pkgs.writeShellScriptBin "zj" ''
    set -eu
    ${applyColors}/bin/zellij-apply-colors || true
    stamp="$HOME/.cache/zellij/.theme-hash"
    conf="$HOME/.config/zellij/config.kdl"
    new=$(${pkgs.coreutils}/bin/sha256sum "$conf" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d' ' -f1 || true)
    if [ -n "$new" ] && [ "$new" != "$(${pkgs.coreutils}/bin/cat "$stamp" 2>/dev/null || true)" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$stamp")"
      ${pkgs.zellij}/bin/zellij kill-session main 2>/dev/null || true
      printf '%s' "$new" > "$stamp"
    fi
    exec ${pkgs.zellij}/bin/zellij attach --create main
  '';
in {
  config = lib.mkIf (cfg.enable && config.hydrix.graphical.enable) {
    environment.systemPackages = [pkgs.zellij applyColors zj];

    # Seed config.kdl on activation so the first launch is themed; refresh-colors
    # regenerates it on every colorscheme change. Function form so `lib` here is
    # home-manager's (lib.hm.dag), not the system lib.
    home-manager.users.${username} = {lib, ...}: {
      home.activation.zellijTheme = lib.hm.dag.entryAfter ["writeBoundary"] ''
        ${applyColors}/bin/zellij-apply-colors || true
      '';
    };
  };
}
