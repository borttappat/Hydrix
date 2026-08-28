# Stylix Theming Configuration (opt-in)
#
# Only loaded when the consuming flake supplies the `stylix` input (see
# "Stylix (opt-in theming)" in DOCUMENTATION.md for the full picture:
# autoTheme/exclusive tiers, hasStylix gating, per-app handoff).
#
# Supports:
# - Pre-converted base16 YAML schemes (colorschemes/base16/*.yaml)
# - Pywal JSON conversion at build time (colorschemes/*.json)
# - VM-type based colors (pentest=red, comms=blue, browsing=green, dev=purple)
#
# Usage in profiles:
#   hydrix.graphical.colorscheme = "hydrix";  # Auto-converts colorschemes/hydrix.json
#   # Add more with `save-colorscheme <name>`, then reference by that name
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Shared pywal->base16 conversion + vmType fallback palettes (also used by
  # theming/boot/*.nix and theming/dm/greetd.nix for build-time colors).
  hydrixTheme = import ../lib.nix {inherit lib pkgs;};
  inherit (hydrixTheme) pywalToBase16 vmTypeColors;

  # Username from hydrix.username option (see modules/options.nix)
  username = config.hydrix.username;

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
  # When vmColors.enable is true, VMs use the host's colorscheme for Stylix
  # (the VM's own colorscheme is only used for alacritty text colors)
  vmColorsEnabled = config.hydrix.vmColors.enable;
  hostColorscheme = config.hydrix.vmColors.hostColorscheme;
  vmColorscheme = config.hydrix.colorscheme; # VM's own colorscheme (for alacritty text)

  # Effective colorscheme for Stylix: use host's if vmColors enabled, otherwise VM's own
  colorscheme =
    if vmColorsEnabled && hostColorscheme != null
    then hostColorscheme
    else vmColorscheme;

  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";

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
in {
  # Options are defined in options.nix (single source of truth)
  # This module only configures Stylix using those options

  config = lib.mkIf config.hydrix.graphical.enable {
    stylix.enable = true;
    stylix.enableReleaseChecks = false;

    # Stylix base16 scheme
    stylix.base16Scheme = resolvedScheme;

    # Dark mode
    stylix.polarity = config.hydrix.graphical.polarity;

    # Wallpaper (required by Stylix)
    # Derived from the resolved colorscheme JSON's "wallpaper" field, a bare
    # filename colocated in the same directory as the JSON itself. Every step
    # is existence-checked and falls through to a solid color placeholder.
    # VMs never get a real wallpaper here: waypipe forwards individual app
    # windows, not a full desktop, so there's no visual benefit, only closure cost.
    stylix.image = let
      wallpaperField =
        if hasPywalJson
        then (builtins.fromJSON (builtins.readFile pywalJsonPath)).wallpaper or null
        else null;
      wallpaperCandidate =
        if wallpaperField != null && wallpaperField != ""
        then builtins.dirOf pywalJsonPath + "/${wallpaperField}"
        else null;
      wallpaperFromScheme =
        if !isVM && wallpaperCandidate != null && builtins.pathExists wallpaperCandidate
        then wallpaperCandidate
        else null;
    in
      if wallpaperFromScheme != null
      then wallpaperFromScheme
      else
        pkgs.runCommand "wallpaper.png" {buildInputs = [pkgs.imagemagick];} ''
          convert -size 1920x1080 xc:#${resolvedScheme.base00 or "0B0E1B"} $out
        '';

    # Font family/size (native-theme.nix already sets fonts.packages/fontconfig
    # directly; this just tells Stylix's own targets which family/sizes to use)
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
        popups = builtins.floor (fontCfg.size * 1.2);
      };
    };

    stylix.autoEnable = config.hydrix.graphical.stylix.autoTheme;

    # System-level targets
    stylix.targets = {
      fish.enable = lib.mkDefault true;
      font-packages.enable = lib.mkDefault true;
      fontconfig.enable = lib.mkDefault true;
      gtk.enable = lib.mkDefault true;
      gtksourceview.enable = lib.mkDefault true;
      qt.enable = lib.mkDefault true;
    };

    # Home Manager Stylix targets
    home-manager.users.${username}.stylix = {
      autoEnable = config.hydrix.graphical.stylix.autoTheme;
      targets = {
        alacritty.enable = lib.mkDefault config.hydrix.graphical.stylix.exclusive;
        bat.enable = lib.mkDefault true;
        cava.enable = lib.mkDefault true;
        firefox = {
          enable = lib.mkDefault true;
          profileNames = lib.mkDefault ["default"];
        };
        font-packages.enable = lib.mkDefault true;
        fontconfig.enable = lib.mkDefault true;
        gtk.enable = lib.mkDefault true;
        gtksourceview.enable = lib.mkDefault true;
        mpv.enable = lib.mkDefault true;
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
