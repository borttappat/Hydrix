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
#   wifi-sync                       Sync WiFi credentials from router VM
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
    src = ../colorschemes;
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

        # === Polybar color cache (avoids xrdb-query per script invocation) ===
        echo "  Writing polybar color cache..."
        printf 'color0="%s"\ncolor1="%s"\ncolor2="%s"\ncolor3="%s"\ncolor4="%s"\ncolor5="%s"\ncolor6="%s"\ncolor7="%s"\ncolor8="%s"\nwal_bg="%s"\nwal_fg="%s"\n' \
          "$COLOR0" "$COLOR1" "$COLOR2" "$COLOR3" "$COLOR4" \
          "$COLOR5" "$COLOR6" "$COLOR7" "$COLOR8" "$BG" "$FG" \
          > /tmp/hydrix-colors.sh

        # === Xresources (rofi, i3, urxvt, etc) ===
        echo "  Updating Xresources..."
        if [ -f "$WAL_XRES" ]; then
            ${xrdb} -merge "$WAL_XRES"
        fi
        # Override i3wm.color4 specifically for focused borders
        ${xrdb} -merge <<< "i3wm.color4: $COLOR4"

        # === Window manager reload ===
        if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
          # Hyprland: write colors.conf, reload compositor, re-apply VM borders
          echo "  Applying hyprland colors..."
          if command -v hypr-apply-colors >/dev/null 2>&1; then
            hypr-apply-colors
          fi
        elif [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
          # Sway: regenerate colors.conf include and reload
          echo "  Applying sway colors..."
          if command -v sway-apply-colors >/dev/null 2>&1; then
            sway-apply-colors
          fi
        else
          # i3: reload via IPC
          echo "  Reloading i3..."
          ${i3msg} reload >/dev/null 2>&1 || true
          # Signal vm-focus-daemon to re-apply border colors
          ${pkgs.procps}/bin/pkill -USR1 -f vm-focus-daemon 2>/dev/null || true
        fi

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

        # === GTK wal colors ===
        echo "  Generating GTK wal colors..."
        if command -v generate-gtk-colors >/dev/null 2>&1; then
            generate-gtk-colors
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
      "[colors.cursor]\n" +
      "cursor = \"" + (.special.cursor // .special.foreground // .colors.color7) + "\"\n" +
      "text = \"CellBackground\"\n\n" +
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

    # Mark wallpaper as user-set (prevents init-wal-cache from overwriting on rebuilds)
    WALLPAPER_INIT_MARKER="$HOME/.cache/hydrix/wallpaper-initialized"
    mkdir -p "$(dirname "$WALLPAPER_INIT_MARKER")"
    touch "$WALLPAPER_INIT_MARKER"

    # RGB Control (ASUS / OpenRGB) - suppress verbose output
    HEX_CODE=$(sed -n '2p' ~/.cache/wal/colors | sed 's/#//')

    if command -v asusctl >/dev/null 2>&1 && asusctl -v >/dev/null 2>&1; then
      echo "ASUS hardware detected, checking for AURA support..."
      # Check if AURA interface is available (asusctl -s outputs "No aura interface found" if not supported)
      if ! asusctl -s 2>&1 | grep -v '^\[INFO' | grep -q "No aura interface found"; then
        echo "AURA lighting supported, setting RGB color..."
        asusctl aura static -c "$HEX_CODE" >/dev/null 2>&1
        asusctl -k >/dev/null 2>&1
        echo "ASUS backlight set"
      else
        echo "AURA lighting not supported on this device, skipping RGB"
      fi
    elif command -v openrgb >/dev/null 2>&1; then
      if openrgb --list-devices 2>/dev/null | grep -q "Device"; then
        echo "Setting OpenRGB..."
        openrgb --device 0 --mode static --color "$HEX_CODE" 2>/dev/null || true
      fi
    fi

    # Set wallpaper: feh on X11 (wal handles it), swaybg on Wayland
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
      pkill swaybg 2>/dev/null || true
      ${pkgs.swaybg}/bin/swaybg -i "$FILE_PATH" -m fill &
      # Reload Hyprland if running (applies colorscheme to decorations)
      if ${pkgs.procps}/bin/pgrep -x hyprland >/dev/null 2>&1; then
        ${pkgs.hyprland}/bin/hyprctl reload 2>/dev/null || true
      fi
    fi

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps (polybar, i3, zathura, firefox, dunst, etc)
    ${refreshColorsScript}/bin/refresh-colors

    # Pre-generate lockscreen background in background (instant lock on next use)
    if command -v generate-lockscreen >/dev/null 2>&1; then
      generate-lockscreen "$FILE_PATH" &
    fi

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

    # Mark wallpaper as user-set (prevents init-wal-cache from overwriting on rebuilds)
    WALLPAPER_INIT_MARKER="$HOME/.cache/hydrix/wallpaper-initialized"
    mkdir -p "$(dirname "$WALLPAPER_INIT_MARKER")"
    touch "$WALLPAPER_INIT_MARKER"

    # RGB Control (ASUS / OpenRGB) - suppress verbose output
    HEX_CODE=$(sed -n '2p' ~/.cache/wal/colors | sed 's/#//')

    if command -v asusctl >/dev/null 2>&1 && asusctl -v >/dev/null 2>&1; then
      echo "ASUS hardware detected, checking for AURA support..."
      # Check if AURA interface is available (asusctl -s outputs "No aura interface found" if not supported)
      if ! asusctl -s 2>&1 | grep -v '^\[INFO' | grep -q "No aura interface found"; then
        echo "AURA lighting supported, setting RGB color..."
        asusctl aura static -c "$HEX_CODE" >/dev/null 2>&1
        asusctl -k >/dev/null 2>&1
        echo "ASUS backlight set"
      else
        echo "AURA lighting not supported on this device, skipping RGB"
      fi
    elif command -v openrgb >/dev/null 2>&1; then
      if openrgb --list-devices 2>/dev/null | grep -q "Device"; then
        echo "Setting OpenRGB..."
        openrgb --device 0 --mode static --color "$HEX_CODE" 2>/dev/null || true
      fi
    fi

    # Set wallpaper: feh on X11 (wal handles it), swaybg on Wayland
    # pywal saves the selected wallpaper path in ~/.cache/wal/wal
    SELECTED_WALLPAPER=$(cat "$HOME/.cache/wal/wal" 2>/dev/null)
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && [ -n "$SELECTED_WALLPAPER" ] && [ -f "$SELECTED_WALLPAPER" ]; then
      pkill swaybg 2>/dev/null || true
      ${pkgs.swaybg}/bin/swaybg -i "$SELECTED_WALLPAPER" -m fill &
      # Reload Hyprland if running (applies colorscheme to decorations)
      if ${pkgs.procps}/bin/pgrep -x hyprland >/dev/null 2>&1; then
        ${pkgs.hyprland}/bin/hyprctl reload 2>/dev/null || true
      fi
    fi

    # Run nixwal to update nix-specific cache
    ${nixWalScript}/bin/nixwal

    # Refresh all color-aware apps (polybar, i3, zathura, firefox, dunst, etc)
    ${refreshColorsScript}/bin/refresh-colors

    # Pre-generate lockscreen background in background (instant lock on next use)
    if [ -n "$SELECTED_WALLPAPER" ] && [ -f "$SELECTED_WALLPAPER" ]; then
      if command -v generate-lockscreen >/dev/null 2>&1; then
        generate-lockscreen "$SELECTED_WALLPAPER" &
      fi
    fi

    # Push colors to running VMs via vsock (instant sync)
    if command -v push-colors-to-vms >/dev/null 2>&1; then
      echo "Pushing colors to VMs..."
      push-colors-to-vms &
    fi

    echo "Done! (use restore-colorscheme to revert)"
  '';

  # Wallpaper-only scripts (no colorscheme regeneration)
  # Wayland: swaybg, X11: feh
  wallpaperScript = pkgs.writeShellScriptBin "wallpaper" ''
    #!/usr/bin/env bash
    if [ -z "$1" ]; then
      echo "Usage: wallpaper /path/to/image.jpg"
      exit 1
    fi

    if [ ! -f "$1" ]; then
      echo "File not found: $1"
      exit 1
    fi

    if [[ -n "$${WAYLAND_DISPLAY:-}" ]]; then
      pkill swaybg 2>/dev/null || true
      swaybg -i "$1" -m fill &
      echo "Wallpaper set (Wayland)"
    else
      feh --bg-fill "$1"
      echo "Wallpaper set (X11)"
    fi
  '';

  wallpaperBlackScript = pkgs.writeShellScriptBin "wallpaper-black" ''
    #!/usr/bin/env bash
    if [[ -n "$${WAYLAND_DISPLAY:-}" ]]; then
      pkill swaybg 2>/dev/null || true
      swaybg -i ~/wallpapers/Black.jpg -m fill &
    else
      feh --bg-fill ~/wallpapers/Black.jpg
    fi
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

    # Skip wal cache regeneration if it's recent and the colorscheme hasn't changed.
    # Still run per-app generators: their output files (gtk-wal.css, zathurarc-wal,
    # dunstrc, etc.) live outside the wal cache and must exist after every rebuild.
    if [ "$FORCE_REGEN" = "false" ] && [ -f "$WAL_CACHE/colors.json" ]; then
        if [ "$(find "$WAL_CACHE/colors.json" -mtime -1 2>/dev/null)" ]; then
            echo "Wal cache exists and is recent, generating per-app color files..."
            if command -v generate-gtk-colors >/dev/null 2>&1; then generate-gtk-colors; fi
            if command -v generate-dunstrc >/dev/null 2>&1; then generate-dunstrc; fi
            if command -v write-alacritty-colors >/dev/null 2>&1; then write-alacritty-colors; fi
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
      # One-shot: only runs on fresh installs before user sets their own wallpaper
      ${lib.optionalString (cfg.wallpaper != null) ''
        WALLPAPER_INIT_MARKER="$HOME/.cache/hydrix/wallpaper-initialized"
        if [ ! -f "$WALLPAPER_INIT_MARKER" ]; then
            echo "Setting initial wallpaper: ${cfg.wallpaper}"
            ${pkgs.feh}/bin/feh --bg-fill "${cfg.wallpaper}" 2>/dev/null || true
            mkdir -p "$(dirname "$WALLPAPER_INIT_MARKER")"
            touch "$WALLPAPER_INIT_MARKER"
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

  # (lockScript/lockInstantScript/displayRecoverScript/monitorRescanScript moved to wm/i3/scripts.nix)

  # Path to the colorscheme JSON file (user dir first, then framework)
  colorschemeJsonPath = config.hydrix.resolveColorscheme colorscheme;
  colorschemeJsonExists = builtins.pathExists colorschemeJsonPath;

  # Host-only: Push colors to all running VMs via vsock (replaces 9p polling)
  wifiSyncScript =
    pkgs.writeShellScriptBin "wifi-sync"
    (builtins.readFile ../../scripts/wifi-sync.sh);

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
        wallpaperScript
        wallpaperBlackScript
        refreshColorsScript
        initWalCacheScript
        firefoxPywalScript
        pomoScript
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
        wifiSyncScript # Sync WiFi credentials from router VM
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

      # VM: watch wal colors and update Firefox via pywalfox in the user session.
      # Runs in proper user context (full env) — the sudo'd vsock handler lacks it.
      systemd.user.paths.pywalfox-update = lib.mkIf isVM {
        Unit.Description = "Watch wal colors for pywalfox";
        Path.PathChanged = "%h/.cache/wal/colors.json";
        Install.WantedBy = [ "default.target" ];
      };

      systemd.user.services.pywalfox-update = lib.mkIf isVM {
        Unit.Description = "Update Firefox colors via pywalfox";
        Service = {
          Type = "oneshot";
          ExecStart = "/run/current-system/sw/bin/pywalfox update";
        };
        Install.WantedBy = [ "pywalfox-update.path" ];
      };

      # (post-resume-display + post-resume-trigger moved to wm/i3/scripts.nix)
    };
  };
}
