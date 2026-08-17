# Native Theming (always on, no Stylix required)
#
# Fonts and console (TTY) colors, driven by the same colorscheme-resolution
# logic Stylix would otherwise use. Everything else (GTK, zathura, alacritty,
# firefox, dunst, waybar, Hyprland borders) is themed at runtime by wal/pywal
# via theming/programs/*.nix and theming/graphical/scripts.nix, independent of
# both this file and Stylix.
#
# Usage in profiles:
#   hydrix.graphical.colorscheme = "hydrix";  # Uses colorschemes/base16/hydrix.yaml
#   # OR
#   hydrix.graphical.colorscheme = "nvid";    # Auto-converts colorschemes/nvid.json if no yaml exists
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Shared pywal->base16 conversion + vmType fallback palettes (also used by
  # theming/boot/*.nix, theming/dm/greetd.nix, and theming/graphical/stylix.nix
  # for build-time colors).
  hydrixTheme = import ../lib.nix {inherit lib pkgs;};
  inherit (hydrixTheme) pywalToBase16 vmTypeColors;

  # Font configuration from unified options
  fontCfg = config.hydrix.graphical.font;

  # Map font family names to packages (populated by hydrix.graphical.font.packageMap option)
  fontPackageMap = config.hydrix.graphical.font.packageMap;

  # Get font package for family name (with fallback)
  getFontPackage = name:
    if fontPackageMap ? ${name}
    then fontPackageMap.${name}
    else builtins.head (config.hydrix.graphical.font.packages ++ [pkgs.iosevka]);

  # Determine which color scheme to use
  # When vmColors.enable is true, VMs use the host's colorscheme
  vmColorsEnabled = config.hydrix.vmColors.enable;
  hostColorscheme = config.hydrix.vmColors.hostColorscheme;
  vmColorscheme = config.hydrix.colorscheme; # VM's own colorscheme (for alacritty text)

  colorscheme =
    if vmColorsEnabled && hostColorscheme != null
    then hostColorscheme
    else vmColorscheme;

  vmType = config.hydrix.vmType;

  # Check for pre-converted base16 YAML
  base16YamlPath = ../colorschemes/base16/${colorscheme}.yaml;
  hasBase16Yaml = colorscheme != null && builtins.pathExists base16YamlPath;

  # Check for pywal JSON to convert (user colorschemes first, then framework)
  pywalJsonPath =
    if colorscheme != null
    then config.hydrix.resolveColorscheme colorscheme
    else null;
  hasPywalJson = pywalJsonPath != null && builtins.pathExists pywalJsonPath;

  # Resolve final scheme
  resolvedScheme =
    if hasBase16Yaml
    then base16YamlPath
    else if hasPywalJson
    then pywalToBase16 pywalJsonPath
    else if vmType != null && vmTypeColors ? ${vmType}
    then vmTypeColors.${vmType}
    else vmTypeColors.host;

  # Extract 16 colors from base16 scheme for console.colors (TTY)
  ttyColorsFromScheme = scheme:
    if builtins.isAttrs scheme
    then [
      scheme.base00 # 0: Black (background)
      scheme.base08 # 1: Red
      scheme.base0B # 2: Green
      scheme.base0A # 3: Yellow
      scheme.base0D # 4: Blue
      scheme.base0E # 5: Magenta
      scheme.base0C # 6: Cyan
      scheme.base05 # 7: White (foreground)
      scheme.base03 # 8: Bright Black
      scheme.base08 # 9: Bright Red (same as base)
      scheme.base0B # 10: Bright Green
      scheme.base0A # 11: Bright Yellow
      scheme.base0D # 12: Bright Blue
      scheme.base0E # 13: Bright Magenta
      scheme.base0C # 14: Bright Cyan
      scheme.base07 # 15: Bright White
    ]
    else [
      # Fallback neutral palette
      "0d0d0d"
      "cc241d"
      "98971a"
      "d79921"
      "458588"
      "b16286"
      "689d6a"
      "d0d0d0"
      "3a3a3a"
      "fb4934"
      "b8bb26"
      "fabd2f"
      "83a598"
      "d3869b"
      "8ec07c"
      "f0f0f0"
    ];
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    fonts.packages =
      [(getFontPackage fontCfg.family) pkgs.dejavu_fonts pkgs.noto-fonts-color-emoji]
      ++ config.hydrix.graphical.font.extraPackages;

    # Font rendering settings for sharp text
    fonts.fontconfig = {
      enable = true;
      antialias = true;
      hinting = {
        enable = true;
        style = "full"; # full hinting for sharp edges (slight/medium/full)
        autohint = false; # use font's native hints
      };
      subpixel = {
        rgba = "rgb"; # most common LCD layout
        lcdfilter = "default"; # balanced sharpness/color fringing
      };

      # System-wide font aliases. Apps that don't set an explicit font family
      # (e.g. alacritty's font.normal.family is left unset, by design) resolve
      # "monospace"/"sans-serif"/etc via these -- Stylix's fontconfig target
      # used to set this from stylix.fonts.*; this is the native equivalent.
      defaultFonts = {
        monospace = [fontCfg.family];
        sansSerif = [fontCfg.family];
        serif = ["DejaVu Serif"];
        emoji = ["Noto Color Emoji"];
      };
    };

    # Console (TTY) colors - set directly from colorscheme
    # This applies the colorscheme to Linux virtual consoles (Ctrl+Alt+F1-F6) and boot text
    console.colors = ttyColorsFromScheme resolvedScheme;
  };
}
