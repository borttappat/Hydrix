# Font Profile Loader
#
# Auto-selects a font profile based on font.family.
# Each profile provides per-app sizes, family overrides, and UI adjustments
# using lib.mkDefault so user config in machines/<serial>.nix always wins.
#
# To add a new font: create <name>.nix, add to imports and familyToProfile.

{ config, lib, ... }:

let
  cfg = config.hydrix.graphical;

  # Map font family names to profile names (populated by hydrix.graphical.font.profileMap option)
  familyToProfile = cfg.font.profileMap;

  effectiveProfile =
    if cfg.font.profile != null
    then cfg.font.profile
    else familyToProfile.${cfg.font.family} or "iosevka";
in {
  # Font profiles are now defined in user-config (hydrix-config/fonts/)
  # and loaded via hydrix.graphical.font.profileMap

  # Options defined here rather than in modules/options.nix because they
  # are internal to the font profile subsystem
  options.hydrix.graphical.font.profile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Font profile name. Auto-detected from font.family if null.
      Profiles provide per-app font sizes, family overrides, and UI adjustments.
      User config in machines/<serial>.nix overrides profile defaults.
    '';
  };

  options.hydrix.graphical.font._resolvedProfile = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = effectiveProfile;
    internal = true;
  };
}
