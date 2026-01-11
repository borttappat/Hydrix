{ config, lib, pkgs, ... }:

let
  # Username is computed by hydrix-options.nix (single source of truth)
  username = config.hydrix.username;
in
{
  # Static color theming for VMs and hosts
  #
  # Two modes:
  # 1. VM Type mode: Auto-generates colors based on vmType (pentest=red, etc.)
  # 2. Custom scheme mode: Uses a saved colorscheme from colorschemes/*.json
  #
  # To save a scheme from your host:
  #   wal -i /path/to/wallpaper.jpg
  #   ./scripts/save-colorscheme.sh my-theme
  #
  # Then in your VM/host profile:
  #   hydrix.colorscheme = "my-theme";

  imports = [ ./base.nix ];

  # Note: hydrix.vmType and hydrix.colorscheme options are defined in hydrix-options.nix

  config = let
    # Check if custom scheme exists
    schemeFile = if config.hydrix.colorscheme != null
      then ../../colorschemes/${config.hydrix.colorscheme}.json
      else null;

    hasCustomScheme = config.hydrix.colorscheme != null && builtins.pathExists schemeFile;

    # Determine default colorscheme name (for restore script)
    defaultSchemeName = if config.hydrix.colorscheme != null
      then config.hydrix.colorscheme
      else if config.hydrix.vmType != null
      then config.hydrix.vmType
      else "host";

    # Parse colorscheme JSON for TTY colors
    schemeData = if hasCustomScheme
      then builtins.fromJSON (builtins.readFile schemeFile)
      else null;

    # Extract 16 colors from scheme, strip # prefix for console.colors
    # Falls back to a neutral gray palette if no scheme
    stripHash = color: builtins.substring 1 6 color;

    ttyColors = if schemeData != null then [
      (stripHash schemeData.colors.color0)
      (stripHash schemeData.colors.color1)
      (stripHash schemeData.colors.color2)
      (stripHash schemeData.colors.color3)
      (stripHash schemeData.colors.color4)
      (stripHash schemeData.colors.color5)
      (stripHash schemeData.colors.color6)
      (stripHash schemeData.colors.color7)
      (stripHash schemeData.colors.color8)
      (stripHash schemeData.colors.color9)
      (stripHash schemeData.colors.color10)
      (stripHash schemeData.colors.color11)
      (stripHash schemeData.colors.color12)
      (stripHash schemeData.colors.color13)
      (stripHash schemeData.colors.color14)
      (stripHash schemeData.colors.color15)
    ] else [
      # Default neutral palette (fallback for vmType-based colors)
      "0d0d0d" "585858" "676767" "787878"
      "878787" "989898" "A7A7A7" "d2d2d2"
      "939393" "585858" "676767" "787878"
      "878787" "989898" "A7A7A7" "d2d2d2"
    ];

    # Restore script - reads default from /etc and re-applies
    restoreSchemeScript = pkgs.writeShellScriptBin "restore-colorscheme" ''
      set -euo pipefail

      HYDRIX_PATH="''${HYDRIX_PATH:-$HOME/Hydrix}"

      # Read default colorscheme from /etc
      if [ ! -f /etc/hydrix-colorscheme ]; then
        echo "Error: /etc/hydrix-colorscheme not found"
        echo "This system may not have a default colorscheme configured."
        exit 1
      fi

      SCHEME_TYPE=$(cat /etc/hydrix-colorscheme)
      echo "Default colorscheme: $SCHEME_TYPE"

      # Check if it's a named colorscheme (JSON file exists)
      SCHEME_JSON="$HYDRIX_PATH/colorschemes/$SCHEME_TYPE.json"

      if [ -f "$SCHEME_JSON" ]; then
        echo "Restoring colorscheme from: $SCHEME_JSON"
        apply-colorscheme "$SCHEME_JSON"
      else
        # Fall back to vmType-based colors
        echo "Generating colors for type: $SCHEME_TYPE"
        vm-static-colors "$SCHEME_TYPE"
      fi

      # Restore pywal colors to all terminals
      echo "Restoring terminal colors..."
      ${pkgs.pywal}/bin/wal -R

      # Merge Xresources for polybar and terminal cursor colors
      if [ -f ~/.cache/wal/colors.Xresources ]; then
        echo "Merging Xresources..."
        ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.cache/wal/colors.Xresources
      fi

      # Restart polybar to pick up new colors from xrdb
      echo "Restarting polybar..."
      ${pkgs.polybar}/bin/polybar-msg cmd restart 2>/dev/null || true

      # Regenerate and restart dunst with new colors
      echo "Updating dunst..."
      TEMPLATE_BASE="$HYDRIX_PATH/configs"
      if [ -f "$HYDRIX_PATH/scripts/load-display-config.sh" ]; then
        source "$HYDRIX_PATH/scripts/load-display-config.sh"

        # Extract dunst colors from pywal cache
        DUNST_BG=$(${pkgs.jq}/bin/jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
        DUNST_FG=$(${pkgs.jq}/bin/jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
        DUNST_BG_CRITICAL=$(${pkgs.jq}/bin/jq -r '.colors.color1' ~/.cache/wal/colors.json)
        DUNST_FRAME_LOW=$(${pkgs.jq}/bin/jq -r '.colors.color2' ~/.cache/wal/colors.json)
        DUNST_FRAME_NORMAL=$(${pkgs.jq}/bin/jq -r '.colors.color4' ~/.cache/wal/colors.json)
        DUNST_FRAME_CRITICAL=$(${pkgs.jq}/bin/jq -r '.colors.color1' ~/.cache/wal/colors.json)

        ${pkgs.gnused}/bin/sed -e "s/\''${DUNST_FONT}/$DUNST_FONT/g" \
            -e "s/\''${DUNST_FONT_SIZE}/$DUNST_FONT_SIZE/g" \
            -e "s/\''${DUNST_WIDTH}/$DUNST_WIDTH/g" \
            -e "s/\''${DUNST_HEIGHT}/$DUNST_HEIGHT/g" \
            -e "s/\''${DUNST_OFFSET_X}/$DUNST_OFFSET_X/g" \
            -e "s/\''${DUNST_OFFSET_Y}/$DUNST_OFFSET_Y/g" \
            -e "s/\''${DUNST_PADDING}/$DUNST_PADDING/g" \
            -e "s/\''${DUNST_FRAME_WIDTH}/$DUNST_FRAME_WIDTH/g" \
            -e "s/\''${DUNST_ICON_SIZE}/$DUNST_ICON_SIZE/g" \
            -e "s/\''${DUNST_BG}/$DUNST_BG/g" \
            -e "s/\''${DUNST_FG}/$DUNST_FG/g" \
            -e "s/\''${DUNST_BG_CRITICAL}/$DUNST_BG_CRITICAL/g" \
            -e "s/\''${DUNST_FRAME_LOW}/$DUNST_FRAME_LOW/g" \
            -e "s/\''${DUNST_FRAME_NORMAL}/$DUNST_FRAME_NORMAL/g" \
            -e "s/\''${DUNST_FRAME_CRITICAL}/$DUNST_FRAME_CRITICAL/g" \
            "$TEMPLATE_BASE/dunst/dunstrc.template" > ~/.config/dunst/dunstrc

        pkill dunst 2>/dev/null || true
        ${pkgs.dunst}/bin/dunst &
      fi

      echo "Colorscheme '$SCHEME_TYPE' restored and applied to all apps."
    '';

    # Script to apply custom colorscheme from JSON
    applySchemeScript = pkgs.writeShellScriptBin "apply-colorscheme" ''
      set -euo pipefail

      SCHEME_JSON="$1"

      if [ ! -f "$SCHEME_JSON" ]; then
        echo "Error: Scheme file not found: $SCHEME_JSON"
        exit 1
      fi

      echo "Applying colorscheme from: $SCHEME_JSON"

      mkdir -p ~/.cache/wal

      # Remove existing file if read-only (Nix store files are read-only)
      rm -f ~/.cache/wal/colors.json 2>/dev/null || true

      # Copy the JSON directly
      cp "$SCHEME_JSON" ~/.cache/wal/colors.json

      # Extract colors and generate the simple colors file
      ${pkgs.jq}/bin/jq -r '.colors | to_entries | sort_by(.key | ltrimstr("color") | tonumber) | .[].value' "$SCHEME_JSON" > ~/.cache/wal/colors

      # Generate colors.css
      ${pkgs.jq}/bin/jq -r '
        "/* Pywal colors - Custom theme */\n\n:root {\n" +
        "    --background: \(.special.background);\n" +
        "    --foreground: \(.special.foreground);\n" +
        "    --cursor: \(.special.cursor);\n" +
        (.colors | to_entries | map("    --\(.key): \(.value);") | join("\n")) +
        "\n}"
      ' "$SCHEME_JSON" > ~/.cache/wal/colors.css

      # Generate sequences for terminal using printf for real escape chars
      BG=$(${pkgs.jq}/bin/jq -r '.special.background' "$SCHEME_JSON")
      FG=$(${pkgs.jq}/bin/jq -r '.special.foreground' "$SCHEME_JSON")
      CURSOR=$(${pkgs.jq}/bin/jq -r '.special.cursor' "$SCHEME_JSON")

      # Build escape sequences file with actual escape characters
      # Use BEL (\007) as string terminator for wider terminal compatibility
      {
        for i in {0..15}; do
          COLOR=$(${pkgs.jq}/bin/jq -r ".colors.color$i" "$SCHEME_JSON")
          printf '\033]4;%d;%s\007' "$i" "$COLOR"
        done
        printf '\033]10;%s\007' "$FG"      # Foreground
        printf '\033]11;%s\007' "$BG"      # Background
        printf '\033]12;%s\007' "$CURSOR"  # Cursor color
        printf '\033]708;%s\007' "$BG"     # Border
      } > ~/.cache/wal/sequences

      # Generate Xresources for terminal cursor colors (reuses BG/FG/CURSOR from above)
      cat > ~/.cache/wal/colors.Xresources << XEOF
! X colors.
! Generated by apply-colorscheme
*foreground:        $FG
*background:        $BG
*.foreground:       $FG
*.background:       $BG
URxvt*foreground:   $FG
XTerm*foreground:   $FG
UXTerm*foreground:  $FG
URxvt*background:   [100]$BG
XTerm*background:   $BG
UXTerm*background:  $BG
URxvt*cursorColor:  $CURSOR
XTerm*cursorColor:  $CURSOR
UXTerm*cursorColor: $CURSOR
URxvt*borderColor:  [100]$BG
XEOF

      # Append all 16 colors
      for i in {0..15}; do
        COLOR=$(${pkgs.jq}/bin/jq -r ".colors.color$i" "$SCHEME_JSON")
        echo "*.color$i: $COLOR" >> ~/.cache/wal/colors.Xresources
        echo "*color$i:  $COLOR" >> ~/.cache/wal/colors.Xresources
      done

      # Mark as generated
      touch ~/.cache/wal/.static-colors-generated
      echo "CUSTOM_SCHEME=$SCHEME_JSON" > ~/.cache/wal/.static-colors-type

      echo "Colorscheme applied successfully"
    '';

    # Fallback script for vmType-based colors
    vmTypeColorsScript = pkgs.writeShellScriptBin "vm-static-colors"
      (builtins.readFile ../../scripts/vm-static-colors.sh);

  in {
    # Store the default colorscheme name for restore-colorscheme script
    environment.etc."hydrix-colorscheme".text = defaultSchemeName;

    # Apply colorscheme to TTY/console (Linux virtual terminals)
    console.colors = ttyColors;

    environment.systemPackages = [
      applySchemeScript
      vmTypeColorsScript
      restoreSchemeScript

      # Actual walrgb/randomwalrgb scripts for VMs (adapted to use saved colorschemes)
      (pkgs.writeScriptBin "walrgb" (builtins.readFile ../../scripts/walrgb.sh))
      (pkgs.writeScriptBin "randomwalrgb" (builtins.readFile ../../scripts/randomwalrgb.sh))
      (pkgs.writeScriptBin "wal-gtk" (builtins.readFile ../../scripts/wal-gtk.sh))
      (pkgs.writeScriptBin "zathuracolors" (builtins.readFile ../../scripts/zathuracolors.sh))
    ];

    # Apply configured colorscheme on every boot/rebuild
    # Always runs to enforce the colorscheme defined in machine config
    systemd.services.hydrix-colorscheme = {
      description = "Apply configured Hydrix colorscheme";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Restart on every rebuild to enforce configured colorscheme
      restartIfChanged = true;
      # Force restart based on colorscheme config
      restartTriggers = [ defaultSchemeName ] ++ (if hasCustomScheme then [ "${schemeFile}" ] else []);

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
        Group = "users";
        # Ensure proper home directory access
        StateDirectory = "";
        CacheDirectory = "";
      };

      # Ensure the cache directory exists with correct permissions before running
      # preStart runs as root, then script runs as User
      # Remove any existing symlink (from old dotfiles setups) before creating directory
      preStart = ''
        if [ -L /home/${username}/.cache/wal ]; then
          ${pkgs.coreutils}/bin/rm /home/${username}/.cache/wal
        fi
        ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.cache/wal
        ${pkgs.coreutils}/bin/chown -R ${username}:users /home/${username}/.cache/wal
      '';

      script = if hasCustomScheme then ''
        echo "Applying configured colorscheme: ${config.hydrix.colorscheme}"
        ${applySchemeScript}/bin/apply-colorscheme ${schemeFile}
      '' else ''
        echo "Generating ${if config.hydrix.vmType != null then config.hydrix.vmType else "host"} color scheme"
        ${vmTypeColorsScript}/bin/vm-static-colors ${if config.hydrix.vmType != null then config.hydrix.vmType else "host"}
      '';
    };
  };
}
