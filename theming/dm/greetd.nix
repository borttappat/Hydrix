# greetd login manager — Wayland-native replacement for SDDM.
#
# SDDM's QML theme loader silently falls back to its default theme for our
# custom Main.qml (it infers a Qt5 greeter requirement from the QML imports
# and this build only ships the Qt6 greeter binary — an unresolved upstream
# quirk). greetd sidesteps that entirely: no Qt/QML theme engine at all.
#
# Two interchangeable frontends, picked via hydrix.greetd.frontend:
#   - regreet:  GTK greeter, background image + CSS theming (closest to the
#               GRUB-mirroring visual goal)
#   - tuigreet: minimal TUI greeter, colors only, no background image
#
# Enable with: hydrix.greetd.enable = true
{ config, lib, pkgs, ... }:
let
  cfg = config.hydrix.greetd;

  # Resolve the active colorscheme at build time (theming/lib.nix), so colors
  # below follow hydrix.colorscheme instead of a fixed hex default. Unlike
  # grub-theme/plymouth, regreet's font is resolved by fontconfig from a family
  # NAME (not a literal TTF path), so it safely follows hydrix.graphical.font.family.
  scheme = (import ../lib.nix { inherit lib pkgs; }).resolveScheme config;

  bgFallbackUrl = if cfg.background == "" then ""
                  else if lib.hasPrefix "/" cfg.background then "file://${cfg.background}"
                  else cfg.background;

  hyprlandSession = pkgs.runCommand "hyprland-hydrix-session" {
    passthru.providedSessions = [ "hyprland-hydrix" ];
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

  # ANSI color names, not hex — tuigreet only accepts named colors. These map
  # correctly because the console's ANSI palette is already recolored to match
  # hydrix.greetd.colors: black=bg, red=accent, cyan=muted, white=fg. See
  # theming/graphical/stylix.nix's console.colors (ttyColorsFromScheme).
  tuigreetTheme = "border=red;title=red;prompt=red;time=red;button=red;text=white;greet=white;input=white;action=cyan;container=black";

  tuigreetCmd = lib.concatStringsSep " " [
    "${lib.getExe pkgs.tuigreet}"
    "--time"
    "--remember"
    "--remember-session"
    "--asterisks"
    "--greeting HYDRIX"
    "--theme '${tuigreetTheme}'"
    "--cmd hyprland-launch"
  ];
in {
  options.hydrix.greetd = {
    enable = lib.mkEnableOption "Hydrix greetd login manager";

    frontend = lib.mkOption {
      type = lib.types.enum [ "regreet" "tuigreet" ];
      default = "regreet";
      description = "Which greetd frontend to use.";
    };

    background = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Wallpaper path for the regreet background. Ignored by tuigreet.";
    };

    fontSize = lib.mkOption {
      type = lib.types.int;
      default = 16;
    };

    fontFamily = lib.mkOption {
      type = lib.types.str;
      default = config.hydrix.graphical.font.family;
      defaultText = lib.literalExpression "config.hydrix.graphical.font.family";
      description = "regreet font family. Ignored by tuigreet (raw console, no font control).";
    };

    # Defaults resolve from the active hydrix.colorscheme (theming/lib.nix) —
    # override any of these to pin a specific color regardless of colorscheme.
    colors = {
      bg     = lib.mkOption { type = lib.types.str; default = "#${scheme.base00}"; };
      fg     = lib.mkOption { type = lib.types.str; default = "#${scheme.base05}"; };
      accent = lib.mkOption { type = lib.types.str; default = "#${scheme.base08}"; };
      muted  = lib.mkOption { type = lib.types.str; default = "#${scheme.base03}"; };
    };
  };

  config = lib.mkIf cfg.enable {
    services.getty.autologinUser = lib.mkForce null;

    services.displayManager.sessionPackages = lib.mkIf (cfg.frontend == "regreet") [ hyprlandSession ];
    services.displayManager.defaultSession  = lib.mkIf (cfg.frontend == "regreet") "hyprland-hydrix";

    programs.regreet = lib.mkIf (cfg.frontend == "regreet") {
      enable = true;
      font.name = cfg.fontFamily;
      font.size = cfg.fontSize;
      extraCss = ''
        window {
          ${lib.optionalString (bgFallbackUrl != "") ''
          background-image: url("${bgFallbackUrl}");
          background-size: cover;
          background-position: center;
          ''}
        }
        entry {
          background-color: ${cfg.colors.bg};
          color: ${cfg.colors.fg};
          border-color: ${cfg.colors.accent};
        }
        label {
          color: ${cfg.colors.fg};
        }
      '';
    };

    services.greetd = lib.mkIf (cfg.frontend == "tuigreet") {
      enable = true;
      useTextGreeter = true;
      settings.default_session.command = tuigreetCmd;
    };
  };
}
