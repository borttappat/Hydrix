# Dynamic Hardware-Aware DPI Scaling
#
# Implements automatic DPI normalization:
# 1. Detects external monitor DPI (Master DPI)
# 2. Sets internal display to resolution matching Master DPI
# 3. Generates scaling.json with all calculated values
# 4. Creates app-specific config snippets in ~/.config/hydrix/dynamic/
#
# All configuration comes from hydrix.graphical.* options (see options.nix)

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType or null;
  isVM = vmType != null && vmType != "host";

  # Runtime dependencies
  runtimeDeps = with pkgs; [ jq bc gnused gnugrep gawk coreutils xorg.xrandr ];

  # Generate font relations JSON from Nix options
  fontRelationsJson = pkgs.writeText "font-relations.json" (builtins.toJSON {
    name = cfg.font.family;
    relations = cfg.font.relations;
  });

  # Generate standalone relations JSON (machine-specific overrides for standalone mode)
  standaloneRelationsJson = pkgs.writeText "standalone-relations.json" (builtins.toJSON cfg.font.standaloneRelations);

  # Generate font overrides JSON
  fontOverridesJson = pkgs.writeText "font-overrides.json" (builtins.toJSON cfg.font.overrides);

  # Generate font family sizes JSON
  familySizesJson = pkgs.writeText "family-sizes.json" (builtins.toJSON cfg.font.familySizes);

  # Generate font family overrides JSON
  familyOverridesJson = pkgs.writeText "family-overrides.json" (builtins.toJSON cfg.font.familyOverrides);

  # Generate font max sizes JSON
  fontMaxSizesJson = pkgs.writeText "font-max-sizes.json" (builtins.toJSON cfg.font.maxSizes);

  # Generate bar height family relations JSON
  barHeightFamilyRelationsJson = pkgs.writeText "bar-height-family-relations.json" (builtins.toJSON cfg.ui.barHeightFamilyRelations);

  # Determine polybar font family (override or default)
  polybarFontFamily = cfg.font.familyOverrides.polybar or cfg.font.family;

  # Compute overlay alpha hex from alacritty's effective opacity
  # This ensures dunst/rofi/polybar use the same opacity as alacritty's window.opacity
  overlayAlphaHex = let
    opacityCfg = cfg.ui.opacity;
    effectiveOpacity = opacityCfg.overlayOverrides.alacritty or opacityCfg.alacritty;
    intVal = builtins.floor (effectiveOpacity * 255 + 0.5);
  in lib.fixedWidthString 2 "0" (lib.toHexString intVal);

  # Config templates (in modules/graphical/templates/)
  configTemplates = pkgs.runCommand "hydrix-config-templates" {} ''
    mkdir -p $out
    cp ${./templates/alacritty.toml} $out/alacritty.toml
    cp ${./templates/polybar.ini} $out/polybar.ini
    cp ${./templates/rofi.rasi} $out/rofi.rasi
    cp ${./templates/dunst.ini} $out/dunst.ini
    cp ${./templates/picom.conf} $out/picom.conf
    cp ${./templates/firefox-user.js} $out/firefox-user.js
  '';

  # The main hydrix-scale script
  hydrixScaleScript = pkgs.writeShellScriptBin "hydrix-scale" ''
    #!/usr/bin/env bash
    # hydrix-scale - Dynamic Scaling Engine
    # Configuration from Nix options (hydrix.graphical.*)

    set -euo pipefail

    # === Paths ===
    CONFIG_DIR="$HOME/.config/hydrix"
    STATE_FILE="$CONFIG_DIR/scaling.json"
    DYNAMIC_DIR="$CONFIG_DIR/dynamic"
    TEMPLATE_DIR="${configTemplates}"
    FONT_RELATIONS="${fontRelationsJson}"
    STANDALONE_RELATIONS="${standaloneRelationsJson}"
    FONT_OVERRIDES="${fontOverridesJson}"
    FAMILY_SIZES="${familySizesJson}"
    FAMILY_OVERRIDES="${familyOverridesJson}"
    FONT_MAX_SIZES="${fontMaxSizesJson}"
    BAR_HEIGHT_FAMILY_RELATIONS="${barHeightFamilyRelationsJson}"
    POLYBAR_FONT="${polybarFontFamily}"
    POLYBAR_FONT_OFFSET=${toString cfg.ui.polybarFontOffset}

    # === Dependencies ===
    XRANDR="${pkgs.xorg.xrandr}/bin/xrandr"
    JQ="${pkgs.jq}/bin/jq"
    BC="${pkgs.bc}/bin/bc"
    SED="${pkgs.gnused}/bin/sed"
    GREP="${pkgs.gnugrep}/bin/grep"
    AWK="${pkgs.gawk}/bin/awk"

    # === Configuration from Nix ===
    FONT_NAME="${cfg.font.family}"
    REF_DPI=${toString cfg.scaling.referenceDpi}
    INTERNAL_RES="${if cfg.scaling.internalResolution != null then cfg.scaling.internalResolution else ""}"
    STANDALONE_SCALE=${toString cfg.scaling.standaloneScaleFactor}
    BASE_FONT=${toString cfg.font.size}
    BASE_BAR_HEIGHT=${toString cfg.ui.barHeight}
    BAR_HEIGHT_REL=${toString cfg.ui.barHeightRelation}
    BASE_BAR_PADDING=${toString cfg.ui.barPadding}
    BASE_GAPS=${toString cfg.ui.gaps}
    GAPS_STANDALONE_REL=${toString cfg.ui.gapsStandaloneRelation}
    BASE_BAR_GAPS=${toString config.hydrix.graphical.scaling.computed.barGaps}
    BAR_EDGE_GAPS_FACTOR=${toString cfg.ui.barEdgeGapsFactor}
    OUTER_GAPS_MATCH_BAR=${if cfg.ui.outerGapsMatchBar then "true" else "false"}
    BASE_BORDER=${toString cfg.ui.border}
    BASE_PADDING=${toString cfg.ui.padding}
    BASE_PADDING_SMALL=${toString cfg.ui.paddingSmall}
    BASE_CORNER_RADIUS=${toString cfg.ui.cornerRadius}
    BASE_SHADOW_RADIUS=${toString cfg.ui.shadowRadius}
    BASE_SHADOW_OFFSET=${toString cfg.ui.shadowOffset}
    BASE_ROFI_WIDTH=${toString cfg.ui.rofiWidth}
    BASE_ROFI_HEIGHT=${toString cfg.ui.rofiHeight}
    BASE_DUNST_WIDTH=${toString cfg.ui.dunstWidth}
    BASE_DUNST_OFFSET=${toString cfg.ui.dunstOffset}

    # === Defaults ===
    MODE="host"
    APPLY_XRANDR=false
    RES_STEP=0
    MASTER_SOURCE="unknown"

    # === Parse Arguments ===
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --guest) MODE="guest"; shift ;;
            --apply) APPLY_XRANDR=true; shift ;;
            --step)
                # Step up (+N) or down (-N) from calculated optimal resolution
                RES_STEP="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    # === Setup ===
    mkdir -p "$CONFIG_DIR" "$DYNAMIC_DIR"

    # === Helper Functions ===
    calc_dpi() {
        local w_px=$1 w_mm=$2
        [[ -z "$w_mm" || "$w_mm" -eq 0 ]] && { echo "0"; return; }
        LC_ALL=C echo "scale=2; ($w_px * 25.4) / $w_mm" | $BC
    }

    abs_diff() {
        LC_ALL=C echo "scale=2; x=$1-$2; if (x<0) -x else x" | $BC
    }

    round() { LC_ALL=C printf "%.0f" "$1"; }

    scale_value() { LC_ALL=C echo "scale=2; $1 * $2" | $BC; }

    get_font_relation() {
        local app=$1
        $JQ -r ".relations.$app // 1.0" "$FONT_RELATIONS"
    }

    get_standalone_relation() {
        local app=$1
        $JQ -r ".$app // empty" "$STANDALONE_RELATIONS"
    }

    get_font_override() {
        local app=$1
        $JQ -r ".$app // empty" "$FONT_OVERRIDES"
    }

    get_font_max() {
        local app=$1
        $JQ -r ".$app // empty" "$FONT_MAX_SIZES"
    }

    clamp_font_max() {
        local value=$1 max=$2
        if [[ -n "$max" ]]; then
            local exceeds=$(echo "$value > $max" | $BC)
            if [[ "$exceeds" -eq 1 ]]; then
                echo "$max"
                return
            fi
        fi
        echo "$value"
    }

    get_app_family() {
        local app=$1
        $JQ -r ".$app // \"$FONT_NAME\"" "$FAMILY_OVERRIDES"
    }

    get_family_base_size() {
        local family=$1
        $JQ -r ".\"$family\" // $BASE_FONT" "$FAMILY_SIZES"
    }

    get_bar_height_family_relation() {
        local family=$1
        $JQ -r ".\"$family\" // 1.0" "$BAR_HEIGHT_FAMILY_RELATIONS"
    }

    # === Host Mode: Hardware Detection ===
    detect_hardware() {
        echo "=== Hardware Detection (HOST MODE) ==="

        INTERNAL=$($XRANDR --query | $GREP "eDP" | cut -d' ' -f1 | head -1 || true)
        EXTERNAL=$($XRANDR --query | $GREP " connected" | $GREP -v "eDP" | cut -d' ' -f1 | head -1 || true)

        [[ -z "$INTERNAL" ]] && INTERNAL=$($XRANDR --query | $GREP " connected" | cut -d' ' -f1 | head -1)

        echo "Internal: ''${INTERNAL:-None}, External: ''${EXTERNAL:-None}"

        # Determine Master DPI
        if [[ -n "$EXTERNAL" ]]; then
            EXT_INFO=$($XRANDR --query | $GREP "^$EXTERNAL connected")
            EXT_WIDTH_MM=$(echo "$EXT_INFO" | $GREP -oP '\d+mm' | head -1 | $SED 's/mm//')
            EXT_RES=$($XRANDR --query | $SED -n "/^$EXTERNAL connected/,/^[^ ]/p" | $GREP -oP '\d+x\d+' | head -1)
            EXT_WIDTH_PX=$(echo "$EXT_RES" | cut -d'x' -f1)
            MASTER_DPI=$(calc_dpi "$EXT_WIDTH_PX" "$EXT_WIDTH_MM")
            MASTER_SOURCE="external"
            echo "-> Master: External ($EXTERNAL) - ''${EXT_WIDTH_PX}px / ''${EXT_WIDTH_MM}mm = $MASTER_DPI DPI"
        else
            # No external monitor - STANDALONE MODE
            # Use reference DPI (96) for scale factor 1.0 - keeps fonts at base size
            # This prevents fonts from being scaled up based on high internal DPI
            MASTER_DPI=$REF_DPI
            MASTER_SOURCE="standalone"

            if [[ -n "$INTERNAL_RES" ]]; then
                STANDALONE_RES="$INTERNAL_RES"
                echo "-> Standalone mode: Using configured resolution $INTERNAL_RES"
            else
                STANDALONE_RES=""
                echo "-> Standalone mode: Using native resolution"
            fi
            echo "-> Master DPI: $REF_DPI (reference, for consistent font sizing)"
        fi

        # Find optimal internal resolution
        # Strategy:
        # 1. Collect all resolutions matching native aspect ratio EXACTLY
        # 2. Sort by width (descending - highest first)
        # 3. Find the one closest to MASTER_DPI
        # 4. Apply step offset if specified (--step +1 = one higher res, --step -1 = one lower)
        OPTIMAL_RES=""
        VALID_MODES=()
        VALID_DPIS=()
        OPTIMAL_INDEX=0

        if [[ -n "$INTERNAL" && "$MASTER_SOURCE" == "external" ]]; then
            INT_INFO=$($XRANDR --query | $GREP "^$INTERNAL connected")
            INT_WIDTH_MM=$(echo "$INT_INFO" | $GREP -oP '\d+mm' | head -1 | $SED 's/mm//')
            NATIVE_RES=$($XRANDR --query | $SED -n "/^$INTERNAL connected/,/^[^ ]/p" | $GREP "^   " | head -1 | $AWK '{print $1}')
            NATIVE_W=$(echo "$NATIVE_RES" | cut -d'x' -f1)
            NATIVE_H=$(echo "$NATIVE_RES" | cut -d'x' -f2 | $GREP -oP '^\d+')
            TARGET_RATIO=$(LC_ALL=C echo "scale=6; $NATIVE_W / $NATIVE_H" | $BC)

            echo "-> Native: $NATIVE_RES (ratio $TARGET_RATIO)"

            MODES=$($XRANDR --query | $SED -n "/^$INTERNAL connected/,/^[^ ]/p" | $GREP "^   " | $AWK '{print $1}')

            # Collect all resolutions with EXACT aspect ratio match
            for res in $MODES; do
                w_px=$(echo "$res" | cut -d'x' -f1)
                h_px=$(echo "$res" | cut -d'x' -f2 | $GREP -oP '^\d+')
                [[ -z "$w_px" || -z "$h_px" || "$h_px" -eq 0 ]] && continue

                ratio=$(LC_ALL=C echo "scale=6; $w_px / $h_px" | $BC 2>/dev/null || echo "0")
                ratio_diff=$(abs_diff "$ratio" "$TARGET_RATIO")
                # 0.1% tolerance - effectively exact match (accounts for floating point)
                is_exact_ratio=$(echo "$ratio_diff < 0.001" | $BC 2>/dev/null || echo "0")

                if [[ "$is_exact_ratio" -eq 1 ]]; then
                    dpi=$(calc_dpi "$w_px" "$INT_WIDTH_MM")
                    VALID_MODES+=("$res")
                    VALID_DPIS+=("$dpi")
                fi
            done

            # Sort by width descending (highest resolution first)
            # We'll use indices and sort
            NUM_MODES=''${#VALID_MODES[@]}
            if [[ $NUM_MODES -gt 0 ]]; then
                # Simple bubble sort by width (descending)
                for ((i=0; i<NUM_MODES-1; i++)); do
                    for ((j=i+1; j<NUM_MODES; j++)); do
                        w_i=$(echo "''${VALID_MODES[$i]}" | cut -d'x' -f1)
                        w_j=$(echo "''${VALID_MODES[$j]}" | cut -d'x' -f1)
                        if [[ $w_j -gt $w_i ]]; then
                            # Swap modes
                            tmp="''${VALID_MODES[$i]}"
                            VALID_MODES[$i]="''${VALID_MODES[$j]}"
                            VALID_MODES[$j]="$tmp"
                            # Swap DPIs
                            tmp="''${VALID_DPIS[$i]}"
                            VALID_DPIS[$i]="''${VALID_DPIS[$j]}"
                            VALID_DPIS[$j]="$tmp"
                        fi
                    done
                done

                echo "-> Valid resolutions (native aspect ratio):"
                for ((i=0; i<NUM_MODES; i++)); do
                    echo "   [$i] ''${VALID_MODES[$i]} (''${VALID_DPIS[$i]} DPI)"
                done

                # Find index closest to MASTER_DPI
                MIN_DIFF="9999"
                for ((i=0; i<NUM_MODES; i++)); do
                    diff=$(abs_diff "''${VALID_DPIS[$i]}" "$MASTER_DPI")
                    is_better=$(echo "$diff < $MIN_DIFF" | $BC 2>/dev/null || echo "0")
                    if [[ "$is_better" -eq 1 ]]; then
                        MIN_DIFF="$diff"
                        OPTIMAL_INDEX=$i
                    fi
                done

                echo "-> DPI-matched index: $OPTIMAL_INDEX (''${VALID_MODES[$OPTIMAL_INDEX]})"

                # Apply step offset
                if [[ "$RES_STEP" -ne 0 ]]; then
                    # Negative step = higher resolution (lower index)
                    # Positive step = lower resolution (higher index)
                    NEW_INDEX=$((OPTIMAL_INDEX + RES_STEP))
                    if [[ $NEW_INDEX -lt 0 ]]; then
                        NEW_INDEX=0
                        echo "-> Step clamped to highest resolution"
                    elif [[ $NEW_INDEX -ge $NUM_MODES ]]; then
                        NEW_INDEX=$((NUM_MODES - 1))
                        echo "-> Step clamped to lowest resolution"
                    fi
                    OPTIMAL_INDEX=$NEW_INDEX
                    echo "-> After step $RES_STEP: index $OPTIMAL_INDEX"
                fi

                OPTIMAL_RES="''${VALID_MODES[$OPTIMAL_INDEX]}"
                OPTIMAL_DPI="''${VALID_DPIS[$OPTIMAL_INDEX]}"
                echo "-> Selected: $OPTIMAL_RES ($OPTIMAL_DPI DPI)"
            else
                echo "-> WARNING: No resolutions match native aspect ratio!"
            fi
        fi

        # Apply xrandr
        if [[ "$APPLY_XRANDR" == "true" && -n "$INTERNAL" ]]; then
            if [[ -n "$EXTERNAL" && -n "$OPTIMAL_RES" ]]; then
                # External monitor present: use calculated optimal resolution
                echo "-> Applying: $INTERNAL -> $OPTIMAL_RES (matched to external DPI)"
                $XRANDR --output "$INTERNAL" --mode "$OPTIMAL_RES"
                $XRANDR --output "$EXTERNAL" --auto --above "$INTERNAL"
            elif [[ -z "$EXTERNAL" && -n "$STANDALONE_RES" ]]; then
                # No external, use configured standalone resolution
                echo "-> Applying: $INTERNAL -> $STANDALONE_RES (standalone mode)"
                $XRANDR --output "$INTERNAL" --mode "$STANDALONE_RES"
            fi
        fi

        SCALE_FACTOR=$(LC_ALL=C echo "scale=4; $MASTER_DPI / $REF_DPI" | $BC)

        # Never scale below 1.0 - sub-96 DPI is typically EDID rounding, not a genuinely lower-DPI display
        IS_BELOW_ONE=$(echo "$SCALE_FACTOR < 1.0" | $BC)
        if [[ "$IS_BELOW_ONE" -eq 1 ]]; then
            echo "-> Scale Factor: $SCALE_FACTOR -> clamped to 1.0 (floor)"
            SCALE_FACTOR="1.0000"
        fi

        # Apply standalone scale factor when no external monitor
        if [[ "$MASTER_SOURCE" == "standalone" ]]; then
            SCALE_FACTOR=$(LC_ALL=C echo "scale=4; $SCALE_FACTOR * $STANDALONE_SCALE" | $BC)
            echo "-> Scale Factor: $SCALE_FACTOR (with standalone multiplier $STANDALONE_SCALE)"
        else
            echo "-> Scale Factor: $SCALE_FACTOR"
        fi
    }

    # === Calculate Scaled Values ===
    calculate_values() {
        echo ""
        echo "=== Calculating Scaled Values ==="

        # Font sizes with relations
        # In standalone mode, check standaloneRelations first, fall back to relations
        get_effective_relation() {
          local app=$1
          if [[ "$MASTER_SOURCE" == "standalone" ]]; then
            local standalone_rel=$(get_standalone_relation "$app")
            if [[ -n "$standalone_rel" ]]; then
              echo "$standalone_rel"
              return
            fi
          fi
          get_font_relation "$app"
        }

        REL_ALACRITTY=$(get_effective_relation "alacritty")
        REL_POLYBAR=$(get_effective_relation "polybar")
        REL_ROFI=$(get_effective_relation "rofi")
        REL_DUNST=$(get_effective_relation "dunst")
        REL_FIREFOX=$(get_effective_relation "firefox")
        REL_GTK=$(get_effective_relation "gtk")

        # Determine effective base size per app (based on family)
        FAMILY_ALACRITTY=$(get_app_family "alacritty")
        BASE_ALACRITTY=$(get_family_base_size "$FAMILY_ALACRITTY")

        FAMILY_POLYBAR=$(get_app_family "polybar")
        BASE_POLYBAR=$(get_family_base_size "$FAMILY_POLYBAR")

        FAMILY_ROFI=$(get_app_family "rofi")
        BASE_ROFI=$(get_family_base_size "$FAMILY_ROFI")

        FAMILY_DUNST=$(get_app_family "dunst")
        BASE_DUNST=$(get_family_base_size "$FAMILY_DUNST")

        FAMILY_FIREFOX=$(get_app_family "firefox")
        BASE_FIREFOX=$(get_family_base_size "$FAMILY_FIREFOX")

        FAMILY_GTK=$(get_app_family "gtk")
        BASE_GTK=$(get_family_base_size "$FAMILY_GTK")

        # Base calculations or overrides
        OVR_ALACRITTY=$(get_font_override "alacritty")
        OVR_POLYBAR=$(get_font_override "polybar")
        OVR_ROFI=$(get_font_override "rofi")
        OVR_DUNST=$(get_font_override "dunst")

        # Font scale factor: standalone shrinks geometry but not fonts
        FONT_SCALE=$SCALE_FACTOR
        IS_FONT_BELOW_ONE=$(echo "$FONT_SCALE < 1.0" | $BC)
        [[ "$IS_FONT_BELOW_ONE" -eq 1 ]] && FONT_SCALE="1.0"

        # Alacritty supports fractional font sizes - round to nearest 0.5 for sharp rendering
        # Formula: floor(value * 2 + 0.5) / 2 gives nearest 0.5 increment
        # REL_ALACRITTY already uses standaloneRelations if in standalone mode
        FONT_ALACRITTY_RAW=$(LC_ALL=C echo "scale=4; $BASE_ALACRITTY * $FONT_SCALE * $REL_ALACRITTY" | $BC)
        FONT_ALACRITTY_HALF=$(LC_ALL=C echo "scale=0; ($FONT_ALACRITTY_RAW * 2 + 0.5) / 1" | $BC)
        FONT_ALACRITTY_SCALED=$(LC_ALL=C echo "scale=1; $FONT_ALACRITTY_HALF / 2" | $BC)
        FONT_ALACRITTY=''${OVR_ALACRITTY:-$FONT_ALACRITTY_SCALED}

        FONT_POLYBAR=''${OVR_POLYBAR:-$(round "$(LC_ALL=C echo "$BASE_POLYBAR * $FONT_SCALE * $REL_POLYBAR" | $BC)")}
        FONT_ROFI=''${OVR_ROFI:-$(round "$(LC_ALL=C echo "$BASE_ROFI * $FONT_SCALE * $REL_ROFI" | $BC)")}
        FONT_DUNST=''${OVR_DUNST:-$(round "$(LC_ALL=C echo "$BASE_DUNST * $FONT_SCALE * $REL_DUNST" | $BC)")}
        FONT_FIREFOX=$(round "$(LC_ALL=C echo "$BASE_FIREFOX * $FONT_SCALE * $REL_FIREFOX" | $BC)")
        FONT_GTK=$(round "$(LC_ALL=C echo "$BASE_GTK * $FONT_SCALE * $REL_GTK" | $BC)")

        # Apply max size caps (e.g., bitmap font limits)
        FONT_ALACRITTY=$(clamp_font_max "$FONT_ALACRITTY" "$(get_font_max alacritty)")
        FONT_POLYBAR=$(clamp_font_max "$FONT_POLYBAR" "$(get_font_max polybar)")
        FONT_ROFI=$(clamp_font_max "$FONT_ROFI" "$(get_font_max rofi)")
        FONT_DUNST=$(clamp_font_max "$FONT_DUNST" "$(get_font_max dunst)")
        FONT_FIREFOX=$(clamp_font_max "$FONT_FIREFOX" "$(get_font_max firefox)")
        FONT_GTK=$(clamp_font_max "$FONT_GTK" "$(get_font_max gtk)")

        # UI dimensions
        # Get font-specific bar height relation (e.g., Tamzen = 0.85)
        BAR_HEIGHT_FONT_REL=$(get_bar_height_family_relation "$POLYBAR_FONT")
        BAR_HEIGHT=$(round "$(LC_ALL=C echo "$BASE_BAR_HEIGHT * $SCALE_FACTOR * $BAR_HEIGHT_REL * $BAR_HEIGHT_FONT_REL" | $BC)")
        BAR_PADDING=$(round "$(scale_value $BASE_BAR_PADDING $SCALE_FACTOR)")
        # Bar gaps follow DPI only (not affected by standalone relation)
        BAR_GAPS=$(round "$(LC_ALL=C echo "$BASE_BAR_GAPS * $SCALE_FACTOR" | $BC)")
        # Bar edge gaps: bar-to-screen-edge gaps, controlled by barEdgeGapsFactor
        BAR_EDGE_GAPS=$(round "$(LC_ALL=C echo "$BAR_GAPS * $BAR_EDGE_GAPS_FACTOR" | $BC)")

        # Inner gaps: apply standalone relation only in standalone mode
        GAPS_REL=1.0
        [[ "$MASTER_SOURCE" == "standalone" ]] && GAPS_REL=$GAPS_STANDALONE_REL
        GAPS=$(round "$(LC_ALL=C echo "$BASE_GAPS * $SCALE_FACTOR * $GAPS_REL" | $BC)")

        # Outer gaps: match bar_gaps when outerGapsMatchBar is enabled, else 0
        if [[ "$OUTER_GAPS_MATCH_BAR" == "true" ]]; then
            OUTER_GAPS=$BAR_GAPS
        else
            OUTER_GAPS=0
        fi
        BORDER=$(round "$(scale_value $BASE_BORDER $SCALE_FACTOR)")
        PADDING=$(round "$(scale_value $BASE_PADDING $SCALE_FACTOR)")
        PADDING_SMALL=$(round "$(scale_value $BASE_PADDING_SMALL $SCALE_FACTOR)")
        CORNER_RADIUS=$(round "$(scale_value $BASE_CORNER_RADIUS $SCALE_FACTOR)")
        SHADOW_RADIUS=$(round "$(scale_value $BASE_SHADOW_RADIUS $SCALE_FACTOR)")
        SHADOW_OFFSET=$(round "$(scale_value $BASE_SHADOW_OFFSET $SCALE_FACTOR)")
        ROFI_WIDTH=$(round "$(scale_value $BASE_ROFI_WIDTH $SCALE_FACTOR)")
        ROFI_HEIGHT=$(round "$(scale_value $BASE_ROFI_HEIGHT $SCALE_FACTOR)")
        DUNST_WIDTH=$(round "$(scale_value $BASE_DUNST_WIDTH $SCALE_FACTOR)")
        DUNST_OFFSET=$(round "$(scale_value $BASE_DUNST_OFFSET $SCALE_FACTOR)")
        DUNST_OFFSET_Y=$(round "$(LC_ALL=C echo "$DUNST_OFFSET * 2" | $BC)")

        # Minimums (use bc for alacritty since it's decimal)
        [[ $(echo "$FONT_ALACRITTY < 8" | $BC) -eq 1 ]] && FONT_ALACRITTY=8.0
        [[ "$FONT_POLYBAR" -lt 8 ]] && FONT_POLYBAR=8
        [[ "$BAR_HEIGHT" -lt 1 ]] && BAR_HEIGHT=1
        [[ "$BORDER" -lt 1 ]] && BORDER=1

        echo "Fonts: alacritty=$FONT_ALACRITTY polybar=$FONT_POLYBAR rofi=$FONT_ROFI dunst=$FONT_DUNST"
        echo "UI: gaps=$GAPS border=$BORDER bar_height=$BAR_HEIGHT"
    }

    # === Write State ===
    write_state() {
        echo ""
        echo "=== Writing State ==="

        # Build JSON array of valid resolutions
        VALID_MODES_JSON="[]"
        if [[ ''${#VALID_MODES[@]} -gt 0 ]]; then
            VALID_MODES_JSON="["
            for ((i=0; i<''${#VALID_MODES[@]}; i++)); do
                [[ $i -gt 0 ]] && VALID_MODES_JSON+=","
                VALID_MODES_JSON+="\"''${VALID_MODES[$i]}\""
            done
            VALID_MODES_JSON+="]"
        fi

        cat > "$STATE_FILE" <<EOF
{
  "mode": "$MODE",
  "master_dpi": $MASTER_DPI,
  "master_source": "$MASTER_SOURCE",
  "scale_factor": $SCALE_FACTOR,
  "standalone_scale": $STANDALONE_SCALE,
  "font_name": "$FONT_NAME",
  "monitors": {
    "internal": "''${INTERNAL:-null}",
    "external": "''${EXTERNAL:-null}",
    "optimal_internal_res": "''${OPTIMAL_RES:-null}",
    "standalone_res": "''${INTERNAL_RES:-null}",
    "valid_resolutions": $VALID_MODES_JSON,
    "resolution_index": $OPTIMAL_INDEX,
    "applied_step": $RES_STEP
  },
  "fonts": {
    "alacritty": $FONT_ALACRITTY,
    "polybar": $FONT_POLYBAR,
    "rofi": $FONT_ROFI,
    "dunst": $FONT_DUNST,
    "firefox": $FONT_FIREFOX,
    "gtk": $FONT_GTK
  },
  "font_names": {
    "alacritty": "$FAMILY_ALACRITTY",
    "polybar": "$POLYBAR_FONT",
    "rofi": "$FAMILY_ROFI",
    "dunst": "$FAMILY_DUNST",
    "firefox": "$FAMILY_FIREFOX",
    "gtk": "$FAMILY_GTK"
  },
  "sizes": {
    "bar_height": $BAR_HEIGHT,
    "bar_padding": $BAR_PADDING,
    "gaps": $GAPS,
    "outer_gaps": $OUTER_GAPS,
    "bar_gaps": $BAR_GAPS,
    "bar_edge_gaps": $BAR_EDGE_GAPS,
    "border": $BORDER,
    "padding": $PADDING,
    "padding_small": $PADDING_SMALL,
    "corner_radius": $CORNER_RADIUS,
    "shadow_radius": $SHADOW_RADIUS,
    "shadow_offset": $SHADOW_OFFSET,
    "rofi_width": $ROFI_WIDTH,
    "rofi_height": $ROFI_HEIGHT,
    "dunst_width": $DUNST_WIDTH,
    "dunst_offset": $DUNST_OFFSET,
    "font_offset": $POLYBAR_FONT_OFFSET,
    "overlay_alpha_hex": "${overlayAlphaHex}"
  }
}
EOF
        echo "-> Saved: $STATE_FILE"
    }

    # === Generate Configs ===
    generate_configs() {
        echo ""
        echo "=== Generating Configs ==="

        $SED -e "s/@@FONT_SIZE@@/$FONT_ALACRITTY/g" -e "s/@@FONT_NAME@@/$FAMILY_ALACRITTY/g" \
            "$TEMPLATE_DIR/alacritty.toml" > "$DYNAMIC_DIR/alacritty.toml"

        $SED -e "s/@@FONT_SIZE@@/$FONT_POLYBAR/g" -e "s/@@FONT_NAME@@/$POLYBAR_FONT/g" \
            -e "s/@@BAR_HEIGHT@@/$BAR_HEIGHT/g" -e "s/@@BAR_PADDING@@/$BAR_PADDING/g" \
            -e "s/@@FONT_OFFSET@@/$POLYBAR_FONT_OFFSET/g" \
            "$TEMPLATE_DIR/polybar.ini" > "$DYNAMIC_DIR/polybar.ini"

        $SED -e "s/@@FONT_SIZE@@/$FONT_ROFI/g" -e "s/@@FONT_NAME@@/$FAMILY_ROFI/g" \
            -e "s/@@ROFI_WIDTH@@/$ROFI_WIDTH/g" -e "s/@@ROFI_HEIGHT@@/$ROFI_HEIGHT/g" \
            -e "s/@@PADDING_SMALL@@/$PADDING_SMALL/g" \
            "$TEMPLATE_DIR/rofi.rasi" > "$DYNAMIC_DIR/rofi.rasi"

        $SED -e "s/@@FONT_SIZE@@/$FONT_DUNST/g" -e "s/@@FONT_NAME@@/$FAMILY_DUNST/g" \
            -e "s/@@WIDTH@@/$DUNST_WIDTH/g" -e "s/@@OFFSET@@/$DUNST_OFFSET/g" \
            -e "s/@@OFFSET_Y@@/$DUNST_OFFSET_Y/g" -e "s/@@PADDING@@/$PADDING/g" \
            -e "s/@@BORDER@@/$BORDER/g" -e "s/@@CORNER_RADIUS@@/$CORNER_RADIUS/g" \
            "$TEMPLATE_DIR/dunst.ini" > "$DYNAMIC_DIR/dunst.ini"

        $SED -e "s/@@CORNER_RADIUS@@/$CORNER_RADIUS/g" -e "s/@@SHADOW_RADIUS@@/$SHADOW_RADIUS/g" \
            -e "s/@@SHADOW_OFFSET@@/$SHADOW_OFFSET/g" \
            "$TEMPLATE_DIR/picom.conf" > "$DYNAMIC_DIR/picom.conf"

        $SED -e "s/@@SCALE_FACTOR@@/$SCALE_FACTOR/g" \
            "$TEMPLATE_DIR/firefox-user.js" > "$DYNAMIC_DIR/firefox-user.js"

        echo "-> Written to: $DYNAMIC_DIR/"
    }

    # === Guest Mode ===
    guest_mode() {
        echo "=== Guest Mode ==="
        if [[ ! -f "$STATE_FILE" ]]; then
            echo "Error: $STATE_FILE not found"; exit 1
        fi
        MASTER_DPI=$($JQ -r '.master_dpi' "$STATE_FILE")
        SCALE_FACTOR=$($JQ -r '.scale_factor' "$STATE_FILE")
        echo "-> Read: DPI=$MASTER_DPI Scale=$SCALE_FACTOR"
    }

    # === Main ===
    echo "========================================"
    echo "  Hydrix Dynamic Scaling"
    echo "========================================"
    echo "Mode: $MODE | Font: $FONT_NAME | Apply: $APPLY_XRANDR"
    echo ""

    if [[ "$MODE" == "host" ]]; then
        detect_hardware
    else
        guest_mode
    fi

    calculate_values
    write_state
    generate_configs

    echo ""
    echo "=== Complete ==="
  '';

in {
  # This module now only provides the systemd services and script
  # Options are defined in options.nix

  config = lib.mkIf (cfg.enable && cfg.scaling.auto) {
    environment.systemPackages = [ hydrixScaleScript ] ++ runtimeDeps;

    # Host service
    systemd.user.services.hydrix-scale = lib.mkIf (!isVM) {
      description = "Hydrix Dynamic Scaling";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${hydrixScaleScript}/bin/hydrix-scale${lib.optionalString cfg.scaling.applyOnLogin " --apply"}";
        RemainAfterExit = true;
      };
      environment.DISPLAY = ":0";
    };

    # VM service
    systemd.user.services.hydrix-scale-guest = lib.mkIf isVM {
      description = "Hydrix Dynamic Scaling (Guest)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${hydrixScaleScript}/bin/hydrix-scale --guest";
        RemainAfterExit = true;
      };
    };

    # VM watcher
    systemd.user.paths.hydrix-scale-watch = lib.mkIf isVM {
      description = "Watch for host scaling changes";
      wantedBy = [ "graphical-session.target" ];
      pathConfig = {
        PathChanged = "/home/${username}/.config/hydrix/scaling.json";
        Unit = "hydrix-scale-guest.service";
      };
    };

    # Patch scaling.json font_name on rebuild so it reflects current config.
    # dynamic-scaling only regenerates scaling.json on display events, so
    # after a rebuild with a different font, it would be stale until then.
    # Only updates the global font_name — per-app font_names are left to
    # dynamic-scaling which handles familyOverrides.
    system.activationScripts.updateScalingFont = lib.mkIf (!isVM) {
      text = ''
        SCALING_JSON="/home/${username}/.config/hydrix/scaling.json"
        if [ -f "$SCALING_JSON" ]; then
          ${pkgs.jq}/bin/jq --arg font "${cfg.font.family}" '.font_name = $font' \
            "$SCALING_JSON" > "''${SCALING_JSON}.tmp" && \
            mv "''${SCALING_JSON}.tmp" "$SCALING_JSON"
          chown ${username}:users "$SCALING_JSON"
        fi
      '';
    };
  };
}
