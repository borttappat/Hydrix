# Shared colorscheme resolution — used by stylix.nix and any module that
# needs the active base16 palette at build time (GRUB theme, Plymouth splash,
# greetd login manager, etc.), so a machine's hydrix.colorscheme choice
# propagates everywhere without each consumer re-implementing resolution.
{ lib, pkgs }:
let
  # Convert pywal JSON to base16 attribute set.
  # Pywal format: { colors: { color0: "#XXXXXX", ... }, special: { background, foreground, cursor } }
  # Base16 format: { base00: "XXXXXX", base01: "XXXXXX", ... } (no leading '#')
  pywalToBase16 = pywalJson:
    let
      data = builtins.fromJSON (builtins.readFile pywalJson);
      colors = data.colors;
      special = data.special or {};

      strip = c: builtins.substring 1 6 c;

      getColor = key: fallback:
        if colors ? ${key} then strip colors.${key}
        else strip fallback;

      bg = strip (special.background or colors.color0);
      fg = strip (special.foreground or colors.color7);
    in {
      base00 = bg;
      base01 = getColor "color8" colors.color0;
      base02 = getColor "color8" colors.color0;
      base03 = getColor "color8" colors.color0;
      base04 = getColor "color7" colors.color15;
      base05 = fg;
      base06 = getColor "color15" colors.color7;
      base07 = getColor "color15" colors.color7;
      base08 = getColor "color1" "#cc241d";
      base09 = getColor "color9" "#d65d0e";
      base0A = getColor "color3" "#d79921";
      base0B = getColor "color2" "#98971a";
      base0C = getColor "color6" "#689d6a";
      base0D = getColor "color4" "#458588";
      base0E = getColor "color5" "#b16286";
      base0F = getColor "color1" "#9d0006";
    };

  # VM-type color palettes (fallback if no colorscheme resolves)
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
      base00 = "0B0E1B"; base01 = "1B5D68"; base02 = "156D73"; base03 = "659b94";
      base04 = "659b94"; base05 = "91ded4"; base06 = "91ded4"; base07 = "91ded4";
      base08 = "1B5D68"; base09 = "156D73"; base0A = "1E877A"; base0B = "1C7787";
      base0C = "138C89"; base0D = "26A19B"; base0E = "1E877A"; base0F = "1B5D68";
    };
  };
in {
  # Exposed for consumers (stylix.nix) that need to reconstruct their own
  # priority order — e.g. preferring a base16 YAML path (unparseable in pure
  # Nix, so resolveScheme below can't use it) over the pywal/vmType fallback.
  inherit pywalToBase16 vmTypeColors;

  # resolveScheme :: config -> attrset of base16 -> "RRGGBB" (no '#') hex strings.
  #
  # Resolution order matches stylix.nix's own: pre-converted base16 YAML (not
  # parseable in pure Nix — falls through, same limitation stylix.nix already
  # has for this case), pywal JSON conversion, then vmType fallback.
  resolveScheme = config:
    let
      vmColorsEnabled = config.hydrix.vmColors.enable;
      hostColorscheme = config.hydrix.vmColors.hostColorscheme;
      vmColorscheme = config.hydrix.colorscheme;
      colorscheme = if vmColorsEnabled && hostColorscheme != null
        then hostColorscheme
        else vmColorscheme;
      vmType = config.hydrix.vmType;

      pywalJsonPath = if colorscheme != null then config.hydrix.resolveColorscheme colorscheme else null;
      hasPywalJson = pywalJsonPath != null && builtins.pathExists pywalJsonPath;

      raw =
        if hasPywalJson then pywalToBase16 pywalJsonPath
        else if vmType != null && vmTypeColors ? ${vmType} then vmTypeColors.${vmType}
        else vmTypeColors.host;
    in
      # Guards against the base16-YAML case (a path, not an attrset) the same
      # way stylix.nix's ttyColorsFromScheme does — falls back to a neutral
      # palette rather than erroring.
      if builtins.isAttrs raw then raw else vmTypeColors.host;
}
