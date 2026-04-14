# Graphical Helper Scripts
#
# This module provides colorscheme management scripts built directly in Nix.
# These are separate from the shell scripts in hydrix-scripts.nix.
#
# COLORSCHEME COMMANDS (available system-wide)
# --------------------------------------------
#   apply-colorscheme <file.json>   Apply a pywal JSON scheme (temporary)
#   restore-colorscheme             Revert to the nix-configured colorscheme
#   refresh-colors                  Reload all color-aware apps from wal cache
#   nixwal                          Update nix-specific wal cache files
#   init-wal-cache                  Initialize pywal cache from colorscheme
#   firefox-pywal                   Update Firefox via pywalfox
#
# LOCKSCREEN COMMANDS
# -------------------
#   lock                            Lock screen (waits for idle, then locks)
#   lock-instant                    Lock screen immediately
#   generate-lockscreen             Generate lockscreen background image
#
# HOST-ONLY COMMANDS
# ------------------
#   push-colors-to-vms              Push pywal colors to all running VMs
#   display-recover                 Recover display after suspend/resume
#
# VM-ONLY COMMANDS
# ----------------
#   wal-sync                        Sync colors from host
#   set-colorscheme-mode <mode>     Set inheritance mode (full/dynamic/none)
#   get-colorscheme-mode            Show current inheritance mode
#
# UTILITY
# -------
#   pomo                            Pomodoro timer with notification
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.graphical;
  # When vmColors.enable is true, VMs inherit the host colorscheme for wal cache
  # consistency (matches what Stylix uses at build time)
  ownColorscheme = config.hydrix.colorscheme;
  hostColorscheme = config.hydrix.vmColors.hostColorscheme;
  vmColorsEnabled = config.hydrix.vmColors.enable;
  colorscheme =
    if vmColorsEnabled && hostColorscheme != null
    then hostColorscheme
    else ownColorscheme;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";
  colorschemeInheritance = config.hydrix.colorschemeInheritance;
  jq = "${pkgs.jq}/bin/jq";
  xrdb = "${pkgs.xorg.xrdb}/bin/xrdb";
  i3msg = "${pkgs.i3}/bin/i3-msg";

  # Package colorschemes for runtime access
  # Merges framework colorschemes with user colorschemes (user takes priority)
  userCsDir = config.hydrix.userColorschemesDir;
  colorschemesPackage = pkgs.stdenvNoCC.mkDerivation {
    name = "hydrix-colorschemes";
    src = ../../colorschemes;
    installPhase =
      ''
        mkdir -p $out/colorschemes
        cp -r $src/* $out/colorschemes/
      ''
      + lib.optionalString (userCsDir != null) ''
        cp -r ${userCsDir}/*.json $out/colorschemes/ 2>/dev/null || true
        cp -r ${userCsDir}/*.yaml $out/colorschemes/ 2>/dev/null || true
      '';
  };

  # Shared script to refresh all color-aware applications
  # Called by walrgb, randomwalrgb, apply-colorscheme, restore-colorscheme
  refreshColorsScript = pkgs.writeShellScriptBin "refresh-colors" ''
        #!/usr/bin/env bash
        # Refresh all applications with current wal colors
        # Reads from ~/.cache/wal/colors.json

        WAL_COLORS="$HOME/.cache/wal/colors.json"
        WAL_XRES="$HOME/.cache/wal/colors.Xresources"

        if [ ! -f "$WAL_COLORS" ]; then
            echo "Error: No wal colors found at $WAL_COLORS"
            exit 1
        fi

        echo "Refreshing colors from wal cache..."

        # Extract colors
        COLOR0=$(${jq} -r '.colors.color0' "$WAL_COLORS")
        COLOR1=$(${jq} -r '.colors.color1' "$WAL_COLORS")
        COLOR2=$(${jq} -r '.colors.color2' "$WAL_COLORS")
        COLOR3=$(${jq} -r '.colors.color3' "$WAL_COLORS")
        COLOR4=$(${jq} -r '.colors.color4' "$WAL_COLORS")
        COLOR5=$(${jq} -r '.colors.color5' "$WAL_COLORS")
        COLOR6=$(${jq} -r '.colors.color6' "$WAL_COLORS")
        COLOR7=$(${jq} -r '.colors.color7' "$WAL_COLORS")
        COLOR8=$(${jq} -r '.colors.color8' "$WAL_COLORS")
        BG=$(${jq} -r '.special.background' "$WAL_COLORS")
        FG=$(${jq} -r '.special.foreground' "$WAL_COLORS")

        # === Xresources (rofi, i3, urxvt, etc) ===
        echo "  Updating Xresources..."
        if [ -f "$WAL_XRES" ]; then
            ${xrdb} -merge "$WAL_XRES"
        fi
        # Override i3wm.color4 specifically for focused borders
        ${xrdb} -merge <<< "i3wm.color4: $COLOR4"

        # === i3 ===
        echo "  Reloading i3..."
        ${i3msg} reload >/dev/null 2>&1 || true

        # Signal vm-focus-daemon to re-apply border colors
        ${pkgs.procps}/bin/pkill -USR1 -f vm-focus-daemon 2>/dev/null || true

        # === Polybar + display-setup (fixes gaps) ===
        # Skip display-setup in VMs - it would spawn polybar on host displays via xpra
        # VMs just need polybar-msg to restart with new colors
        if [ -e "/mnt/hydrix-config" ]; then
            echo "  Restarting polybar (VM mode)..."
            ${pkgs.polybar}/bin/polybar-msg cmd restart 2>/dev/null || true
        elif command -v display-setup >/dev/null 2>&1; then
            echo "  Running display-setup (polybar + gaps)..."
            display-setup >/dev/null 2>&1 || true
        else
            ${pkgs.polybar}/bin/polybar-msg cmd restart 2>/dev/null || true
        fi

        # === Firefox (pywalfox) ===
        if command -v pywalfox >/dev/null 2>&1; then
            echo "  Updating Firefox..."
            pywalfox update 2>/dev/null || true
        fi

        # === Zathura ===
        echo "  Generating zathura colors..."
        ZATHURA_DIR="$HOME/.config/zathura"
        mkdir -p "$ZATHURA_DIR"
        cat > "$ZATHURA_DIR/zathurarc-wal" << ZEOF
    # Generated by refresh-colors from pywal
    set notification-error-bg "$BG"
    set notification-error-fg "$COLOR1"
    set notification-warning-bg "$BG"
    set notification-warning-fg "$COLOR3"
    set notification-bg "$BG"
    set notification-fg "$COLOR4"

    set completion-group-bg "$BG"
    set completion-group-fg "$COLOR4"
    set completion-bg "$COLOR0"
    set completion-fg "$FG"
    set completion-highlight-bg "$COLOR4"
    set completion-highlight-fg "$BG"

    set index-bg "$BG"
    set index-fg "$COLOR4"
    set index-active-bg "$COLOR4"
    set index-active-fg "$BG"

    set inputbar-bg "$COLOR0"
    set inputbar-fg "$FG"

    set statusbar-bg "$COLOR0"
    set statusbar-fg "$FG"

    set highlight-color "$COLOR3"
    set highlight-active-color "$COLOR4"

    set default-bg "$BG"
    set default-fg "$FG"

    set recolor true
    set recolor-lightcolor "$BG"
    set recolor-darkcolor "$FG"
    set recolor-reverse-video true
    set recolor-keephue false
    ZEOF
        # Link as main config if not managed by home-manager
        if [ ! -L "$ZATHURA_DIR/zathurarc" ]; then
            cp "$ZATHURA_DIR/zathurarc-wal" "$ZATHURA_DIR/zathurarc"
        fi

        # === Dunst ===
        echo "  Regenerating dunst config..."
        if command -v generate-dunstrc >/dev/null 2>&1; then
            generate-dunstrc
        fi
        # Restart dunst to pick up new colors (kill + let systemd restart, or start manually)
        echo "  Restarting dunst..."
        ${pkgs.procps}/bin/pkill -9 dunst 2>/dev/null || true
        sleep 0.3
        # Try systemd first, fall back to direct start
        if systemctl --user start dunst 2>/dev/null; then
            true
        else
            ${pkgs.dunst}/bin/dunst &>/dev/null &
            disown 2>/dev/null || true
        fi

        # === GTK (for virt-manager, nautilus, etc) ===
        # GTK reads colors from the theme, we use wal-gtk if available
        if command -v wal-gtk >/dev/null 2>&1; then
            echo "  Updating GTK theme..."
            wal-gtk 2>/dev/null || true
        fi

        # === Alacritty ===
        # Update runtime colors TOML for live_config_reload (all alacritty instances reload)
        if command -v write-alacritty-colors >/dev/null 2>&1; then
            echo "  Updating alacritty runtime colors..."
            write-alacritty-colors
        fi

        # Send wal escape sequences to terminals (host only - VMs use live_config_reload)
        # VMs don't need sequences because alacritty imports colors-runtime.toml
        WAL_SEQUENCES="$HOME/.cache/wal/sequences"
        if [ -f "$WAL_SEQUENCES" ] && [ ! -e "/mnt/hydrix-config" ]; then
            echo "  Updating terminals via sequences..."
            for pts in /dev/pts/[0-9]*; do
                # Only write to our own terminals
                if [ -O "$pts" ] 2>/dev/null; then
                    ${pkgs.coreutils}/bin/cat "$WAL_SEQUENCES" > "$pts" 2>/dev/null || true
                fi
            done
        fi

        # === Starship prompt ===
        # Uses static config from configs/starship/starship.toml
        # No runtime generation needed

        # === Sync wal cache to hydrix-config for VMs ===
        # VMs mount ~/.config/hydrix via 9p and can read wal colors from there
        # Skip this in VMs (they have /mnt/hydrix-config as a read-only mount)
        HYDRIX_CONFIG="$HOME/.config/hydrix"
        WAL_ACTIVE="$HOME/.cache/wal/.active"
        if [ ! -e "/mnt/hydrix-config" ] && [ -d "$HYDRIX_CONFIG" ] && [ -f "$WAL_COLORS" ]; then
            echo "  Syncing wal cache to hydrix-config..."
            mkdir -p "$HYDRIX_CONFIG/wal"
            cp "$WAL_COLORS" "$HYDRIX_CONFIG/wal/colors.json"
            # Also sync the .active marker so VMs know when wal is active
            if [ -f "$WAL_ACTIVE" ]; then
                touch "$HYDRIX_CONFIG/wal/.active"
            else
                rm -f "$HYDRIX_CONFIG/wal/.active"
            fi

            # Push colors to running VMs via vsock for instant sync (background)
            if command -v push-colors-to-vms >/dev/null 2>&1; then
                echo "  Pushing to VMs via vsock..."
                push-colors-to-vms &
            fi
        fi

        # Final i3 reload to ensure everything (borders, colors, gaps) is consistent
        ${i3msg} reload >/dev/null 2>&1 || true

        echo "Colors refreshed!"
  '';

  # Write alacritty colors TOML from wal colors.json
  # Generates ~/.config/alacritty/colors-runtime.toml for live_config_reload
  # This replaces ANSI sequences injection for VMs - new terminals start with correct colors
  writeAlacrittyColorsScript = pkgs.writeShellScriptBin "write-alacritty-colors" ''
    WAL_COLORS="''${1:-$HOME/.cache/wal/colors.json}"
    ALACRITTY_COLORS="$HOME/.config/alacritty/colors-runtime.toml"

    if [ ! -f "$WAL_COLORS" ]; then
      exit 0
    fi

    mkdir -p "$(dirname "$ALACRITTY_COLORS")"

    # Single jq call to generate full TOML from wal colors.json
    ${jq} -r '
      "# Runtime colors - auto-generated by write-alacritty-colors\n" +
      "[colors.primary]\n" +
      "background = \"" + (.special.background // .colors.color0) + "\"\n" +
      "foreground = \"" + (.special.foreground // .colors.color7) + "\"\n\n" +
      "[colors.normal]\n" +
      "black = \"" + .colors.color0 + "\"\n" +
      "red = \"" + .colors.color1 + "\"\n" +
      "green = \"" + .colors.color2 + "\"\n" +
      "yellow = \"" + .colors.color3 + "\"\n" +
      "blue = \"" + .colors.color4 + "\"\n" +
      "magenta = \"" + .colors.color5 + "\"\n" +
      "cyan = \"" + .colors.color6 + "\"\n" +
      "white = \"" + .colors.color7 + "\"\n\n" +
      "[colors.bright]\n" +
      "black = \"" + .colors.color8 + "\"\n" +
      "red = \"" + (.colors.color9 // .colors.color1) + "\"\n" +
      "green = \"" + (.colors.color10 // .colors.color2) + "\"\n" +
      "yellow = \"" + (.colors.color11 // .colors.color3) + "\"\n" +
      "blue = \"" + (.colors.color12 // .colors.color4) + "\"\n" +
      "magenta = \"" + (.colors.color13 // .colors.color5) + "\"\n" +
      "cyan = \"" + (.colors.color14 // .colors.color6) + "\"\n" +
      "white = \"" + (.colors.color15 // .colors.color7) + "\""
    ' "$WAL_COLORS" > "$ALACRITTY_COLORS.tmp" && mv "$ALACRITTY_COLORS.tmp" "$ALACRITTY_COLORS"
  '';

  # Wrapper to apply a scheme and reload components
  # Creates ~/.cache/wal/.active to signal vm-focus-daemon to use wal colors
  applySchemeScript = pkgs.writeShellScriptBin "apply-colorscheme" ''
    set -euo pipefail
    SCHEME_PATH="$1"
    WAL_ACTIVE="$HOME/.cache/wal/.active"

    if [ ! -f "$SCHEME_PATH" ]; then
        echo "Error: Scheme file not found: $SCHEME_PATH"
        exit 1
    fi

    echo "Applying colorscheme from: $SCHEME_PATH"

    # Check if file is an image or JSON (suppress ImageMagick v7 deprecation warnings)
    if [[ "$SCHEME_PATH" == *.json ]]; then
        ${pkgs.pywal}/bin/wal -q --theme "$SCHEME_PATH" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true
    else
        ${pkgs.pywal}/bin/wal -q -i "$SCHEME_PATH" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true
    fi

    # Mark wal colors as active (vm-focus-daemon will respect this)
    mkdir -p "$(dirname "$WAL_ACTIVE")"
    touch "$WAL_ACTIVE"

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps
    ${refreshColorsScript}/bin/refresh-colors

    echo "Colorscheme active (use restore-colorscheme to revert)"
  '';

  # Script to restore the default nix-configured scheme
  # Removes ~/.cache/wal/.active to return vm-focus-daemon to normal operation
  restoreSchemeScript = pkgs.writeShellScriptBin "restore-colorscheme" ''
    set -euo pipefail
    WAL_ACTIVE="$HOME/.cache/wal/.active"
    VM_SCHEME_JSON="/etc/hydrix-colorscheme.json"
    # Colorschemes packaged in Nix store (always available)
    NIX_COLORSCHEMES="${colorschemesPackage}/colorschemes"

    # Read the default scheme name from /etc (populated by Nix)
    if [ ! -f /etc/hydrix-colorscheme ]; then
        echo "Error: /etc/hydrix-colorscheme not found."
        echo "This system may not have a default colorscheme configured via Nix."
        exit 1
    fi

    SCHEME_NAME=$(cat /etc/hydrix-colorscheme)
    SCHEME_JSON="$NIX_COLORSCHEMES/$SCHEME_NAME.json"

    # Try Nix store path first, then baked JSON (VM fallback)
    # Suppress ImageMagick v7 deprecation warnings
    if [ -f "$SCHEME_JSON" ]; then
        echo "Restoring default colorscheme: $SCHEME_NAME"
        ${pkgs.pywal}/bin/wal -q --theme "$SCHEME_JSON" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true
    elif [ -f "$VM_SCHEME_JSON" ]; then
        echo "Restoring default colorscheme (from /etc): $SCHEME_NAME"
        ${pkgs.pywal}/bin/wal -q --theme "$VM_SCHEME_JSON" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true
    else
        echo "Error: Colorscheme file not found."
        echo "  Tried: $SCHEME_JSON"
        echo "  Tried: $VM_SCHEME_JSON"
        exit 1
    fi

    # Remove the active marker (vm-focus-daemon returns to normal)
    rm -f "$WAL_ACTIVE"

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps
    ${refreshColorsScript}/bin/refresh-colors

    echo "Default colorscheme restored"
  '';

  # Convert pywal colors to a format usable by other tools
  nixWalScript = pkgs.writeShellScriptBin "nixwal" ''
    #!/usr/bin/env bash
    SOURCE="$HOME/.cache/wal/colors"
    TARGET="$HOME/.config/wal/nix-colors"
    mkdir -p "$(dirname "$TARGET")"

    if [ -f "$SOURCE" ]; then
        rm -f "$TARGET"
        while IFS= read -r line; do
            line="''${line//#/}"
            echo "\"$line\"" >> "$TARGET"
        done < "$SOURCE"
        echo "Generated $TARGET"
    fi
  '';

  # Pre-generate lockscreen background from wallpaper
  # Called by walrgb/randomwalrgb after setting wallpaper
  generateLockscreenScript = pkgs.writeShellScriptBin "generate-lockscreen" ''
    #!/usr/bin/env bash
    # Pre-generate blurred lockscreen background with text overlay
    # Runs in background so walrgb returns immediately

    WALLPAPER="$1"
    LOCK_CACHE="$HOME/.cache/lockscreen.png"
    LOCK_LOG="/tmp/lockscreen-gen.log"

    # Configuration (baked at build time)
    FONT="${cfg.lockscreen.font}"
    FONT_SIZE=${toString cfg.lockscreen.fontSize}
    LOCK_TEXT="${cfg.lockscreen.text}"

    # Source wal colors for theming
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      color1="#bf616a"
    fi

    echo "[$(date)] Starting lockscreen generation from: $WALLPAPER" >> "$LOCK_LOG"

    if [ ! -f "$WALLPAPER" ]; then
      echo "[$(date)] Error: Wallpaper not found: $WALLPAPER" >> "$LOCK_LOG"
      exit 1
    fi

    # Detect virtual desktop dimensions and primary monitor position for correct text placement
    VIRT_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
    VIRT_SIZE="''${VIRT_SIZE:-1920x1200}"
    PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected primary " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    [ -z "$PRIMARY_GEOM" ] && PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    MON_X=0; MON_Y=0
    if [ -n "$PRIMARY_GEOM" ]; then
      MON_X=$(echo "$PRIMARY_GEOM" | cut -d+ -f2)
      MON_Y=$(echo "$PRIMARY_GEOM" | cut -d+ -f3)
    fi
    TEXT_X=$((MON_X + 50))
    TEXT_Y=$((MON_Y + 50))

    # Create temp files
    blur_img="/tmp/lockscreen_blur_$$.png"

    ${
      if cfg.lockscreen.blur
      then ''
        # Scale wallpaper to virtual desktop size, then pixelate
        ${pkgs.imagemagick}/bin/magick "$WALLPAPER" -resize "$VIRT_SIZE^" -gravity Center -extent "$VIRT_SIZE" -scale 20% -scale 500% "$blur_img" 2>>"$LOCK_LOG"
      ''
      else ''
        ${pkgs.imagemagick}/bin/magick "$WALLPAPER" -resize "$VIRT_SIZE^" -gravity Center -extent "$VIRT_SIZE" "$blur_img" 2>>"$LOCK_LOG"
      ''
    }

    # Add text overlay on primary monitor (fall back to CozetteVector if font fails - bitmap fonts don't work)
    if ! ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
        -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
        -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" "$LOCK_CACHE" 2>>"$LOCK_LOG"; then
      FONT="CozetteVector"
      ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
          -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
          -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" "$LOCK_CACHE" 2>>"$LOCK_LOG"
    fi

    # Cleanup
    rm -f "$blur_img"

    echo "[$(date)] Lockscreen generated: $LOCK_CACHE" >> "$LOCK_LOG"
  '';

  # Main theme applicator (wallpaper + colors + RGB lighting)
  # Creates ~/.cache/wal/.active to signal vm-focus-daemon to use wal colors
  walRgbScript = pkgs.writeShellScriptBin "walrgb" ''
    #!/usr/bin/env bash
    if [ -z "$1" ]; then
      echo "Usage: walrgb /path/to/image.jpg"
      exit 1
    fi

    FILE_PATH="$1"
    WAL_ACTIVE="$HOME/.cache/wal/.active"

    echo "Setting colorscheme from $FILE_PATH"

    # Generate colors (suppress ImageMagick v7 deprecation warnings)
    ${pkgs.pywal}/bin/wal -q -i "$FILE_PATH" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true

    # Mark wal colors as active (vm-focus-daemon will respect this)
    mkdir -p "$(dirname "$WAL_ACTIVE")"
    touch "$WAL_ACTIVE"

    # RGB Control (ASUS / OpenRGB) - suppress verbose output
    HEX_CODE=$(sed -n '2p' ~/.cache/wal/colors | sed 's/#//')

    if command -v asusctl >/dev/null 2>&1 && asusctl -v >/dev/null 2>&1; then
      echo "Setting ASUS Aura..."
      RUST_LOG=error asusctl aura static -c "$HEX_CODE" 2>/dev/null || true
      RUST_LOG=error asusctl -k high 2>/dev/null || true
    elif command -v openrgb >/dev/null 2>&1; then
      if openrgb --list-devices 2>/dev/null | grep -q "Device"; then
        echo "Setting OpenRGB..."
        openrgb --device 0 --mode static --color "$HEX_CODE" 2>/dev/null || true
      fi
    fi

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps (polybar, i3, zathura, firefox, dunst, etc)
    ${refreshColorsScript}/bin/refresh-colors

    # Pre-generate lockscreen background in background (instant lock on next use)
    ${generateLockscreenScript}/bin/generate-lockscreen "$FILE_PATH" &

    # Push colors to running VMs via vsock (instant sync)
    if command -v push-colors-to-vms >/dev/null 2>&1; then
      echo "Pushing colors to VMs..."
      push-colors-to-vms &
    fi

    echo "Done! (use restore-colorscheme to revert)"
  '';

  # Random wallpaper theme applicator
  randomWalRgbScript = pkgs.writeShellScriptBin "randomwalrgb" ''
    #!/usr/bin/env bash
    WALLPAPER_DIR="''${1:-$HOME/wallpapers}"
    WAL_ACTIVE="$HOME/.cache/wal/.active"

    if [ ! -d "$WALLPAPER_DIR" ]; then
      echo "Wallpaper directory not found: $WALLPAPER_DIR"
      exit 1
    fi

    echo "Setting random wallpaper from $WALLPAPER_DIR"

    # Generate colors from random wallpaper (suppress ImageMagick v7 deprecation warnings)
    ${pkgs.pywal}/bin/wal -q -i "$WALLPAPER_DIR" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true

    # Mark wal colors as active
    mkdir -p "$(dirname "$WAL_ACTIVE")"
    touch "$WAL_ACTIVE"

    # RGB Control (ASUS / OpenRGB) - suppress verbose output
    HEX_CODE=$(sed -n '2p' ~/.cache/wal/colors | sed 's/#//')

    if command -v asusctl >/dev/null 2>&1 && asusctl -v >/dev/null 2>&1; then
      echo "Setting ASUS Aura..."
      RUST_LOG=error asusctl aura static -c "$HEX_CODE" 2>/dev/null || true
      RUST_LOG=error asusctl -k high 2>/dev/null || true
    elif command -v openrgb >/dev/null 2>&1; then
      if openrgb --list-devices 2>/dev/null | grep -q "Device"; then
        echo "Setting OpenRGB..."
        openrgb --device 0 --mode static --color "$HEX_CODE" 2>/dev/null || true
      fi
    fi

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps (polybar, i3, zathura, firefox, dunst, etc)
    ${refreshColorsScript}/bin/refresh-colors

    # Pre-generate lockscreen background in background (instant lock on next use)
    # pywal saves the selected wallpaper path in ~/.cache/wal/wal
    SELECTED_WALLPAPER=$(cat "$HOME/.cache/wal/wal" 2>/dev/null)
    if [ -n "$SELECTED_WALLPAPER" ] && [ -f "$SELECTED_WALLPAPER" ]; then
      ${generateLockscreenScript}/bin/generate-lockscreen "$SELECTED_WALLPAPER" &
    fi

    # Push colors to running VMs via vsock (instant sync)
    if command -v push-colors-to-vms >/dev/null 2>&1; then
      echo "Pushing colors to VMs..."
      push-colors-to-vms &
    fi

    echo "Done! (use restore-colorscheme to revert)"
  '';

  # Initialize wal cache from configured colorscheme
  # This ensures ~/.cache/wal/colors.json exists for pywalfox and other tools
  initWalCacheScript = pkgs.writeShellScriptBin "init-wal-cache" ''
    set -euo pipefail
    # Colorschemes packaged in Nix store (always available)
    NIX_COLORSCHEMES="${colorschemesPackage}/colorschemes"
    WAL_CACHE="$HOME/.cache/wal"
    SCHEME_MARKER="$WAL_CACHE/.colorscheme-name"

    # Read the colorscheme name from /etc (populated by Nix at build time)
    if [ ! -f /etc/hydrix-colorscheme ]; then
        echo "No /etc/hydrix-colorscheme found, skipping wal cache init"
        exit 0
    fi

    SCHEME_NAME=$(cat /etc/hydrix-colorscheme)
    SCHEME_JSON="$NIX_COLORSCHEMES/$SCHEME_NAME.json"

    # Check if colorscheme changed since last cache (forces regeneration on rebuild)
    FORCE_REGEN=false
    if [ -f "$SCHEME_MARKER" ]; then
        CACHED_SCHEME=$(cat "$SCHEME_MARKER")
        if [ "$CACHED_SCHEME" != "$SCHEME_NAME" ]; then
            echo "Colorscheme changed: $CACHED_SCHEME -> $SCHEME_NAME (forcing regeneration)"
            FORCE_REGEN=true
            rm -rf "$WAL_CACHE"
        fi
    fi

    # Note: wal-sync removed from init-wal-cache — the push model (vsock port 14503)
    # handles live color updates. wal-sync would overwrite pushed colors with stale
    # 9p data. init-wal-cache just generates initial wal cache from VM's colorscheme.

    # Skip if wal cache already exists, is recent, and colorscheme hasn't changed
    if [ "$FORCE_REGEN" = "false" ] && [ -f "$WAL_CACHE/colors.json" ]; then
        if [ "$(find "$WAL_CACHE/colors.json" -mtime -1 2>/dev/null)" ]; then
            echo "Wal cache exists and is recent, skipping"
            exit 0
        fi
    fi

    if [ -f "$SCHEME_JSON" ]; then
        echo "Initializing wal cache from colorscheme: $SCHEME_NAME"
        mkdir -p "$WAL_CACHE"

        # Use pywal to generate all cache files from the theme (suppress ImageMagick v7 deprecation warnings)
        ${pkgs.pywal}/bin/wal -q --theme "$SCHEME_JSON" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true

        # Save scheme name for change detection on next boot
        echo "$SCHEME_NAME" > "$SCHEME_MARKER"

        ${lib.optionalString (!isVM) ''
      # Set wallpaper via feh so ~/.fehbg exists for i3 startup
      ${lib.optionalString (cfg.wallpaper != null) ''
        if [ ! -f "$HOME/.fehbg" ]; then
            echo "Setting initial wallpaper: ${cfg.wallpaper}"
            ${pkgs.feh}/bin/feh --bg-fill "${cfg.wallpaper}" 2>/dev/null || true
        fi

        # Pre-generate lockscreen cache so lock/lock-instant show pixelated wallpaper
        if [ ! -f "$HOME/.cache/lockscreen.png" ]; then
            echo "Generating initial lockscreen cache..."
            generate-lockscreen "${cfg.wallpaper}" &
        fi
      ''}

      # Refresh all color-aware apps with the new wal cache
      if command -v refresh-colors >/dev/null 2>&1; then
          echo "Refreshing app colors..."
          refresh-colors 2>/dev/null || true
      fi

      # Push colors to any VMs that are already running
      if command -v push-colors-to-vms >/dev/null 2>&1; then
          echo "Pushing colors to running VMs..."
          push-colors-to-vms &
      fi
    ''}

        # Sync to hydrix-config for VMs to access
        HYDRIX_CONFIG="$HOME/.config/hydrix"
        if [ -d "$HYDRIX_CONFIG" ] || [ ! -e "/mnt/hydrix-config" ]; then
            mkdir -p "$HYDRIX_CONFIG/wal"
            cp "$WAL_CACHE/colors.json" "$HYDRIX_CONFIG/wal/colors.json"
            echo "Synced to hydrix-config"
        fi

        echo "Wal cache initialized"
    else
        echo "Colorscheme not found: $SCHEME_JSON"
        echo "This may be normal for VMs without Hydrix repo access"

        # For VMs: check for baked colorscheme JSON first
        VM_SCHEME_JSON="/etc/hydrix-colorscheme.json"
        if [ -f "$VM_SCHEME_JSON" ]; then
            echo "Initializing wal cache from baked colorscheme: $SCHEME_NAME"
            mkdir -p "$WAL_CACHE"
            ${pkgs.pywal}/bin/wal -q --theme "$VM_SCHEME_JSON" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true
            # Save scheme name for change detection on next boot
            echo "$SCHEME_NAME" > "$SCHEME_MARKER"
            echo "Wal cache initialized from /etc"
        else
            echo "No colorscheme JSON found (scheme: $SCHEME_NAME)"
            echo "Push model will provide host colors at runtime via vsock"
        fi
    fi

    # Ensure colors-runtime.toml exists so alacritty sets up an inotify watch.
    # Don't populate it — text colors come from build-time /etc/hydrix-alacritty-colors.toml.
    # The vsock handler writes only the host background override to this file.
    mkdir -p "$HOME/.config/alacritty"
    touch "$HOME/.config/alacritty/colors-runtime.toml"

    # Generate dunstrc with wal colors (for dunst to read on start)
    if [ -f "$WAL_CACHE/colors.json" ]; then
        if command -v generate-dunstrc >/dev/null 2>&1; then
            echo "Generating dunstrc..."
            generate-dunstrc
        fi
    fi

    # Update xpra X background to match wal colors (for VMs)
    # This hides the resize_increments gap in alacritty windows
    if [ -f "$WAL_CACHE/colors.json" ] && [ -S /tmp/.X11-unix/X100 ]; then
        BG_COLOR=$(${jq} -r '.special.background // .colors.color0 // "#000000"' "$WAL_CACHE/colors.json" 2>/dev/null)
        ${pkgs.xorg.xsetroot}/bin/xsetroot -display :100 -solid "$BG_COLOR" 2>/dev/null || true
    fi
  '';

  # Firefox wrapper that runs pywalfox update after launch
  firefoxPywalScript = pkgs.writeShellScriptBin "firefox-pywal" ''
    #!/usr/bin/env bash
    # Launch Firefox and run pywalfox update once it's ready

    # Start Firefox in background
    ${pkgs.firefox}/bin/firefox "$@" &
    FIREFOX_PID=$!

    # Wait for Firefox to initialize (check if native messaging is ready)
    sleep 3

    # Run pywalfox update if wal cache exists
    if [ -f "$HOME/.cache/wal/colors.json" ]; then
        if command -v pywalfox &>/dev/null; then
            pywalfox update 2>/dev/null || true
        fi
    fi

    # Wait for Firefox to exit
    wait $FIREFOX_PID 2>/dev/null || true
  '';

  # Script to set colorscheme inheritance mode at runtime
  # Modes: full, dynamic, none
  setColorschemeModeScript = pkgs.writeShellScriptBin "set-colorscheme-mode" ''
    #!/usr/bin/env bash
    set -euo pipefail

    MODE_FILE="$HOME/.cache/wal/.colorscheme-mode"
    VALID_MODES="full dynamic none"

    show_help() {
        echo "Usage: set-colorscheme-mode <mode>"
        echo ""
        echo "Modes:"
        echo "  full    - All colors from host, no VM distinction"
        echo "  dynamic - Host background + VM text colors (default)"
        echo "  none    - VM's declared colorscheme only, ignore host"
        echo ""
        echo "Current mode: $(get-colorscheme-mode)"
    }

    if [ -z "''${1:-}" ]; then
        show_help
        exit 0
    fi

    MODE="$1"

    if ! echo "$VALID_MODES" | grep -qw "$MODE"; then
        echo "Error: Invalid mode '$MODE'"
        echo "Valid modes: $VALID_MODES"
        exit 1
    fi

    mkdir -p "$(dirname "$MODE_FILE")"
    echo "$MODE" > "$MODE_FILE"
    echo "Colorscheme inheritance mode set to: $MODE"

    # Clear the sync hash to force re-sync on next poll
    rm -f "$HOME/.cache/wal/.wal-sync-hash"

    # If mode is 'none', restore VM colorscheme immediately
    if [ "$MODE" = "none" ]; then
        echo "Restoring VM colorscheme..."
        restore-colorscheme
    else
        echo "Colors will sync on next poll cycle (within 5 seconds)"
    fi
  '';

  # Script to get current colorscheme inheritance mode
  getColorschemeModeScript = pkgs.writeShellScriptBin "get-colorscheme-mode" ''
    #!/usr/bin/env bash
    MODE_FILE="$HOME/.cache/wal/.colorscheme-mode"
    DEFAULT_MODE="${colorschemeInheritance}"

    if [ -f "$MODE_FILE" ]; then
        cat "$MODE_FILE"
    else
        echo "$DEFAULT_MODE"
    fi
  '';

  # VM-only script to sync wal colors from host based on inheritance mode
  # Modes: full (all host), dynamic (host bg + VM text), none (VM only)
  walSyncScript = pkgs.writeShellScriptBin "wal-sync" ''
    #!/usr/bin/env bash
    set -euo pipefail

    HOST_WAL="/mnt/hydrix-config/wal/colors.json"
    VM_COLORSCHEME_JSON="/etc/hydrix-colorscheme.json"
    WAL_CACHE="$HOME/.cache/wal"
    WAL_COLORS="$WAL_CACHE/colors.json"
    WAL_ACTIVE="$WAL_CACHE/.active"
    LAST_SYNC_HASH="$WAL_CACHE/.wal-sync-hash"
    MODE_FILE="$WAL_CACHE/.colorscheme-mode"
    DEFAULT_MODE="${colorschemeInheritance}"

    # Get current inheritance mode (runtime override or default)
    MODE="$DEFAULT_MODE"
    if [ -f "$MODE_FILE" ]; then
        MODE=$(${pkgs.coreutils}/bin/cat "$MODE_FILE")
    fi

    # Mode 'none' - don't sync from host at all
    if [ "$MODE" = "none" ]; then
        exit 0
    fi

    # Check if host wal colors exist
    if [ ! -f "$HOST_WAL" ]; then
        exit 0
    fi

    # Note: .active marker check removed — push model handles runtime updates.
    # At boot time, host colors on 9p are valid regardless of .active state.

    # Check if host colors have changed since last sync (skip if unchanged)
    HOST_HASH=$(${pkgs.coreutils}/bin/md5sum "$HOST_WAL" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    if [ -f "$LAST_SYNC_HASH" ] && [ "$(${pkgs.coreutils}/bin/cat "$LAST_SYNC_HASH")" = "$HOST_HASH" ]; then
        exit 0
    fi

    echo "Syncing wal colors from host (mode: $MODE)..."
    mkdir -p "$WAL_CACHE"

    if [ "$MODE" = "full" ]; then
        # Full mode: Use all host colors as-is
        echo "Using all colors from host"
        cp "$HOST_WAL" "$WAL_COLORS"

    elif [ "$MODE" = "dynamic" ]; then
        # Dynamic mode: Host background/special + VM text colors (color0-15)
        if [ -f "$VM_COLORSCHEME_JSON" ]; then
            echo "Merging: host background + VM text colors"
            # Start with host colors
            cp "$HOST_WAL" "$WAL_COLORS"
            # Override all text colors (color0-15) with VM's colors
            ${jq} -s '
              .[0] as $host | .[1] as $vm |
              $host | .colors = $vm.colors
            ' "$HOST_WAL" "$VM_COLORSCHEME_JSON" > "$WAL_COLORS.tmp"
            ${pkgs.coreutils}/bin/mv "$WAL_COLORS.tmp" "$WAL_COLORS"
        else
            echo "No VM colorscheme found, using host colors"
            cp "$HOST_WAL" "$WAL_COLORS"
        fi
    fi

    # Mark wal as active in VM
    touch "$WAL_ACTIVE"

    # Generate pywal cache files (Xresources, sequences, etc.) - suppress ImageMagick v7 warnings
    echo "Generating pywal cache files..."
    ${pkgs.pywal}/bin/wal -q --theme "$WAL_COLORS" 2>&1 | grep -v "WARNING: The convert command is deprecated" || true

    # For dynamic mode, re-apply VM colors after pywal regenerates
    # (pywal --theme overwrites colors.json)
    if [ "$MODE" = "dynamic" ] && [ -f "$VM_COLORSCHEME_JSON" ]; then
        ${jq} -s '
          .[0] as $current | .[1] as $vm |
          $current | .colors = $vm.colors
        ' "$WAL_COLORS" "$VM_COLORSCHEME_JSON" > "$WAL_COLORS.tmp"
        ${pkgs.coreutils}/bin/mv "$WAL_COLORS.tmp" "$WAL_COLORS"
    fi

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps
    ${refreshColorsScript}/bin/refresh-colors

    # Update xpra X background to match (hides resize_increments gaps in alacritty)
    if [ -n "''${DISPLAY:-}" ] || [ -S /tmp/.X11-unix/X100 ]; then
        BG_COLOR=$(${jq} -r '.special.background // .colors.color0 // "#000000"' "$WAL_COLORS" 2>/dev/null)
        ${pkgs.xorg.xsetroot}/bin/xsetroot -display :100 -solid "$BG_COLOR" 2>/dev/null || true
    fi

    # Save hash to avoid re-syncing unchanged colors
    echo "$HOST_HASH" > "$LAST_SYNC_HASH"

    echo "VM wal sync complete!"
  '';

  # Pomodoro timer script
  # CLI: pomo start|stop|pause|reset|<none>
  # State file: /tmp/pomodoro_state (STATE START_TIME ALERT)
  # - STATE: WORK, BREAK, PAUSED_WORK, PAUSED_BREAK
  # - START_TIME: Unix timestamp when current phase started (or remaining seconds when paused)
  # - ALERT: 0 (normal) or 1 (timer expired, awaiting acknowledgment)
  pomoScript = pkgs.writeShellScriptBin "pomo" ''
    #!/usr/bin/env bash
    STATE_FILE="/tmp/pomodoro_state"
    WORK_DURATION=1500   # 25 minutes
    BREAK_DURATION=300   # 5 minutes

    get_state() {
      if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
      else
        echo ""
      fi
    }

    write_state() {
      echo "$1 $2 $3" > "$STATE_FILE"
    }

    start_timer() {
      local current=$(get_state)
      if [ -z "$current" ]; then
        # Fresh start - begin WORK phase
        write_state "WORK" "$(date +%s)" "0"
        echo "Pomodoro started: WORK phase (25 min)"
      elif [[ "$current" == PAUSED_* ]]; then
        # Resume from pause
        local state=$(echo "$current" | awk '{print $1}')
        local remaining=$(echo "$current" | awk '{print $2}')
        local alert=$(echo "$current" | awk '{print $3}')
        local original_state="''${state#PAUSED_}"
        # Calculate new start time based on remaining seconds
        local now=$(date +%s)
        if [ "$original_state" = "WORK" ]; then
          local new_start=$((now - (WORK_DURATION - remaining)))
        else
          local new_start=$((now - (BREAK_DURATION - remaining)))
        fi
        write_state "$original_state" "$new_start" "$alert"
        echo "Pomodoro resumed: $original_state phase"
      else
        echo "Pomodoro is already running"
      fi
    }

    pause_timer() {
      local current=$(get_state)
      if [ -z "$current" ]; then
        echo "No timer running"
        return 1
      fi

      local state=$(echo "$current" | awk '{print $1}')
      local start_time=$(echo "$current" | awk '{print $2}')
      local alert=$(echo "$current" | awk '{print $3}')

      if [[ "$state" == PAUSED_* ]]; then
        echo "Timer is already paused"
        return 0
      fi

      local now=$(date +%s)
      local elapsed=$((now - start_time))
      local duration
      if [ "$state" = "WORK" ]; then
        duration=$WORK_DURATION
      else
        duration=$BREAK_DURATION
      fi
      local remaining=$((duration - elapsed))
      if [ "$remaining" -lt 0 ]; then
        remaining=0
      fi

      write_state "PAUSED_$state" "$remaining" "$alert"
      echo "Pomodoro paused: $remaining seconds remaining"
    }

    stop_timer() {
      if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
        echo "Pomodoro stopped"
      else
        echo "No timer running"
      fi
    }

    reset_timer() {
      write_state "WORK" "$(date +%s)" "0"
      echo "Pomodoro reset: WORK phase (25 min)"
    }

    # Advance to next phase (called when timer expires and user acknowledges)
    advance_phase() {
      local current=$(get_state)
      if [ -z "$current" ]; then
        echo "No timer running. Use 'pomo start' to begin."
        return 1
      fi

      local state=$(echo "$current" | awk '{print $1}')
      local alert=$(echo "$current" | awk '{print $3}')

      # Clear paused prefix if present
      state="''${state#PAUSED_}"

      # Only advance if alerting (timer expired) or if explicitly requested
      if [ "$state" = "WORK" ]; then
        write_state "BREAK" "$(date +%s)" "0"
        echo "Starting BREAK phase (5 min)"
      else
        write_state "WORK" "$(date +%s)" "0"
        echo "Starting WORK phase (25 min)"
      fi
    }

    toggle_pause() {
      local current=$(get_state)
      if [ -z "$current" ]; then
        start_timer
        return
      fi

      local state=$(echo "$current" | awk '{print $1}')
      local alert=$(echo "$current" | awk '{print $3}')

      # If alerting, acknowledge and advance
      if [ "$alert" = "1" ]; then
        advance_phase
        return
      fi

      # Otherwise toggle pause
      if [[ "$state" == PAUSED_* ]]; then
        start_timer
      else
        pause_timer
      fi
    }

    case "''${1:-}" in
      start)
        start_timer
        ;;
      stop)
        stop_timer
        ;;
      pause)
        pause_timer
        ;;
      reset)
        reset_timer
        ;;
      "")
        # No argument: acknowledge alert and advance, or toggle pause
        toggle_pause
        ;;
      *)
        echo "Usage: pomo [start|stop|pause|reset]"
        echo "  start  - Start or resume timer"
        echo "  stop   - Stop and clear timer"
        echo "  pause  - Pause current timer"
        echo "  reset  - Reset to WORK phase"
        echo "  (none) - Acknowledge alert / toggle pause"
        exit 1
        ;;
    esac
  '';

  # Lockscreen script using i3lock-color with wal colors
  # Prefers pre-cached background from walrgb; falls back to live screenshot
  lockScript = pkgs.writeShellScriptBin "lock" ''
    # Kill any existing instances
    ${pkgs.killall}/bin/killall -q i3lock

    # Source wal colors for theming
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      # Fallback colors if wal not initialized
      color0="#0c0c0c"
      color1="#bf616a"
      color3="#ebcb8b"
      color6="#8fbcbb"
      color7="#d8dee9"
    fi

    # Move cursor to bottom-right corner (out of the way)
    ${pkgs.xdotool}/bin/xdotool mousemove 9999 9999

    # Configuration (baked at build time from hydrix.graphical.lockscreen options)
    FONT="${cfg.lockscreen.font}"
    CLOCK_SIZE=${toString cfg.lockscreen.clockSize}
    WRONG_TEXT="${cfg.lockscreen.wrongText}"
    VERIFY_TEXT="${cfg.lockscreen.verifyText}"

    # Detect primary monitor position for correct text/element placement on multi-monitor setups
    PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected primary " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    [ -z "$PRIMARY_GEOM" ] && PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    MON_W=1920; MON_H=1200; MON_X=0; MON_Y=0
    if [ -n "$PRIMARY_GEOM" ]; then
      MON_W=$(echo "$PRIMARY_GEOM" | cut -dx -f1)
      MON_H=$(echo "$PRIMARY_GEOM" | cut -dx -f2 | cut -d+ -f1)
      MON_X=$(echo "$PRIMARY_GEOM" | cut -d+ -f2)
      MON_Y=$(echo "$PRIMARY_GEOM" | cut -d+ -f3)
    fi
    # Positions proportional to primary monitor (ratios derived from 1920x1200 originals)
    IND_X=$((MON_X + MON_W * 171 / 1000))
    IND_Y=$((MON_Y + MON_H * 225 / 1000))
    TIME_X=$((MON_X + MON_W * 128 / 1000))
    DATE_X=$((MON_X + MON_W * 115 / 1000))
    DATE_Y=$((MON_Y + MON_H * 158 / 1000))
    VERIF_X=$((MON_X + MON_W * 162 / 1000))
    WRONG_X=$((MON_X + MON_W * 479 / 1000))
    TEXT_X=$((MON_X + 50))
    TEXT_Y=$((MON_Y + 50))

    # Always take a live screenshot, blur it, and apply colors
    LOCK_TEXT="${cfg.lockscreen.text}"
    FONT_SIZE=${toString cfg.lockscreen.fontSize}
    img=/tmp/i3lock_screen.png
    blur_img=/tmp/i3lock_blur.png

    ${pkgs.scrot}/bin/scrot -o "$img" 2>/dev/null || true

    if [ -f "$img" ]; then
      ${
      if cfg.lockscreen.blur
      then ''
        ${pkgs.imagemagick}/bin/magick "$img" -scale 20% -scale 500% "$blur_img" 2>/dev/null || cp "$img" "$blur_img"
      ''
      else ''
        cp "$img" "$blur_img"
      ''
    }

      if ! ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
          -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
          -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" /tmp/i3lock_text.png 2>/dev/null; then
        FONT="CozetteVector"
        ${pkgs.imagemagick}/bin/magick "$blur_img" -gravity NorthWest \
            -pointsize $FONT_SIZE -font "$FONT" -fill "$color1" \
            -annotate +"$TEXT_X"+"$TEXT_Y" "$LOCK_TEXT" /tmp/i3lock_text.png 2>/dev/null || true
      fi

      if [ -f /tmp/i3lock_text.png ]; then
        LOCK_IMG=/tmp/i3lock_text.png
      elif [ -f "$blur_img" ]; then
        LOCK_IMG="$blur_img"
      else
        LOCK_IMG="/tmp/i3lock_solid.png"
        SCREEN_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
        ${pkgs.imagemagick}/bin/magick -size "''${SCREEN_SIZE:-1920x1200}" "xc:$color0" "$LOCK_IMG" 2>/dev/null || true
      fi
    else
      LOCK_IMG="/tmp/i3lock_solid.png"
      SCREEN_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
      ${pkgs.imagemagick}/bin/magick -size "''${SCREEN_SIZE:-1920x1200}" "xc:$color0" "$LOCK_IMG" 2>/dev/null || true
    fi

    # Run i3lock-color with wal colors and custom text
    ${pkgs.i3lock-color}/bin/i3lock \
        -i "$LOCK_IMG" \
        --clock \
        --time-str="%H:%M:%S" \
        --date-str="%A, %Y-%m-%d" \
        --layout-font="$FONT" \
        --layout-size=26 \
        --time-font="$FONT" \
        --date-font="$FONT" \
        --time-size=$CLOCK_SIZE \
        --date-size=1 \
        --time-color="''${color3:1}" \
        --date-color="''${color7:1}" \
        --inside-color="''${color0:1}00" \
        --ring-color="''${color0:1}00" \
        --ringwrong-color="''${color0:1}00" \
        --line-color="''${color0:1}ff" \
        --separator-color="''${color0:1}00" \
        --keyhl-color="''${color3:1}ff" \
        --bshl-color="''${color0:1}ff" \
        --time-pos="$TIME_X:$IND_Y" \
        --date-pos="$DATE_X:$DATE_Y" \
        --indicator \
        --radius=50 \
        --ringver-color="''${color6:1}00" \
        --verif-text="$VERIFY_TEXT" \
        --verif-font="$FONT" \
        --verif-size=91 \
        --verif-color="$color3" \
        --verif-pos="$VERIF_X:$IND_Y" \
        --wrong-text="$WRONG_TEXT" \
        --wrong-pos="$WRONG_X:$IND_Y" \
        --wrong-font="$FONT" \
        --wrong-size=91 \
        --wrong-color="$color3" \
        --noinput-text="Err: no input" \
        --ind-pos="$IND_X:$IND_Y" \
        --bar-indicator \
        --bar-step=5 \
        --bar-max-height=5 \
        --bar-color="''${color0:1}00"

    # Cleanup temporary files (not the cache)
    rm -f /tmp/i3lock_screen.png /tmp/i3lock_blur.png /tmp/i3lock_text.png /tmp/i3lock_solid.png

    # After unlock: wake display (DPMS) to prevent black screen on resume
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true
  '';

  # Instant lockscreen script using pre-cached background from walrgb
  # Used for lid closure/suspend where speed is critical
  # Also triggered by xss-lock on idle timeout - exits early if already locked
  lockInstantScript = pkgs.writeShellScriptBin "lock-instant" ''
    # If i3lock is already running (manual lock), don't restart it
    if ${pkgs.procps}/bin/pgrep -x i3lock >/dev/null 2>&1; then
      exit 0
    fi

    # Source wal colors for theming
    if [ -f "$HOME/.cache/wal/colors.sh" ]; then
      . "$HOME/.cache/wal/colors.sh"
    else
      # Fallback colors if wal not initialized
      color0="#0c0c0c"
      color1="#bf616a"
      color3="#ebcb8b"
      color6="#8fbcbb"
      color7="#d8dee9"
    fi

    # Move cursor to bottom-right corner (out of the way)
    ${pkgs.xdotool}/bin/xdotool mousemove 9999 9999

    # Configuration (baked at build time from hydrix.graphical.lockscreen options)
    FONT="${cfg.lockscreen.font}"
    CLOCK_SIZE=${toString cfg.lockscreen.clockSize}
    WRONG_TEXT="${cfg.lockscreen.wrongText}"
    VERIFY_TEXT="${cfg.lockscreen.verifyText}"

    # Detect primary monitor position for correct element placement on multi-monitor setups
    PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected primary " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    [ -z "$PRIMARY_GEOM" ] && PRIMARY_GEOM=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gnugrep}/bin/grep " connected " | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
    MON_W=1920; MON_H=1200; MON_X=0; MON_Y=0
    if [ -n "$PRIMARY_GEOM" ]; then
      MON_W=$(echo "$PRIMARY_GEOM" | cut -dx -f1)
      MON_H=$(echo "$PRIMARY_GEOM" | cut -dx -f2 | cut -d+ -f1)
      MON_X=$(echo "$PRIMARY_GEOM" | cut -d+ -f2)
      MON_Y=$(echo "$PRIMARY_GEOM" | cut -d+ -f3)
    fi
    # Positions proportional to primary monitor (ratios derived from 1920x1200 originals)
    IND_X=$((MON_X + MON_W * 171 / 1000))
    IND_Y=$((MON_Y + MON_H * 225 / 1000))
    TIME_X=$((MON_X + MON_W * 128 / 1000))
    DATE_X=$((MON_X + MON_W * 115 / 1000))
    DATE_Y=$((MON_Y + MON_H * 158 / 1000))
    VERIF_X=$((MON_X + MON_W * 162 / 1000))
    WRONG_X=$((MON_X + MON_W * 479 / 1000))

    # Use pre-cached lockscreen background (instant) or fall back to solid color
    LOCK_CACHE="$HOME/.cache/lockscreen.png"
    if [ -f "$LOCK_CACHE" ]; then
      LOCK_IMG="$LOCK_CACHE"
    else
      # No cached image - create solid color fallback (instant, no screenshot)
      LOCK_IMG="/tmp/i3lock_solid.png"
      SCREEN_SIZE=$(${pkgs.xorg.xdpyinfo}/bin/xdpyinfo | ${pkgs.gnugrep}/bin/grep -oP 'dimensions:\s+\K[0-9]+x[0-9]+' | head -1)
      ${pkgs.imagemagick}/bin/magick -size "''${SCREEN_SIZE:-1920x1200}" "xc:$color0" "$LOCK_IMG" 2>/dev/null || true
    fi

    # Run i3lock-color with wal colors and custom text
    ${pkgs.i3lock-color}/bin/i3lock \
        -i "$LOCK_IMG" \
        --clock \
        --time-str="%H:%M:%S" \
        --date-str="%A, %Y-%m-%d" \
        --layout-font="$FONT" \
        --layout-size=26 \
        --time-font="$FONT" \
        --date-font="$FONT" \
        --time-size=$CLOCK_SIZE \
        --date-size=1 \
        --time-color="''${color3:1}" \
        --date-color="''${color7:1}" \
        --inside-color="''${color0:1}00" \
        --ring-color="''${color0:1}00" \
        --ringwrong-color="''${color0:1}00" \
        --line-color="''${color0:1}ff" \
        --separator-color="''${color0:1}00" \
        --keyhl-color="''${color3:1}ff" \
        --bshl-color="''${color0:1}ff" \
        --time-pos="$TIME_X:$IND_Y" \
        --date-pos="$DATE_X:$DATE_Y" \
        --indicator \
        --radius=50 \
        --ringver-color="''${color6:1}00" \
        --verif-text="$VERIFY_TEXT" \
        --verif-font="$FONT" \
        --verif-size=91 \
        --verif-color="$color3" \
        --verif-pos="$VERIF_X:$IND_Y" \
        --wrong-text="$WRONG_TEXT" \
        --wrong-pos="$WRONG_X:$IND_Y" \
        --wrong-font="$FONT" \
        --wrong-size=91 \
        --wrong-color="$color3" \
        --noinput-text="Err: no input" \
        --ind-pos="$IND_X:$IND_Y" \
        --bar-indicator \
        --bar-step=5 \
        --bar-max-height=5 \
        --bar-color="''${color0:1}00"

    # Cleanup only fallback image (keep cached image)
    rm -f /tmp/i3lock_solid.png

    # After unlock: wake display (DPMS) to prevent black screen on resume
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true
  '';

  # Display recovery script for emergency situations
  # Used after lid open if display is black
  displayRecoverScript = pkgs.writeShellScriptBin "display-recover" ''
    #!/usr/bin/env bash
    # Emergency display recovery - forces DPMS, xrandr, picom, and i3 reload
    echo "Starting display recovery..."
    echo "[$(date)] Manual display recovery triggered" >> /tmp/suspend-debug.log

    # Save current gamma settings before reinitializing
    GAMMA_SAVE_FILE="/tmp/xrandr-gamma-save"
    > "$GAMMA_SAVE_FILE"
    for monitor in $(${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep " connected" | cut -d' ' -f1); do
      gamma=$(${pkgs.xorg.xrandr}/bin/xrandr --verbose --query 2>/dev/null | ${pkgs.gawk}/bin/awk -v m="$monitor" '
        BEGIN { found=0; gamma="" }
        $1 == m { found=1 }
        found && /Red gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=$3 }
        found && /Green gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3 }
        found && /Blue gamma:/ { gsub(/[^0-9.]/, "", $3); gamma=gamma":"$3; print gamma }
      ')
      if [ -n "$gamma" ]; then
        echo "$monitor=$gamma" >> "$GAMMA_SAVE_FILE"
      fi
    done

    # Force DPMS on
    echo "  Forcing DPMS on..."
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true

    # Wait briefly
    sleep 0.5

    # Reinitialize displays
    echo "  Running xrandr --auto..."
    ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true
    sleep 0.5
    ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true

    # Restore gamma settings after reinitialization
    sleep 0.5
    if [ -f "$GAMMA_SAVE_FILE" ] && [ -s "$GAMMA_SAVE_FILE" ]; then
      while IFS='=' read -r monitor gamma; do
        if [ -n "$monitor" ] && [ -n "$gamma" ]; then
          ${pkgs.xorg.xrandr}/bin/xrandr --output "$monitor" --gamma "$gamma" 2>/dev/null || true
          echo "[$(date)] Restored gamma for $monitor: $gamma" >> /tmp/suspend-debug.log
        fi
      done < "$GAMMA_SAVE_FILE"
    fi

    # Restart picom (compositor)
    echo "  Restarting picom..."
    ${pkgs.procps}/bin/pkill -9 picom 2>/dev/null || true
    sleep 0.3
    ${pkgs.picom}/bin/picom --daemon 2>/dev/null || true

    # Reload i3
    echo "  Reloading i3..."
    ${pkgs.i3}/bin/i3-msg reload 2>/dev/null || true

    # Run display-setup if available (refreshes polybar, gaps)
    # Use --no-move to preserve workspace-to-monitor assignments
    if command -v display-setup >/dev/null 2>&1; then
      echo "  Running display-setup..."
      display-setup --no-move >/dev/null 2>&1 || true
    fi

    echo "Display recovery complete!"
    echo "[$(date)] Manual display recovery completed" >> /tmp/suspend-debug.log
  '';

  # Monitor rescan script - more aggressive than display-recover
  # Use when a monitor doesn't show up after being connected
  monitorRescanScript = pkgs.writeShellScriptBin "monitor-rescan" ''
    #!/usr/bin/env bash
    # Aggressive monitor rescan - for when hotplug doesn't detect a monitor
    LOG="/tmp/monitor-rescan.log"
    echo "=== Monitor Rescan - $(date) ===" | tee "$LOG"

    echo "Current state:" | tee -a "$LOG"
    ${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep -E "connected|disconnected" | tee -a "$LOG"

    echo "" | tee -a "$LOG"
    echo "Checking /sys/class/drm status files..." | tee -a "$LOG"
    for f in /sys/class/drm/card0-*/status; do
      name=$(basename $(dirname "$f"))
      status=$(cat "$f" 2>/dev/null || echo "N/A")
      echo "  $name: $status" | tee -a "$LOG"
    done

    echo "" | tee -a "$LOG"
    echo "Step 1: Force DPMS on" | tee -a "$LOG"
    ${pkgs.xorg.xset}/bin/xset dpms force on 2>/dev/null || true

    echo "Step 2: Probe outputs with xrandr --auto (3x with delays)" | tee -a "$LOG"
    for i in 1 2 3; do
      ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true
      sleep 1
    done

    echo "Step 3: Check for newly detected monitors" | tee -a "$LOG"
    NEW_STATE=$(${pkgs.xorg.xrandr}/bin/xrandr --query 2>/dev/null | grep -E "connected|disconnected")
    echo "$NEW_STATE" | tee -a "$LOG"

    # Count external monitors
    EXT_COUNT=$(echo "$NEW_STATE" | grep " connected" | grep -v "eDP" | wc -l)

    if [ "$EXT_COUNT" -gt 0 ]; then
      echo "" | tee -a "$LOG"
      echo "Found $EXT_COUNT external monitor(s)! Running display-setup..." | tee -a "$LOG"
      display-setup 2>&1 | tee -a "$LOG"
      echo "Monitor rescan complete - external monitor(s) configured" | tee -a "$LOG"
    else
      echo "" | tee -a "$LOG"
      echo "No external monitors detected." | tee -a "$LOG"
      echo "If a monitor is physically connected but not showing:" | tee -a "$LOG"
      echo "  1. Check cable connection (try replugging)" | tee -a "$LOG"
      echo "  2. Try Ctrl+Alt+F2 then Ctrl+Alt+F1 (VT switch)" | tee -a "$LOG"
      echo "  3. Run 'xrandr --listmonitors' to see X's view" | tee -a "$LOG"
    fi
  '';

  # Path to the colorscheme JSON file (user dir first, then framework)
  colorschemeJsonPath = config.hydrix.resolveColorscheme colorscheme;
  colorschemeJsonExists = builtins.pathExists colorschemeJsonPath;

  # Host-only: Push colors to all running VMs via vsock (replaces 9p polling)
  pushColorsToVmsScript = pkgs.writeShellScriptBin "push-colors-to-vms" ''
    #!/usr/bin/env bash
    # Push host background color to all running VMs via vsock port 14503.
    # VMs use this to override only the alacritty background while keeping
    # their own text colors from the build-time colorscheme.

    WAL_COLORS="$HOME/.cache/wal/colors.json"
    PORT=14503
    LOG="/tmp/push-colors.log"

    log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

    if [ ! -f "$WAL_COLORS" ]; then
      log "No wal colors found, skipping push"
      exit 0
    fi

    # Extract just the background hex
    BG_HEX=$(${jq} -r '.special.background // .colors.color0' "$WAL_COLORS")
    if [ -z "$BG_HEX" ] || [ "$BG_HEX" = "null" ]; then
      log "No background color found"
      exit 0
    fi

    VM_REGISTRY="/etc/hydrix/vm-registry.json"
    if [[ ! -f "$VM_REGISTRY" ]]; then
      log "No VM registry found at $VM_REGISTRY, skipping VM color push"
      exit 0
    fi

    while IFS=$'\t' read -r vm cid; do
      [[ -z "$vm" || -z "$cid" ]] && continue
      if systemctl is-active --quiet "microvm@''${vm}.service" 2>/dev/null; then
        result=$(echo "$BG_HEX" | ${pkgs.socat}/bin/socat -t1 - "VSOCK-CONNECT:''${cid}:''${PORT}" 2>/dev/null || echo "FAIL")
        log "$vm (cid=$cid): $result"
      fi
    done < <(${jq} -r 'to_entries[] | [.value.vmName, (.value.cid | tostring)] | @tsv' "$VM_REGISTRY" 2>/dev/null)
  '';
in {
  config = lib.mkIf cfg.enable {
    # Save the current colorscheme name for the restore script
    environment.etc."hydrix-colorscheme".text = "${colorscheme}";

    # Also save the full colorscheme JSON for VMs (they don't have repo access)
    environment.etc."hydrix-colorscheme.json" = lib.mkIf colorschemeJsonExists {
      source = colorschemeJsonPath;
    };

    # Add scripts to system packages
    environment.systemPackages =
      [
        applySchemeScript
        restoreSchemeScript
        nixWalScript
        walRgbScript
        randomWalRgbScript
        refreshColorsScript
        initWalCacheScript
        firefoxPywalScript
        pomoScript
        lockScript
        lockInstantScript
        generateLockscreenScript
        displayRecoverScript
        monitorRescanScript
        writeAlacrittyColorsScript # Generate alacritty colors TOML from wal cache
      ]
      ++ lib.optionals isVM [
        walSyncScript
        setColorschemeModeScript
        getColorschemeModeScript
        pkgs.xorg.xsetroot # For updating xpra background when colors change
      ]
      ++ lib.optionals (!isVM) [
        pushColorsToVmsScript # Push colors to VMs via vsock (instant sync)
        pkgs.socat # For vsock communication with VMs
      ];

    # Systemd user service to initialize wal cache on login
    # This ensures pywalfox has colors to read before Firefox is launched
    home-manager.users.${username} = {...}: {
      systemd.user.services.init-wal-cache = {
        Unit =
          {
            Description = "Initialize pywal cache from colorscheme";
          }
          // lib.optionalAttrs (!isVM) {
            # Host: wait for graphical session
            After = ["graphical-session-pre.target"];
            PartOf = ["graphical-session.target"];
          };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${initWalCacheScript}/bin/init-wal-cache";
          Environment = [
            "HOME=/home/${username}"
          ];
        };
        Install = {
          # VMs: run on default.target (graphical-session never activates in microVMs)
          # Host: run on graphical-session.target as before
          WantedBy =
            if isVM
            then ["default.target"]
            else ["graphical-session.target"];
        };
      };

      # VM color inheritance is handled entirely by:
      # 1. Build-time: /etc/hydrix-alacritty-colors.toml (full VM colorscheme)
      # 2. Runtime: vm-colorscheme vsock service writes colors-runtime.toml (bg override)
      # No user-side services needed — the system service writes the TOML directly.

      # Host-only: Post-resume display recovery (waits for i3lock to exit)
      # Runs display-setup after user unlocks to fix polybar/gaps
      systemd.user.services.post-resume-display = lib.mkIf (!isVM) {
        Unit = {
          Description = "Recover display after resume and unlock";
        };
        Service = {
          Type = "oneshot";
          ExecStart = let
            script = pkgs.writeShellScript "post-resume-unlock" ''
              LOG="/tmp/suspend-debug.log"
              echo "[$(date)] User post-resume: waiting for unlock" >> "$LOG"

              # Wait for i3lock to exit (max 5 minutes)
              TIMEOUT=300
              COUNT=0
              while ${pkgs.procps}/bin/pgrep -x i3lock >/dev/null 2>&1; do
                sleep 1
                COUNT=$((COUNT + 1))
                if [ "$COUNT" -ge "$TIMEOUT" ]; then
                  echo "[$(date)] User post-resume: timeout waiting for unlock" >> "$LOG"
                  exit 0
                fi
              done

              echo "[$(date)] User post-resume: i3lock exited, running display-setup" >> "$LOG"

              # Run display-setup to fix polybar/gaps
              if command -v display-setup >/dev/null 2>&1; then
                display-setup >/dev/null 2>&1 || true
              fi

              echo "[$(date)] User post-resume: complete" >> "$LOG"
            '';
          in "${script}";
          Environment = [
            "HOME=/home/${username}"
            "DISPLAY=:0"
          ];
        };
      };

      # Timer to trigger post-resume service when resume is detected
      # Uses /sys/power/wakeup_count changing as trigger indicator
      systemd.user.paths.post-resume-trigger = lib.mkIf (!isVM) {
        Unit = {
          Description = "Watch for resume events";
        };
        Path = {
          PathChanged = "/tmp/resume-trigger";
          Unit = "post-resume-display.service";
        };
        Install = {
          WantedBy = ["graphical-session.target"];
        };
      };
    };
  };
}
