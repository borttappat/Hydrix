# Stylix Theming Configuration
#
# Provides automatic theming via Stylix with support for:
# - Pre-converted base16 YAML schemes (colorschemes/base16/*.yaml)
# - Pywal JSON conversion at build time (colorschemes/*.json)
# - VM-type based colors (pentest=red, comms=blue, browsing=green, dev=purple)
#
# Usage in profiles:
#   hydrix.graphical.colorscheme = "hydrix";  # Uses colorschemes/base16/hydrix.yaml
#   # OR
#   hydrix.graphical.colorscheme = "nvid";    # Auto-converts colorschemes/nvid.json if no yaml exists

{ config, lib, pkgs, ... }:

let
  # Shared pywal->base16 conversion + vmType fallback palettes (also used by
  # theming/boot/*.nix and theming/dm/greetd.nix for build-time colors).
  hydrixTheme = import ../lib.nix { inherit lib pkgs; };
  inherit (hydrixTheme) pywalToBase16 vmTypeColors;

  # Username from hydrix.username option (see modules/options.nix)
  username = config.hydrix.username;

  # Font configuration from unified options
  fontCfg = config.hydrix.graphical.font;

  # Map font family names to packages (populated by hydrix.graphical.font.packageMap option)
  fontPackageMap = config.hydrix.graphical.font.packageMap;

  # Get font package for family name (with fallback)
  getFontPackage = name:
    if fontPackageMap ? ${name} then fontPackageMap.${name}
    else builtins.head (config.hydrix.graphical.font.packages ++ [ pkgs.iosevka ]);

  # Determine which color scheme to use
  # When vmColors.enable is true, VMs use the host's colorscheme for Stylix
  # (the VM's own colorscheme is only used for alacritty text colors)
  vmColorsEnabled = config.hydrix.vmColors.enable;
  hostColorscheme = config.hydrix.vmColors.hostColorscheme;
  vmColorscheme = config.hydrix.colorscheme;  # VM's own colorscheme (for alacritty text)

  # Effective colorscheme for Stylix: use host's if vmColors enabled, otherwise VM's own
  colorscheme = if vmColorsEnabled && hostColorscheme != null
    then hostColorscheme
    else vmColorscheme;

  vmType = config.hydrix.vmType;

  # Check for pre-converted base16 YAML
  base16YamlPath = ../colorschemes/base16/${colorscheme}.yaml;
  hasBase16Yaml = colorscheme != null && builtins.pathExists base16YamlPath;

  # Check for pywal JSON to convert (user colorschemes first, then framework)
  pywalJsonPath = if colorscheme != null then config.hydrix.resolveColorscheme colorscheme else null;
  hasPywalJson = pywalJsonPath != null && builtins.pathExists pywalJsonPath;

  # Resolve final scheme
  resolvedScheme =
    if hasBase16Yaml then base16YamlPath
    else if hasPywalJson then pywalToBase16 pywalJsonPath
    else if vmType != null && vmTypeColors ? ${vmType} then vmTypeColors.${vmType}
    else vmTypeColors.host;

  # Extract 16 colors from base16 scheme for console.colors (TTY)
  # Maps base16 colors to ANSI terminal colors
  ttyColorsFromScheme = scheme:
    if builtins.isAttrs scheme then [
      scheme.base00  # 0: Black (background)
      scheme.base08  # 1: Red
      scheme.base0B  # 2: Green
      scheme.base0A  # 3: Yellow
      scheme.base0D  # 4: Blue
      scheme.base0E  # 5: Magenta
      scheme.base0C  # 6: Cyan
      scheme.base05  # 7: White (foreground)
      scheme.base03  # 8: Bright Black
      scheme.base08  # 9: Bright Red (same as base)
      scheme.base0B  # 10: Bright Green
      scheme.base0A  # 11: Bright Yellow
      scheme.base0D  # 12: Bright Blue
      scheme.base0E  # 13: Bright Magenta
      scheme.base0C  # 14: Bright Cyan
      scheme.base07  # 15: Bright White
    ] else [
      # Fallback neutral palette
      "0d0d0d" "cc241d" "98971a" "d79921"
      "458588" "b16286" "689d6a" "d0d0d0"
      "3a3a3a" "fb4934" "b8bb26" "fabd2f"
      "83a598" "d3869b" "8ec07c" "f0f0f0"
    ];

in {
  # Options are defined in options.nix (single source of truth)
  # This module only configures Stylix using those options

  config = lib.mkIf config.hydrix.graphical.enable {
    # Stylix base16 scheme
    stylix.base16Scheme = resolvedScheme;

    # Dark mode
    stylix.polarity = config.hydrix.graphical.polarity;

    # Wallpaper (required by Stylix)
    # If no wallpaper specified, create a simple solid color placeholder
    stylix.image =
      if config.hydrix.graphical.wallpaper != null
      then config.hydrix.graphical.wallpaper
      else pkgs.runCommand "wallpaper.png" { buildInputs = [ pkgs.imagemagick ]; } ''
        convert -size 1920x1080 xc:#${resolvedScheme.base00 or "0B0E1B"} $out
      '';

    # Font configuration from unified options
    fonts.packages = [ (getFontPackage fontCfg.family) ] ++ config.hydrix.graphical.font.extraPackages;

    # Font rendering settings for sharp text
    fonts.fontconfig = {
      enable = true;
      antialias = true;
      hinting = {
        enable = true;
        style = "full";  # full hinting for sharp edges (slight/medium/full)
        autohint = false;  # use font's native hints
      };
      subpixel = {
        rgba = "rgb";  # most common LCD layout
        lcdfilter = "default";  # balanced sharpness/color fringing
      };
    };

    stylix.fonts = {
      monospace = {
        name = fontCfg.family;
        package = getFontPackage fontCfg.family;
      };
      sansSerif = {
        name = fontCfg.family;
        package = getFontPackage fontCfg.family;
      };
      serif = {
        package = pkgs.dejavu_fonts;
        name = "DejaVu Serif";
      };
      emoji = {
        package = pkgs.noto-fonts-color-emoji;
        name = "Noto Color Emoji";
      };
      # Base sizes - scaled per-app at runtime via scaling.json
      sizes = {
        terminal = fontCfg.size;
        applications = fontCfg.size;
        desktop = fontCfg.size;
        popups = builtins.floor (fontCfg.size * (fontCfg.relations.rofi or 1.2));
      };
    };

    # Disable auto-enable so Stylix doesn't theme every DE/app it knows about.
    # Hydrix uses i3. We whitelist only the targets we actually use.
    # Runtime theming (walrgb/pywal) is unaffected — it operates independently.
    stylix.autoEnable = false;

    # System-level targets
    stylix.targets = {
      fish.enable = lib.mkDefault true;
      font-packages.enable = lib.mkDefault true;
      fontconfig.enable = lib.mkDefault true;
      gtk.enable = lib.mkDefault true;
      gtksourceview.enable = lib.mkDefault true;
      qt.enable = lib.mkDefault true;
    };

    # Console (TTY) colors - set directly from colorscheme
    # Stylix's console target is buggy (passes malformed kernel params), so we use NixOS native option
    # This applies the colorscheme to Linux virtual consoles (Ctrl+Alt+F1-F6) and boot text
    console.colors = ttyColorsFromScheme resolvedScheme;

    # Home Manager Stylix targets
    home-manager.users.${username}.stylix = {
      autoEnable = false;
      targets = {
        # Alacritty: disabled when vmColors enabled — colors come from
        # colors-runtime.toml (written by write-alacritty-colors on vsock push)
        alacritty.enable = lib.mkDefault false;
        bat.enable = lib.mkDefault true;
        cava.enable = lib.mkDefault true;
        feh.enable = lib.mkDefault true;
        firefox = { enable = lib.mkDefault true; profileNames = lib.mkDefault [ "default" ]; };
        font-packages.enable = lib.mkDefault true;
        fontconfig.enable = lib.mkDefault true;
        gtk.enable = lib.mkDefault true;
        gtksourceview.enable = lib.mkDefault true;
        mpv.enable = lib.mkDefault true;
        obsidian.enable = lib.mkDefault true;
        qt.enable = lib.mkDefault true;
        starship.enable = lib.mkDefault true;
        tmux.enable = lib.mkDefault true;
        xresources.enable = lib.mkDefault true;
        zathura.enable = lib.mkDefault true;
        vim.enable = lib.mkDefault false;
      };
    };
  };
}
