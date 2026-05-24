# Zathura PDF Viewer
#
# Writes ~/.config/zathura/zathurarc as a plain file via home.activation.
# All settings come from hydrix.graphical.zathura.* options — set defaults
# here or override in hydrix-config/shared/zathura.nix.
#
# Colors are injected at runtime from the wal cache:
#   ~/.config/zathura/zathurarc-wal is written by walrgb/refresh-colors
#   and included by zathurarc. Zathura picks up changes live via inotify.
#   No rebuild required when the colorscheme changes.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  sc       = config.hydrix.graphical.scaling.computed;
  z        = config.hydrix.graphical.zathura;

  boolStr = b: if b then "true" else "false";

  mappingLines = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "map ${k} ${v}") z.mappings);

  zathurarc = pkgs.writeText "zathurarc" ''
    # Colors — updated at runtime by walrgb / refresh-colors
    include ~/.config/zathura/zathurarc-wal

    # Recolor
    set recolor               ${boolStr z.recolor}
    set recolor-reverse-video ${boolStr z.recolorReverseVideo}
    set recolor-keephue       ${boolStr z.recolorKeepHue}

    # UI (scaled by DPI)
    set statusbar-h-padding ${toString sc.padding}
    set statusbar-v-padding ${toString sc.padding}
    set page-padding        ${toString sc.border}

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
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { lib, ... }: {
      # Stylix's zathura target only fires when programs.zathura.enable = true.
      # We don't set that, but disable it explicitly to be safe.
      stylix.targets.zathura.enable = lib.mkForce false;

      home.activation.zathuraConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/zathura"
        mkdir -p "$_dir"
        [ -L "$_dir/zathurarc" ] && rm -f "$_dir/zathurarc"
        cat ${zathurarc} > "$_dir/zathurarc"
      '';
    };

    environment.systemPackages = [ pkgs.zathura ];
  };
}
