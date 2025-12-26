{ config, pkgs, lib, ... }:

let
  # Detect username dynamically for host
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";
  hostConfigPath = "${basePath}/local/host.nix";

  hostConfig = if builtins.pathExists hostConfigPath
    then import hostConfigPath
    else null;

  username = if hostConfig != null && hostConfig ? username
    then hostConfig.username
    else effectiveUser;

  # Script to initialize default colors if none exist
  initColorsScript = pkgs.writeShellScriptBin "init-host-colors" ''
    set -euo pipefail

    USER_HOME="/home/${username}"
    WAL_CACHE="$USER_HOME/.cache/wal"

    # Only run if colors don't exist
    if [ -f "$WAL_CACHE/colors" ]; then
      echo "Pywal colors already exist, skipping initialization"
      exit 0
    fi

    echo "Initializing default pywal colors for host..."
    mkdir -p "$WAL_CACHE"

    # Check for existing wallpaper in common locations
    WALLPAPER=""
    for wp in "$USER_HOME/Wallpapers"/*.{jpg,png,jpeg} "$USER_HOME/.config/wallpaper".*; do
      if [ -f "$wp" ]; then
        WALLPAPER="$wp"
        break
      fi
    done

    if [ -n "$WALLPAPER" ] && [ -f "$WALLPAPER" ]; then
      echo "Found wallpaper: $WALLPAPER"
      ${pkgs.pywal}/bin/wal -i "$WALLPAPER" -n -q
    else
      # Generate default dark theme colors
      echo "No wallpaper found, generating default dark theme"
      cat > "$WAL_CACHE/colors" << 'COLORS'
#0d0d0d
#585858
#676767
#787878
#878787
#989898
#A7A7A7
#d2d2d2
#939393
#585858
#676767
#787878
#878787
#989898
#A7A7A7
#d2d2d2
COLORS

      cat > "$WAL_CACHE/colors.json" << 'JSON'
{
  "special": {
    "background": "#0d0d0d",
    "foreground": "#d2d2d2",
    "cursor": "#d2d2d2"
  },
  "colors": {
    "color0": "#0d0d0d",
    "color1": "#585858",
    "color2": "#676767",
    "color3": "#787878",
    "color4": "#878787",
    "color5": "#989898",
    "color6": "#A7A7A7",
    "color7": "#d2d2d2",
    "color8": "#939393",
    "color9": "#585858",
    "color10": "#676767",
    "color11": "#787878",
    "color12": "#878787",
    "color13": "#989898",
    "color14": "#A7A7A7",
    "color15": "#d2d2d2"
  }
}
JSON

      # Generate terminal sequences
      BG="#0d0d0d"
      FG="#d2d2d2"
      SEQ=""
      while IFS= read -r COLOR; do
        SEQ="$SEQ\e]4;$i;$COLOR\e\\"
        i=$((i + 1))
      done < "$WAL_CACHE/colors"
      SEQ="$SEQ\e]10;$FG\e\\\e]11;$BG\e\\\e]12;$FG\e\\\e]708;$BG\e\\"
      printf '%s' "$SEQ" > "$WAL_CACHE/sequences"
    fi

    chown -R ${username}:users "$WAL_CACHE"
    echo "Host colors initialized"
  '';
in
{
  # Dynamic color theming for host machines
  #
  # This module provides the full walrgb workflow:
  # - walrgb script for changing colors based on wallpapers
  # - RGB hardware integration (asusctl for ASUS, openrgb for others)
  # - Pywalfox for Firefox color sync
  # - Supporting scripts for GTK, Zathura, etc.
  #
  # Usage: walrgb /path/to/wallpaper.jpg

  imports = [ ./base.nix ];

  config = {
    # Add full walrgb workflow scripts
    environment.systemPackages = with pkgs; [
      # Main theming workflow
      (pkgs.writeScriptBin "walrgb" (builtins.readFile ../../scripts/walrgb.sh))
      (pkgs.writeScriptBin "randomwalrgb" (builtins.readFile ../../scripts/randomwalrgb.sh))

      # Supporting scripts
      (pkgs.writeScriptBin "nixwal" (builtins.readFile ../../scripts/nixwal.sh))
      (pkgs.writeScriptBin "wal-gtk" (builtins.readFile ../../scripts/wal-gtk.sh))
      (pkgs.writeScriptBin "zathuracolors" (builtins.readFile ../../scripts/zathuracolors.sh))
      (pkgs.writeScriptBin "deploy-obsidian-config" (builtins.readFile ../../scripts/deploy-obsidian-config.sh))

      # Color initialization script
      initColorsScript

      # Browser integration
      pywalfox-native

      # RGB hardware control
      asusctl        # For ASUS hardware RGB/keyboard backlight
      openrgb        # For generic RGB devices
    ];

    # Initialize colors on first boot if they don't exist
    systemd.services.init-host-colors = {
      description = "Initialize pywal colors for host";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${initColorsScript}/bin/init-host-colors";
      };
    };

    # Note: The walrgb script orchestrates updates across:
    # - pywal color generation
    # - RGB lighting (asusctl/openrgb)
    # - Polybar restart
    # - Firefox (pywalfox)
    # - GTK themes
    # - Dunst notifications
    # - Zathura PDF reader
    # - GitHub Pages colors (if applicable)
  };
}
