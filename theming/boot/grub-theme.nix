# Custom Hydrix GRUB bootloader theme.
#
# Dark background with green accent menu, Iosevka font (converted to PF2),
# and "HYDRIX" branding label.
#
# Enable with: hydrix.grub.theme.enable = true
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.grub.theme;

  # Boot-time identity font — deliberately independent of hydrix.graphical.font.family
  # (that's the desktop UI font; font packages don't share a uniform Regular/Bold TTF
  # naming convention, so auto-deriving a boot font from it is unreliable). Still
  # overridable via cfg.fontPackage if you want a different boot-screen font.
  fontRegular = "${cfg.fontPackage}/share/fonts/truetype/Iosevka-Regular.ttf";
  fontBold    = "${cfg.fontPackage}/share/fonts/truetype/Iosevka-Bold.ttf";

  # Resolve the active colorscheme at build time (theming/lib.nix), so colors
  # below follow hydrix.colorscheme instead of a fixed hex default.
  scheme = (import ../lib.nix { inherit lib pkgs; }).resolveScheme config;

  menuSize  = cfg.fontSize;
  titleSize = builtins.floor (cfg.fontSize * 1.6);
  hintSize  = builtins.floor (cfg.fontSize * 0.75);

  hydrixGrubTheme = pkgs.runCommand "hydrix-grub-theme" {
    nativeBuildInputs = [ pkgs.imagemagick pkgs.grub2 ];
  } ''
    dir=$out/grub/themes/hydrix
    mkdir -p $dir

    # ── Fonts (TTF → PF2) ─────────────────────────────────────────────
    grub-mkfont --output=$dir/iosevka_regular_${toString menuSize}.pf2  --size=${toString menuSize}  ${fontRegular}
    grub-mkfont --output=$dir/iosevka_bold_${toString menuSize}.pf2    --size=${toString menuSize}  ${fontBold}
    grub-mkfont --output=$dir/iosevka_bold_${toString titleSize}.pf2   --size=${toString titleSize} ${fontBold}
    grub-mkfont --output=$dir/iosevka_regular_${toString hintSize}.pf2 --size=${toString hintSize}  ${fontRegular}

    # ── Background ─────────────────────────────────────────────────────
    ${if cfg.background != null then ''
      magick "${cfg.background}" -resize 1920x1200^ -gravity center -extent 1920x1200 PNG24:$dir/background.png
    '' else ''
      magick -size 1920x1200 "xc:${cfg.colors.bg}" PNG24:$dir/background.png
    ''}

    # ── Selection highlight (no alpha — GRUB PNG parser is limited) ────
    magick -size 64x64 "xc:${cfg.colors.bg}" \
      -fill "${cfg.colors.accent}" -draw "color 0,0 reset" \
      -evaluate multiply 0.3 \
      PNG24:$dir/select_c.png
    for piece in n s w e nw ne sw se; do
      magick -size 4x4 "xc:${cfg.colors.accent}" PNG24:"$dir/select_$piece.png"
    done

    # ── Terminal box (styles GRUB terminal/console between menus) ──────
    # Must be large enough to tile properly across the full screen
    for piece in c n s w e nw ne sw se; do
      magick -size 32x32 "xc:${cfg.colors.bg}" PNG24:"$dir/terminal_box_$piece.png"
    done

    # ── theme.txt ──────────────────────────────────────────────────────
    cat > $dir/theme.txt << THEME
title-text: ""
desktop-image: "background.png"
desktop-color: "${cfg.colors.bg}"
terminal-font: "Iosevka Regular ${toString menuSize}"
terminal-left: "0"
terminal-top: "0"
terminal-width: "100%"
terminal-height: "100%"
terminal-border: "0"
terminal-box: "terminal_box_*.png"

+ boot_menu {
  left = 31%
  top = 30%
  width = 38%
  height = 45%
  item_font = "Iosevka Regular ${toString menuSize}"
  item_color = "${cfg.colors.fg}"
  selected_item_font = "Iosevka Bold ${toString menuSize}"
  selected_item_color = "${cfg.colors.accentBright}"
  item_height = ${toString (builtins.floor (menuSize * 2.2))}
  item_padding = ${toString (builtins.floor (menuSize * 0.5))}
  item_spacing = ${toString (builtins.floor (menuSize * 0.5))}
  selected_item_pixmap_style = "select_*.png"
  scrollbar = false
}

+ label {
  left = 0
  top = 85%
  width = 100%
  text = "HYDRIX"
  font = "Iosevka Bold ${toString titleSize}"
  color = "${cfg.colors.accent}"
  align = "center"
}

+ label {
  left = 0
  top = 90%
  width = 100%
  text = "Use arrow keys to select, Enter to boot"
  font = "Iosevka Regular ${toString hintSize}"
  color = "${cfg.colors.muted}"
  align = "center"
}
THEME
  '';

in {
  options.hydrix.grub.theme = {
    enable = lib.mkEnableOption "Hydrix-themed GRUB bootloader";

    fontSize = lib.mkOption {
      type    = lib.types.int;
      default = 18;
      description = "Base menu font size in px (title = 1.6x, hints = 0.75x)";
    };

    background = lib.mkOption {
      type    = lib.types.nullOr lib.types.path;
      default = null;
      description = "Wallpaper path for GRUB background. null = solid color.";
    };

    fontPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.iosevka;
      description = ''
        Package providing the boot font. Must ship Iosevka-Regular.ttf and
        Iosevka-Bold.ttf under share/fonts/truetype — the boot font is a
        deliberate identity choice independent of hydrix.graphical.font.family,
        not auto-derived from it.
      '';
    };

    # Defaults resolve from the active hydrix.colorscheme (theming/lib.nix) —
    # override any of these to pin a specific color regardless of colorscheme.
    colors = {
      bg = lib.mkOption {
        type = lib.types.str;
        default = "#${scheme.base00}";
      };
      fg = lib.mkOption {
        type = lib.types.str;
        default = "#${scheme.base05}";
      };
      accent = lib.mkOption {
        type = lib.types.str;
        default = "#${scheme.base08}";
      };
      accentBright = lib.mkOption {
        type = lib.types.str;
        default = "#${scheme.base0B}";
      };
      muted = lib.mkOption {
        type = lib.types.str;
        default = "#${scheme.base03}";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.grub.theme = "${hydrixGrubTheme}/grub/themes/hydrix";

    # Style the GRUB terminal/console text (submenus, countdown, editor).
    # terminal-box handles the background; these control text color.
    # GRUB color format: foreground/background (named colors only).
    # "black" = #000000 (close enough to our #050505 bg).
    boot.loader.grub.extraConfig = ''
      set color_normal=dark-gray/black
      set color_highlight=green/black
      set menu_color_normal=dark-gray/black
      set menu_color_highlight=green/black
    '';

    # Disable NixOS default splash (grey square with NixOS logo)
    boot.loader.grub.splashImage = null;
    boot.loader.grub.backgroundColor = "#050505";

    # Keep GRUB framebuffer resolution for Plymouth (prevents letterboxing)
    boot.loader.grub.gfxpayloadEfi = "keep";
  };
}
