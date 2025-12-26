{ config, lib, pkgs, ... }:

let
  # Check if we're building for a VM (vmType is set and not "host")
  isVM = (config.hydrix.vmType or null) != null && config.hydrix.vmType != "host";

  # Detect username dynamically (same pattern as base.nix)
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

  # VMs always use "user", host uses detected username
  username = if isVM then "user"
    else if hostConfig != null && hostConfig ? username
    then hostConfig.username
    else "user";
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

  options.hydrix = {
    vmType = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "pentest" "comms" "browsing" "dev" "host" ]);
      description = "VM/host type for fallback color scheme generation";
      default = null;
    };

    colorscheme = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Name of saved colorscheme to use (from colorschemes/*.json). If set, overrides vmType colors.";
      default = null;
      example = "tokyo-night";
    };
  };

  config = let
    # Check if custom scheme exists
    schemeFile = if config.hydrix.colorscheme != null
      then ../../colorschemes/${config.hydrix.colorscheme}.json
      else null;

    hasCustomScheme = config.hydrix.colorscheme != null && builtins.pathExists schemeFile;

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

      # Generate sequences for terminal
      BG=$(${pkgs.jq}/bin/jq -r '.special.background' "$SCHEME_JSON")
      FG=$(${pkgs.jq}/bin/jq -r '.special.foreground' "$SCHEME_JSON")

      # Build escape sequences (OSC - Operating System Command)
      SEQ=""
      for i in {0..15}; do
        COLOR=$(${pkgs.jq}/bin/jq -r ".colors.color$i" "$SCHEME_JSON")
        SEQ="$SEQ\e]4;$i;$COLOR\e\\"
      done
      SEQ="$SEQ\e]10;$FG\e\\\e]11;$BG\e\\\e]12;$FG\e\\\e]708;$BG\e\\"

      printf '%s' "$SEQ" > ~/.cache/wal/sequences

      # Mark as generated
      touch ~/.cache/wal/.static-colors-generated
      echo "CUSTOM_SCHEME=$SCHEME_JSON" > ~/.cache/wal/.static-colors-type

      echo "Colorscheme applied successfully"
    '';

    # Fallback script for vmType-based colors
    vmTypeColorsScript = pkgs.writeShellScriptBin "vm-static-colors"
      (builtins.readFile ../../scripts/vm-static-colors.sh);

  in {
    environment.systemPackages = [
      applySchemeScript
      vmTypeColorsScript

      # Actual walrgb/randomwalrgb scripts for VMs (adapted to use saved colorschemes)
      (pkgs.writeScriptBin "walrgb" (builtins.readFile ../../scripts/walrgb.sh))
      (pkgs.writeScriptBin "randomwalrgb" (builtins.readFile ../../scripts/randomwalrgb.sh))
      (pkgs.writeScriptBin "wal-gtk" (builtins.readFile ../../scripts/wal-gtk.sh))
      (pkgs.writeScriptBin "zathuracolors" (builtins.readFile ../../scripts/zathuracolors.sh))
    ];

    # Generate static pywal cache on first boot
    systemd.services.vm-static-colors = {
      description = "Apply static color scheme";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      unitConfig = {
        ConditionPathExists = "!/home/${username}/.cache/wal/.static-colors-generated";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
      };

      script = if hasCustomScheme then ''
        echo "Applying custom colorscheme: ${config.hydrix.colorscheme}"
        ${applySchemeScript}/bin/apply-colorscheme ${schemeFile}
      '' else ''
        echo "Generating ${if config.hydrix.vmType != null then config.hydrix.vmType else "host"} color scheme"
        ${vmTypeColorsScript}/bin/vm-static-colors ${if config.hydrix.vmType != null then config.hydrix.vmType else "host"}
      '';
    };
  };
}
