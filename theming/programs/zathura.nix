# Zathura PDF Viewer
#
# The base zathurarc is written as a plain writable file via home.activation
# (not xdg.configFile, which symlinks into the read-only nix store), editable
# freely between rebuilds, like hyprland/waybar/eww in hydrix-config. Rebuild
# restores it to the settings below.
#
# A launch wrapper builds a temp --config-dir from that same writable file
# plus colors read fresh from the wal cache, so every new window opens with
# the current colorscheme and any live zathurarc edits (adapted from
# https://github.com/GideonWolfe/Zathura-Pywal). Already-open windows are
# updated live via zathura's D-Bus interface (org.pwmt.zathura.ExecuteCommand
# runs a command exactly as if typed in the inputbar) -- called from
# refresh-colors, so a colorscheme change applies immediately with no
# restart needed.
#
# All non-color settings come from hydrix.graphical.zathura.* options, set
# defaults here or override in hydrix-config/modules/zathura.nix.
{
  config,
  lib,
  pkgs,
  hasStylix ? false,
  ...
}: let
  username = config.hydrix.username;
  sc = config.hydrix.graphical.scaling.computed;
  z = config.hydrix.graphical.zathura;
  jq = "${pkgs.jq}/bin/jq";
  gdbus = "${pkgs.glib}/bin/gdbus";

  # See "Stylix (opt-in theming)" in DOCUMENTATION.md. Note: under
  # handOffToStylix, hydrix.graphical.zathura.* (recolor, padding,
  # scroll/zoom, sandbox, mappings, extraConfig) stops applying -- those are
  # only ever delivered via the wrapper below, and Stylix's own zathura
  # target manages ~/.config/zathura/zathurarc itself.
  handOffToStylix = hasStylix && config.hydrix.graphical.stylix.exclusive;

  boolStr = b:
    if b
    then "true"
    else "false";

  mappingLines =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "map ${k} ${v}") z.mappings);

  zathurarc = pkgs.writeText "zathurarc" ''
    # Recolor
    set recolor               ${boolStr z.recolor}
    set recolor-reverse-video ${boolStr z.recolorReverseVideo}
    set recolor-keephue       ${boolStr z.recolorKeepHue}

    # UI (scaled by DPI)
    set statusbar-h-padding ${toString sc.padding}
    set statusbar-v-padding ${toString sc.padding}
    set page-v-padding      ${toString sc.border}

    # Clipboard
    set selection-clipboard ${z.selectionClipboard}

    # Scroll
    set scroll-page-aware  ${boolStr z.scrollPageAware}
    set scroll-full-overlap ${z.scrollFullOverlap}
    set scroll-step         ${toString z.scrollStep}

    # Zoom
    set zoom-min  ${toString z.zoomMin}
    set zoom-max  ${toString z.zoomMax}
    set zoom-step ${toString z.zoomStep}

    # Search
    set incremental-search ${boolStr z.incrementalSearch}

    # Sandbox
    set sandbox ${z.sandbox}

    # Key mappings
    ${mappingLines}

    ${z.extraConfig}
  '';

  # Shared: read the current wal cache and build a bash array `COMMANDS` of
  # girara `set <option> "<value>"` strings. Sourced by both the launch
  # wrapper (writes them into a temp config) and the live-reload script
  # (pushes them into already-open windows via D-Bus). Silently produces an
  # empty COMMANDS array if the wal cache doesn't exist yet.
  colorCommands = ''
    WAL_COLORS="$HOME/.cache/wal/colors.json"
    COMMANDS=()
    if [ -f "$WAL_COLORS" ]; then
      COLOR0=$(${jq} -r '.colors.color0' "$WAL_COLORS")
      COLOR1=$(${jq} -r '.colors.color1' "$WAL_COLORS")
      COLOR3=$(${jq} -r '.colors.color3' "$WAL_COLORS")
      COLOR4=$(${jq} -r '.colors.color4' "$WAL_COLORS")
      BG=$(${jq} -r '.special.background' "$WAL_COLORS")
      FG=$(${jq} -r '.special.foreground' "$WAL_COLORS")

      COMMANDS=(
        "set notification-error-bg \"$BG\""
        "set notification-error-fg \"$COLOR1\""
        "set notification-warning-bg \"$BG\""
        "set notification-warning-fg \"$COLOR3\""
        "set notification-bg \"$BG\""
        "set notification-fg \"$COLOR4\""
        "set completion-group-bg \"$BG\""
        "set completion-group-fg \"$COLOR4\""
        "set completion-bg \"$COLOR0\""
        "set completion-fg \"$FG\""
        "set completion-highlight-bg \"$COLOR4\""
        "set completion-highlight-fg \"$BG\""
        "set index-bg \"$BG\""
        "set index-fg \"$COLOR4\""
        "set index-active-bg \"$COLOR4\""
        "set index-active-fg \"$BG\""
        "set inputbar-bg \"$COLOR0\""
        "set inputbar-fg \"$FG\""
        "set statusbar-bg \"$COLOR0\""
        "set statusbar-fg \"$FG\""
        "set highlight-color \"$COLOR3\""
        "set highlight-active-color \"$COLOR4\""
        "set default-bg \"$BG\""
        "set default-fg \"$FG\""
        "set recolor-lightcolor \"$BG\""
        "set recolor-darkcolor \"$FG\""
      )
    fi
  '';

  # Wraps the real zathura binary: every launch builds a temp config dir
  # containing the writable base zathurarc (home.activation seeds it, the
  # user can edit it between rebuilds) plus colors read fresh from the wal
  # cache, then execs zathura against it -- a brand new window always opens
  # with the current colorscheme and any live zathurarc edits, no dependency
  # on any previous refresh-colors run having written a separate include
  # file.
  zathuraWrapped = pkgs.writeShellScriptBin "zathura" ''
    set -eu
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    cat "$HOME/.config/zathura/zathurarc" > "$tmp/zathurarc"

    ${colorCommands}
    for cmd in "''${COMMANDS[@]}"; do
      echo "$cmd" >> "$tmp/zathurarc"
    done

    exec ${pkgs.zathura}/bin/zathura --config-dir="$tmp" "$@"
  '';

  # Pushes fresh colors into every already-running zathura window live.
  # Bus name template is `org.pwmt.zathura.PID-<pid>` (one per instance);
  # ExecuteCommand takes a single string executed exactly as if typed in the
  # inputbar, so each `set` line is pushed as its own call.
  zathuraReloadColors = pkgs.writeShellScriptBin "zathura-reload-colors" ''
    set -eu
    ${colorCommands}
    if [ "''${#COMMANDS[@]}" -eq 0 ]; then
      exit 0
    fi

    for bus in $(${gdbus} call --session \
        --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListNames 2>/dev/null \
        | tr ',' '\n' | grep -o 'org\.pwmt\.zathura\.PID-[0-9]*'); do
      for cmd in "''${COMMANDS[@]}"; do
        ${gdbus} call --session \
          --dest "$bus" \
          --object-path /org/pwmt/zathura \
          --method org.pwmt.zathura.ExecuteCommand \
          "'$cmd'" >/dev/null 2>&1 || true
      done
    done
  '';
in {
  config = lib.mkMerge [
    (lib.optionalAttrs hasStylix (lib.mkIf (config.hydrix.graphical.enable && !handOffToStylix) {
      home-manager.users.${username}.stylix.targets.zathura.enable = lib.mkForce false;
    }))

    (lib.mkIf (config.hydrix.graphical.enable && !handOffToStylix) {
      home-manager.users.${username} = { lib, ... }: {
        home.activation.zathuraConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
          _dir="$HOME/.config/zathura"
          mkdir -p "$_dir"
          [ -L "$_dir/zathurarc" ] && rm -f "$_dir/zathurarc"
          cat ${zathurarc} > "$_dir/zathurarc"
        '';
      };
    })

    (lib.mkIf config.hydrix.graphical.enable {
      environment.systemPackages =
        if handOffToStylix
        then [pkgs.zathura]
        else [
          (lib.hiPrio zathuraWrapped)
          pkgs.zathura
          zathuraReloadColors
        ];
    })
  ];
}
