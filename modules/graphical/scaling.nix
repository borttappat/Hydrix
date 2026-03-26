# Scaling Compatibility Layer
#
# Provides backward-compatible scaling.computed.* values from unified options.
# The actual DPI scaling happens at runtime via hydrix-scale.
#
# DEPRECATED: New code should read from scaling.json at runtime.
# This exists only for modules that need build-time values (i3 gaps, etc.)

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  ui = cfg.ui;
  polybarFont = cfg.font.familyOverrides.polybar or cfg.font.family;
  barHeightFamilyRel = ui.barHeightFamilyRelations.${polybarFont} or 1.0;
in {
  options.hydrix.graphical.scaling = {
    # Computed values - aliases to unified ui.* options
    # These are BASE values (not scaled) - actual scaling happens at runtime
    computed = {
      factor = lib.mkOption {
        type = lib.types.float;
        readOnly = true;
        default = 1.0;
        description = "Scale factor placeholder (actual scaling is runtime)";
      };

      gaps = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.gaps;
      };

      border = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.border;
      };

      barHeight = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = builtins.floor (ui.barHeight * ui.barHeightRelation * barHeightFamilyRel);
      };

      barPadding = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.barPadding;
      };

      barGaps = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = if ui.barGaps != null then ui.barGaps else ui.gaps;
        description = "Polybar floating margins (falls back to gaps if not set)";
      };

      outerGaps = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = if ui.outerGapsMatchBar then (if ui.barGaps != null then ui.barGaps else ui.gaps) else 0;
        description = "i3 outer gaps (matches barGaps when outerGapsMatchBar is true, else 0)";
      };

      padding = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.padding;
      };

      paddingSmall = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.paddingSmall;
      };

      cornerRadius = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.cornerRadius;
      };

      shadowRadius = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.shadowRadius;
      };

      shadowOffset = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.shadowOffset;
      };

      rofiWidth = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.rofiWidth;
      };

      rofiHeight = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.rofiHeight;
      };

      dunstWidth = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.dunstWidth;
      };

      dunstOffset = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.dunstOffset;
      };
    };

    # Base values for display-setup.nix fallback
    base = {
      barHeight = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = ui.barHeight;
      };
    };
  };
}
