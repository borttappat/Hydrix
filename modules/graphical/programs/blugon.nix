# Blugon Blue Light Filter Configuration
#
# Provides screen color temperature adjustment to reduce eye strain.
# Controlled via polybar module (click to adjust) or keybindings.
#
# HYBRID AUTO/MANUAL MODE:
# - On boot: Auto-polls based on time-of-day schedule (warm at night, cool during day)
# - On Mod+F5/F6: Stops auto-polling, uses manual temperature
# - On Mod+Shift+F6 (reset): Restores auto-polling
#
# Manual temperature stored in ~/.config/blugon/current
# Mode stored in ~/.config/blugon/mode ("manual" or empty/missing for auto)

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical.bluelight;
  schedule = cfg.schedule;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";

  blugonPath = "${pkgs.blugon}/bin/blugon";

  # Script to initialize blugon config on first run
  blugonInitScript = pkgs.writeShellScriptBin "blugon-init" ''
    CONFIG_DIR="$HOME/.config/blugon"
    CURRENT_FILE="$CONFIG_DIR/current"
    CONFIG_FILE="$CONFIG_DIR/config"
    GAMMA_FILE="$CONFIG_DIR/gamma"
    MODE_FILE="$CONFIG_DIR/mode"

    # Create config directory if needed
    mkdir -p "$CONFIG_DIR"

    # Initialize current temperature if not set (for manual mode)
    if [ ! -f "$CURRENT_FILE" ]; then
      echo "${toString cfg.defaultTemp}" > "$CURRENT_FILE"
    fi

    # Preserve disabled state across rebuilds - only reset if not disabled
    if [ -f "$MODE_FILE" ] && [ "$(cat "$MODE_FILE")" = "disabled" ]; then
      : # Keep disabled state
    else
      rm -f "$MODE_FILE"
    fi

    # Create gamma schedule (time-based for auto mode)
    # Format: hour minute temperature
    cat > "$GAMMA_FILE" << 'GAMMA'
# Hour Minute Temperature
# Time-based schedule: warm at night, cool during day
0   0   ${toString schedule.nightTemp}
${toString schedule.dayStart}   0   ${toString schedule.dayTemp}
${toString schedule.nightStart}  0   ${toString schedule.nightTemp}
24  0   ${toString schedule.nightTemp}
GAMMA

    # Create main config
    # readcurrent = False so blugon follows the gamma schedule in auto mode
    cat > "$CONFIG_FILE" << EOF
[main]
readcurrent = False
interval = 60
backend = scg
wait_for_x = True
fade = False

[current]
min_temp = ${toString cfg.minTemp}.0
max_temp = ${toString cfg.maxTemp}.0

[wait_for_x]
sleep_after_failed_startup = 0.5
sleep_after_losing_x = 10.0

[fade]
steps = 10
duration = 3.0
EOF
  '';

  # Script to set temperature (with bounds checking and mode handling)
  blugonSetScript = pkgs.writeShellScriptBin "blugon-set" ''
    CONFIG_DIR="$HOME/.config/blugon"
    CURRENT_FILE="$CONFIG_DIR/current"
    MODE_FILE="$CONFIG_DIR/mode"
    MIN_TEMP=${toString cfg.minTemp}
    MAX_TEMP=${toString cfg.maxTemp}
    STEP=${toString cfg.step}
    DEFAULT_TEMP=${toString cfg.defaultTemp}

    # Initialize if needed
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CURRENT_FILE" ]; then
      echo "$DEFAULT_TEMP" > "$CURRENT_FILE"
    fi

    # Get current temp
    current=$(cat "$CURRENT_FILE" 2>/dev/null || echo "$DEFAULT_TEMP")

    case "$1" in
      +|up|warmer)
        # Warmer = lower temp (more red)
        # Switch to manual mode - stop blugon service
        systemctl --user stop blugon.service 2>/dev/null || true
        echo "manual" > "$MODE_FILE"
        new=$((current - STEP))
        ;;
      -|down|cooler)
        # Cooler = higher temp (more blue)
        # Switch to manual mode - stop blugon service
        systemctl --user stop blugon.service 2>/dev/null || true
        echo "manual" > "$MODE_FILE"
        new=$((current + STEP))
        ;;
      reset)
        # Resume auto mode - remove mode file and restart blugon service
        rm -f "$MODE_FILE"
        systemctl --user start blugon.service 2>/dev/null || true
        exit 0  # Let blugon daemon set the temp based on schedule
        ;;
      disable|off)
        # Disable blugon entirely - stop service and reset screen to neutral
        systemctl --user stop blugon.service 2>/dev/null || true
        echo "disabled" > "$MODE_FILE"
        echo "$MAX_TEMP" > "$CURRENT_FILE"
        ${blugonPath} --readcurrent --once 2>/dev/null || true
        exit 0
        ;;
      enable|on)
        # Re-enable blugon in auto mode
        rm -f "$MODE_FILE"
        systemctl --user start blugon.service 2>/dev/null || true
        exit 0
        ;;
      *)
        # Absolute value - also switches to manual mode
        if [ -n "$1" ]; then
          systemctl --user stop blugon.service 2>/dev/null || true
          echo "manual" > "$MODE_FILE"
          new="$1"
        else
          echo "Usage: blugon-set [+|-|reset|disable|enable|<temp>]"
          echo "  + / warmer  - decrease temp (more red), switches to manual mode"
          echo "  - / cooler  - increase temp (more blue), switches to manual mode"
          echo "  reset       - restore auto mode (time-based schedule)"
          echo "  disable/off - disable blugon entirely (neutral screen)"
          echo "  enable/on   - re-enable blugon in auto mode"
          echo "  <temp>      - set absolute temperature, switches to manual mode"
          echo ""
          mode=$(cat "$MODE_FILE" 2>/dev/null || echo "auto")
          echo "Current mode: $mode"
          echo "Current temp: $(cat "$CURRENT_FILE" 2>/dev/null || echo "$DEFAULT_TEMP")K"
          exit 1
        fi
        ;;
    esac

    # Clamp to bounds
    if [ "$new" -lt "$MIN_TEMP" ]; then
      new=$MIN_TEMP
    elif [ "$new" -gt "$MAX_TEMP" ]; then
      new=$MAX_TEMP
    fi

    # Set the new temperature
    echo "$new" > "$CURRENT_FILE"

    # Apply immediately using --readcurrent --once
    ${blugonPath} --readcurrent --once 2>/dev/null || true
  '';

in {
  config = lib.mkIf (config.hydrix.graphical.enable && cfg.enable && !isVM) {
    # Add blugon package
    environment.systemPackages = [ pkgs.blugon ];

    home-manager.users.${username} = { pkgs, lib, ... }: {
      # Add helper scripts to path
      home.packages = [
        blugonInitScript
        blugonSetScript
      ];

      # Initialize config on home activation (so it works before service starts)
      home.activation.blugonInit = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${blugonInitScript}/bin/blugon-init
      '';

      # Autostart blugon daemon (auto mode - follows time-based schedule)
      systemd.user.services.blugon = {
        Unit = {
          Description = "Blugon blue light filter (auto mode)";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          Type = "simple";
          # Don't start if user has disabled blugon via blugon-set off
          ExecCondition = "${pkgs.bash}/bin/bash -c '[ ! -f %h/.config/blugon/mode ] || [ \"$(cat %h/.config/blugon/mode)\" != \"disabled\" ]'";
          # No --readcurrent: follows gamma schedule (time-based)
          ExecStart = "${blugonPath}";
          Restart = if cfg.autoRestart then "on-failure" else "no";
          RestartSec = 5;
        };
        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      };
    };
  };
}
