# SDDM login manager with a theme mirroring the Hyprland lockscreen (hyprlock).
#
# Theme sources live in ./sddm (Main.qml, metadata.desktop); theme.conf is
# generated here from the same values hyprlock uses:
#   - text/font/clock size/blur   hydrix.graphical.lockscreen.*
#   - border width                hydrix.graphical.scaling.computed.border
#   - rounding                    hydrix.graphical.ui.cornerRadius (x2, min 2)
#   - colors                      colorscheme slots matching colors-lock.conf
#                                 (color0 bg, color7 fg, color4 accent, color1 wrong)
# The background defaults to the GRUB theme's image, so boot and login match.
#
# metadata.desktop must carry QtVersion=6: without it SDDM assumes a Qt5
# greeter, which this build does not ship, and silently falls back to its
# default theme.
#
# Enable with:  hydrix.sddm.enable = true   (mutually exclusive with greetd)
# Preview with: hydrix.sddm.preview = true, then run hydrix-sddm-preview
#               inside a graphical session (windowed test mode, Esc quits).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.sddm;
  lk = config.hydrix.graphical.lockscreen;
  sc = config.hydrix.graphical.scaling.computed;
  ui = config.hydrix.graphical.ui;

  scheme = (import ../lib.nix {inherit lib pkgs;}).resolveScheme config;

  greeter = "${cfg.package}/bin/sddm-greeter-qt6";

  # QSettings splits unquoted values on commas ("Papers, please" -> list).
  q = s: ''"${lib.escape ["\\" "\""] (toString s)}"'';

  themeConf = pkgs.writeText "theme.conf" ''
    [General]
    background=${q (
      if cfg.background == null
      then ""
      else "${cfg.background}"
    )}
    blur=${lib.boolToString lk.blur}
    dim=0.5
    vibrancy=0.2

    bg=${q cfg.colors.bg}
    fg=${q cfg.colors.fg}
    accent=${q cfg.colors.accent}
    wrong=${q cfg.colors.wrong}

    font=${q lk.font}
    clockSize=${toString lk.clockSize}
    scale=${toString cfg.scale}

    fieldWidth=${toString cfg.fieldWidth}
    fieldHeight=${toString cfg.fieldHeight}
    rounding=${toString (
      if (ui.cornerRadius or 0) > 0
      then ui.cornerRadius * 2
      else 2
    )}
    border=${toString (sc.border or 2)}

    text=${q lk.text}
    wrongText=${q lk.wrongText}
    verifyText=${q lk.verifyText}
  '';

  theme = pkgs.runCommand "hydrix-sddm-theme" {} ''
    dir=$out/share/sddm/themes/hydrix
    mkdir -p $dir
    cp ${./sddm/Main.qml} $dir/Main.qml
    cp ${./sddm/metadata.desktop} $dir/metadata.desktop
    cp ${themeConf} $dir/theme.conf
  '';

  # Runs the built theme in a window (Main.qml divides out the window's
  # pixel ratio itself, so sizes match the real greeter).
  preview = pkgs.writeShellScriptBin "hydrix-sddm-preview" ''
    dir=$(${pkgs.coreutils}/bin/mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    cp -r ${theme}/share/sddm/themes/hydrix/. "$dir"
    chmod -R u+w "$dir"
    echo "preview=true" >> "$dir/theme.conf"
    ${greeter} --test-mode --theme "$dir"
  '';

  hyprlandSession =
    pkgs.runCommand "hyprland-hydrix-session" {
      passthru.providedSessions = ["hyprland-hydrix"];
    } ''
      mkdir -p $out/share/wayland-sessions
      cat > $out/share/wayland-sessions/hyprland-hydrix.desktop << 'EOF'
      [Desktop Entry]
      Name=Hyprland
      Comment=Hyprland via hyprland-launch (systemd-cat wrapped start-hyprland)
      Exec=/run/current-system/sw/bin/hyprland-launch
      Type=Application
      DesktopNames=Hyprland
      EOF
    '';
in {
  options.hydrix.sddm = {
    enable = lib.mkEnableOption "Hydrix SDDM login manager (replaces greetd)";

    preview = lib.mkEnableOption ''
      the hydrix-sddm-preview command, which opens the theme in a window
      without switching display manager'';

    package = lib.mkPackageOption pkgs ["kdePackages" "sddm"] {};

    background = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = config.hydrix.grub.theme.background;
      defaultText = lib.literalExpression "config.hydrix.grub.theme.background";
      description = "Login background image, blurred and dimmed like hyprlock. null = solid bg color.";
    };

    scale = lib.mkOption {
      type = lib.types.either lib.types.int lib.types.float;
      default = let
        s = config.hydrix.graphical.scaling.hyprInternalScale;
      in
        if s == null
        then 1.0
        else s;
      defaultText = lib.literalExpression "config.hydrix.graphical.scaling.hyprInternalScale (or 1.0)";
      description = ''
        Physical pixels per hyprlock unit. hyprlock sizes are logical pixels,
        so matching it means using the output scale Hyprland runs at; the
        greeter itself (Weston kiosk) runs unscaled.
      '';
    };

    fieldWidth = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Input field width, mirrors hyprlock's input-field size.";
    };

    fieldHeight = lib.mkOption {
      type = lib.types.int;
      default = 55;
      description = "Input field height, mirrors hyprlock's input-field size.";
    };

    # Defaults resolve from the active hydrix.colorscheme (theming/lib.nix),
    # using the same pywal slots hyprlock reads from colors-lock.conf.
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
        default = "#${scheme.base0D}";
      };
      wrong = lib.mkOption {
        type = lib.types.str;
        default = "#${scheme.base08}";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.preview {
      environment.systemPackages = [preview];
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = !config.hydrix.greetd.enable;
          message = "hydrix.sddm and hydrix.greetd are both enabled; pick one login manager.";
        }
      ];

      services.getty.autologinUser = lib.mkForce null;

      services.displayManager.sddm = {
        enable = true;
        package = cfg.package;
        wayland.enable = true;
        theme = "hydrix";
      };
      services.displayManager.sessionPackages = [hyprlandSession];
      services.displayManager.defaultSession = "hyprland-hydrix";

      environment.systemPackages = [theme];
    })
  ];
}
