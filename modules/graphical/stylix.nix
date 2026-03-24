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

  # Convert pywal JSON to base16 attribute set
  # Pywal format: { colors: { color0: "#XXXXXX", ... }, special: { background, foreground, cursor } }
  # Base16 format: { base00: "XXXXXX", base01: "XXXXXX", ... }
  pywalToBase16 = pywalJson:
    let
      # Read and parse the JSON
      data = builtins.fromJSON (builtins.readFile pywalJson);
      colors = data.colors;
      special = data.special or {};

      # Strip # from color values
      strip = c: builtins.substring 1 6 c;

      # Get color with fallback
      getColor = key: fallback:
        if colors ? ${key} then strip colors.${key}
        else strip fallback;

      # Background/foreground from special or fallback to color0/color7
      bg = strip (special.background or colors.color0);
      fg = strip (special.foreground or colors.color7);

    in {
      # Base16 mapping from pywal colors
      # Backgrounds
      base00 = bg;                              # Default Background
      base01 = getColor "color8" colors.color0; # Lighter Background (status bars)
      base02 = getColor "color8" colors.color0; # Selection Background
      base03 = getColor "color8" colors.color0; # Comments, Invisibles

      # Foregrounds
      base04 = getColor "color7" colors.color15; # Dark Foreground (status bars)
      base05 = fg;                               # Default Foreground
      base06 = getColor "color15" colors.color7; # Light Foreground
      base07 = getColor "color15" colors.color7; # Light Background

      # Accent colors (syntax highlighting, UI elements)
      base08 = getColor "color1" "#cc241d";  # Variables, XML Tags, Markup Link Text, Error
      base09 = getColor "color9" "#d65d0e";  # Integers, Boolean, Constants, Markup Link URL
      base0A = getColor "color3" "#d79921";  # Classes, Markup Bold, Search Background
      base0B = getColor "color2" "#98971a";  # Strings, Inherited Class, Markup Code
      base0C = getColor "color6" "#689d6a";  # Support, Regex, Escape, Markup Quotes
      base0D = getColor "color4" "#458588";  # Functions, Methods, Headings
      base0E = getColor "color5" "#b16286";  # Keywords, Storage, Selector
      base0F = getColor "color1" "#9d0006";  # Deprecated, Embedded Language Tags
    };

  # VM-type color palettes (fallback if no colorscheme specified)
  vmTypeColors = {
    pentest = {
      base00 = "0d0d0d"; base01 = "1a1a1a"; base02 = "2a2a2a"; base03 = "3a3a3a";
      base04 = "b0b0b0"; base05 = "d0d0d0"; base06 = "e0e0e0"; base07 = "f0f0f0";
      base08 = "cc241d"; base09 = "d65d0e"; base0A = "d79921"; base0B = "689d6a";
      base0C = "689d6a"; base0D = "458588"; base0E = "cc241d"; base0F = "9d0006";
    };
    comms = {
      base00 = "0d0d1a"; base01 = "1a1a2a"; base02 = "2a2a3a"; base03 = "3a3a4a";
      base04 = "b0b0c0"; base05 = "d0d0e0"; base06 = "e0e0f0"; base07 = "f0f0ff";
      base08 = "cc241d"; base09 = "d65d0e"; base0A = "d79921"; base0B = "98971a";
      base0C = "689d6a"; base0D = "458588"; base0E = "b16286"; base0F = "9d0006";
    };
    browsing = {
      base00 = "0d1a0d"; base01 = "1a2a1a"; base02 = "2a3a2a"; base03 = "3a4a3a";
      base04 = "b0c0b0"; base05 = "d0e0d0"; base06 = "e0f0e0"; base07 = "f0fff0";
      base08 = "cc241d"; base09 = "d65d0e"; base0A = "d79921"; base0B = "98971a";
      base0C = "689d6a"; base0D = "458588"; base0E = "b16286"; base0F = "9d0006";
    };
    dev = {
      base00 = "1a0d1a"; base01 = "2a1a2a"; base02 = "3a2a3a"; base03 = "4a3a4a";
      base04 = "c0b0c0"; base05 = "e0d0e0"; base06 = "f0e0f0"; base07 = "fff0ff";
      base08 = "cc241d"; base09 = "d65d0e"; base0A = "d79921"; base0B = "98971a";
      base0C = "689d6a"; base0D = "458588"; base0E = "b16286"; base0F = "9d0006";
    };
    host = {
      # Default teal/cyan theme (hydrix default)
      base00 = "0B0E1B"; base01 = "1B5D68"; base02 = "156D73"; base03 = "659b94";
      base04 = "659b94"; base05 = "91ded4"; base06 = "91ded4"; base07 = "91ded4";
      base08 = "1B5D68"; base09 = "156D73"; base0A = "1E877A"; base0B = "1C7787";
      base0C = "138C89"; base0D = "26A19B"; base0E = "1E877A"; base0F = "1B5D68";
    };
  };

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
  base16YamlPath = ../../colorschemes/base16/${colorscheme}.yaml;
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
    # Hydrix uses i3 — we whitelist only the targets we actually use.
    # Runtime theming (walrgb/pywal) is unaffected — it operates independently.
    stylix.autoEnable = false;

    # System-level targets
    stylix.targets = {
      fish.enable = true;
      font-packages.enable = true;
      fontconfig.enable = true;
      gtk.enable = true;
      gtksourceview.enable = true;
      qt.enable = true;
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
        alacritty.enable = !vmColorsEnabled;
        bat.enable = true;
        btop.enable = true;
        cava.enable = true;
        feh.enable = true;
        firefox = { enable = true; profileNames = [ "default" ]; };
        font-packages.enable = true;
        fontconfig.enable = true;
        gtk.enable = true;
        gtksourceview.enable = true;
        mpv.enable = true;
        obsidian.enable = true;
        qt.enable = true;
        starship.enable = true;
        tmux.enable = true;
        xresources.enable = true;
        zathura.enable = true;
      };
    };
  };
}
