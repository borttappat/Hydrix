# File Finder Script
#
# Fuzzy file search launcher with smart file-type opener.
# Bind in your hydrix-config i3 keybindings (e.g. $mod+Shift+o).
#
# Dual mode:
#   - DISPLAY set: rofi dmenu with pywal colors and scaling.json theming
#   - No DISPLAY:  fzf terminal fallback (for VM terminals)
#
# Opens by mime type: text → vim (alacritty-dpi), pdf → zathura, image → feh
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;

  fileFinderScript = pkgs.writeShellScriptBin "file-finder" ''
    set -euo pipefail

    readonly SCALING_JSON="$HOME/.config/hydrix/scaling.json"

    get_scaling_value() {
        local key="$1" default="$2" val
        if [[ -f "$SCALING_JSON" ]]; then
            val=$(${pkgs.jq}/bin/jq -r "$key // empty" "$SCALING_JSON" 2>/dev/null)
            echo "''${val:-$default}"
        else
            echo "$default"
        fi
    }

    get_color() {
        local name="$1" fallback="$2" color
        color=$(${pkgs.xorg.xrdb}/bin/xrdb -query 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -E "^\*\.?$name:" \
            | head -1 \
            | ${pkgs.gawk}/bin/awk '{print $2}')
        echo "''${color:-$fallback}"
    }

    build_theme() {
        local bar_gaps corner_radius font_size font_name overlay_alpha
        bar_gaps=$(get_scaling_value '.sizes.bar_gaps' '10')
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '8')
        font_size=$(get_scaling_value '.fonts.rofi' '12')
        font_name=$(get_scaling_value '.font_name' 'Iosevka')
        overlay_alpha=$(get_scaling_value '.sizes.overlay_alpha_hex' 'D9')

        local bg fg accent prefix
        bg=$(get_color "color0" "#101116")
        fg=$(get_color "color7" "#c0caf5")
        accent=$(get_color "color4" "#7aa2f7")
        prefix=$(get_color "color3" "#e0af68")

        cat <<EOF
    configuration {
        font: "''${font_name} Bold ''${font_size}";
        show-icons: false;
        disable-history: false;
        hover-select: true;
        me-select-entry: "";
        me-accept-entry: "MousePrimary";
        kb-cancel: "Escape,q";
        kb-accept-entry: "Return,KP_Enter";
        kb-row-up: "Up";
        kb-row-down: "Down";
    }

    * {
        bg: ''${bg}''${overlay_alpha};
        bg-solid: ''${bg};
        fg: ''${fg};
        accent: ''${accent};
        prefix: ''${prefix};
    }

    window {
        location: north;
        anchor: north;
        y-offset: 20%;
        width: 700px;
        background-color: @bg;
        border: 0px;
        border-radius: ''${corner_radius}px;
    }

    mainbox {
        background-color: transparent;
        children: [inputbar, listview];
        padding: 4px;
    }

    inputbar {
        enabled: true;
        children: [entry];
        background-color: transparent;
        padding: 8px 12px;
    }

    entry {
        background-color: transparent;
        text-color: @fg;
        cursor: text;
        placeholder: "Find file...";
        placeholder-color: @prefix;
    }

    listview {
        lines: 14;
        fixed-height: false;
        dynamic: true;
        scrollbar: false;
        background-color: transparent;
        spacing: 2px;
        padding: 4px 0 0 0;
    }

    element {
        padding: 6px 12px;
        background-color: transparent;
        text-color: @fg;
        border-radius: ''${corner_radius}px;
        cursor: pointer;
    }

    element selected.normal {
        background-color: @accent;
        text-color: @bg-solid;
    }

    element-text {
        background-color: transparent;
        text-color: inherit;
        highlight: bold;
    }

    scrollbar { enabled: false; }
    mode-switcher { enabled: false; }
    EOF
    }

    open_file() {
        local f="$1"
        local mime
        mime=$(${pkgs.file}/bin/file --mime-type -b "$f" 2>/dev/null || echo "application/octet-stream")

        case "$mime" in
            application/pdf)
                ${pkgs.zathura}/bin/zathura "$f" &
                ;;
            image/*)
                ${pkgs.feh}/bin/feh "$f" &
                ;;
            text/*|application/json|application/x-sh|application/javascript|application/xml|inode/x-empty)
                if [[ -n "''${DISPLAY:-}" ]]; then
                    alacritty-dpi -e vim "$f" &
                else
                    vim "$f"
                fi ;;
            *)
                case "''${f##*.}" in
                    nix|sh|py|js|ts|rs|go|c|h|cpp|md|txt|yaml|yml|toml|json|conf|cfg|ini|lua|vim|fish|bash|zsh)
                        if [[ -n "''${DISPLAY:-}" ]]; then
                            alacritty-dpi -e vim "$f" &
                        else
                            vim "$f"
                        fi ;;
                    pdf)
                        ${pkgs.zathura}/bin/zathura "$f" & ;;
                    jpg|jpeg|png|gif|bmp|webp|svg|ico)
                        ${pkgs.feh}/bin/feh "$f" & ;;
                    *)
                        if [[ -n "''${DISPLAY:-}" ]]; then
                            alacritty-dpi -e vim "$f" &
                        else
                            vim "$f"
                        fi ;;
                esac ;;
        esac
        disown 2>/dev/null || true
    }

    main() {
        local search_dir="''${1:-$HOME}"
        local selected

        local fd_cmd=(
            ${pkgs.fd}/bin/fd --type f --hidden --max-depth 8
            --exclude .git
            --exclude .cache
            --exclude .cargo
            --exclude .rustup
            --exclude .local
            --exclude .mozilla
            --exclude .var
            --exclude node_modules
            --exclude __pycache__
            --exclude target
            . "$search_dir"
        )

        if [[ -n "''${DISPLAY:-}" ]]; then
            local theme_file
            theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/file-finder-XXXXXX.rasi)
            build_theme > "$theme_file"

            selected=$("''${fd_cmd[@]}" 2>/dev/null \
                | ${pkgs.gnugrep}/bin/grep -v "^/nix/" \
                | ${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -m -4 -i -p "" \
                2>/dev/null) || true

            ${pkgs.coreutils}/bin/rm -f "$theme_file"
        else
            selected=$("''${fd_cmd[@]}" 2>/dev/null \
                | ${pkgs.fzf}/bin/fzf --prompt "Find file: " --height=40%) || true
        fi

        [[ -z "$selected" ]] && exit 0
        open_file "$selected"
    }

    main "$@"
  '';

in lib.mkIf cfg.enable {
  environment.systemPackages = [ fileFinderScript ];
}
