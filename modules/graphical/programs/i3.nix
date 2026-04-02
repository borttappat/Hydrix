# i3 Window Manager Configuration
#
# Home Manager module for i3 window manager.
# Colors and fonts are automatically applied by Stylix.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  # VMs use Mod1 (ALT), host uses Mod4 (SUPER)
  isVM = vmType != null && vmType != "host";
  mod = if isVM then "Mod1" else "Mod4";

  # Scaling values
  sc = config.hydrix.graphical.scaling.computed;

  # alacritty-dpi is provided by xpra-host.nix on PATH
  # It reads unified font size from scaling.json and disables winit's DPI scaling

  # Brightness control script - adjusts brightness on focused monitor
  # Uses brightnessctl for internal displays (hardware backlight)
  # Uses xrandr for external displays (software gamma)
  hydrix-brightness = pkgs.writeShellScriptBin "hydrix-brightness" ''
    STEP=10

    # Get focused monitor from i3
    MONITOR=$(${pkgs.i3}/bin/i3-msg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .output')

    if [ -z "$MONITOR" ]; then
      exit 1
    fi

    # Internal display: use brightnessctl (hardware backlight)
    if [[ "$MONITOR" == eDP-* ]]; then
      case "$1" in
        +) ${pkgs.brightnessctl}/bin/brightnessctl set +''${STEP}% ;;
        -) ${pkgs.brightnessctl}/bin/brightnessctl set ''${STEP}%- ;;
        *) exit 1 ;;
      esac
    else
      # External display: use xrandr (software gamma)
      CURRENT=$(${pkgs.xorg.xrandr}/bin/xrandr --verbose | ${pkgs.gawk}/bin/awk -v mon="$MONITOR" '
        $1 == mon { found=1 }
        found && /Brightness:/ { print $2; exit }
      ')
      : "''${CURRENT:=1.0}"

      case "$1" in
        +) NEW=$(echo "$CURRENT + 0.1" | ${pkgs.bc}/bin/bc) ;;
        -) NEW=$(echo "$CURRENT - 0.1" | ${pkgs.bc}/bin/bc) ;;
        *) exit 1 ;;
      esac

      # Clamp to 0.1-1.5 range
      NEW=$(echo "$NEW" | ${pkgs.gawk}/bin/awk '{if ($1 < 0.1) print 0.1; else if ($1 > 1.5) print 1.5; else print $1}')

      ${pkgs.xorg.xrandr}/bin/xrandr --output "$MONITOR" --brightness "$NEW"
    fi
  '';

  # Vibrancy control script - adjusts saturation on focused monitor
  hydrix-vibrancy = pkgs.writeShellScriptBin "hydrix-vibrancy" ''
    STEP=0.2
    STATE_FILE="/tmp/vibrant_state"

    # Get focused monitor from i3
    MONITOR=$(${pkgs.i3}/bin/i3-msg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .output')

    if [ -z "$MONITOR" ]; then
      exit 1
    fi

    # Read current state (default 1.0 = normal saturation)
    if [ -f "$STATE_FILE" ]; then
      CURRENT=$(${pkgs.gawk}/bin/awk -v mon="$MONITOR" '$1 == mon {print $2}' "$STATE_FILE")
    fi
    : "''${CURRENT:=1.0}"

    case "$1" in
      +) NEW=$(echo "$CURRENT + $STEP" | ${pkgs.bc}/bin/bc);;
      -) NEW=$(echo "$CURRENT - $STEP" | ${pkgs.bc}/bin/bc);;
      *) exit 1;;
    esac

    # Clamp to 0.0-4.0 range
    NEW=$(echo "$NEW" | ${pkgs.gawk}/bin/awk '{if ($1 < 0) print 0; else if ($1 > 4) print 4; else print $1}')

    # Apply vibrancy
    ${pkgs.libvibrant}/bin/vibrant-cli "$MONITOR" "$NEW"

    # Save state (update or add entry for this monitor)
    if [ -f "$STATE_FILE" ] && grep -q "^$MONITOR " "$STATE_FILE"; then
      ${pkgs.gnused}/bin/sed -i "s/^$MONITOR .*/$MONITOR $NEW/" "$STATE_FILE"
    else
      echo "$MONITOR $NEW" >> "$STATE_FILE"
    fi
  '';

  # Floating terminal script - cascades windows across the screen
  hydrix-float-terminal = pkgs.writeShellScriptBin "hydrix-float-terminal" ''
    STATE_FILE="/tmp/i3_float_state"
    X_OFFSET=50
    Y_OFFSET=50
    MAX_WINDOWS=5
    # Window size from i3 window rules (line ~309)
    WIN_WIDTH=800
    WIN_HEIGHT=450

    # Get cursor position to determine which monitor
    eval $(${pkgs.xdotool}/bin/xdotool getmouselocation --shell)

    # Get display info for cursor position (offset_x, offset_y, width, height)
    DISPLAY_INFO=$(${pkgs.xorg.xrandr}/bin/xrandr --listmonitors | ${pkgs.gawk}/bin/awk -v x="$X" -v y="$Y" '
    $1 ~ /^[0-9]+:/ {
        split($3, pos, /[x+]/)
        split(pos[1], w, /\//)
        split(pos[2], h, /\//)
        width = w[1]
        height = h[1]
        offset_x = pos[3]
        offset_y = pos[4]
        if (x >= offset_x && x < offset_x + width && y >= offset_y && y < offset_y + height) {
            print offset_x " " offset_y " " width " " height
        }
    }')

    read DISPLAY_OFFSET_X DISPLAY_OFFSET_Y DISPLAY_WIDTH DISPLAY_HEIGHT <<< "$DISPLAY_INFO"
    : "''${DISPLAY_OFFSET_X:=0}"
    : "''${DISPLAY_OFFSET_Y:=0}"
    : "''${DISPLAY_WIDTH:=1920}"
    : "''${DISPLAY_HEIGHT:=1080}"

    # Calculate centered starting position (offset back by cascade space)
    # Start at ~25% from center to leave room for cascading
    INIT_X=$(( (DISPLAY_WIDTH - WIN_WIDTH) / 2 - (MAX_WINDOWS * X_OFFSET / 2) ))
    INIT_Y=$(( (DISPLAY_HEIGHT - WIN_HEIGHT) / 2 - (MAX_WINDOWS * Y_OFFSET / 2) ))
    # Clamp to minimum of 50px from edge
    [ $INIT_X -lt 50 ] && INIT_X=50
    [ $INIT_Y -lt 50 ] && INIT_Y=50

    # Read current state
    if [ -f "$STATE_FILE" ]; then
        read window_count current_x current_y < "$STATE_FILE"
    else
        window_count=0
        current_x=$((DISPLAY_OFFSET_X + INIT_X))
        current_y=$((DISPLAY_OFFSET_Y + INIT_Y))
    fi

    # Count floating windows on current workspace
    floating_windows=$(${pkgs.i3}/bin/i3-msg -t get_tree | ${pkgs.jq}/bin/jq '.. | select(.type?) | select(.type=="workspace" and .focused==true) | .. | select(.type?=="floating_con") | .nodes | length' 2>/dev/null || echo 0)

    # Calculate position
    if [ "$floating_windows" -eq 0 ] 2>/dev/null; then
        window_count=0
        current_x=$((DISPLAY_OFFSET_X + INIT_X))
        current_y=$((DISPLAY_OFFSET_Y + INIT_Y))
    else
        window_count=$((window_count + 1))
        new_x=$((current_x + X_OFFSET))
        new_y=$((current_y + Y_OFFSET))

        # Check if window would exceed monitor bounds
        max_x=$((DISPLAY_OFFSET_X + DISPLAY_WIDTH - WIN_WIDTH - 50))
        max_y=$((DISPLAY_OFFSET_Y + DISPLAY_HEIGHT - WIN_HEIGHT - 50))

        if [ $window_count -gt $MAX_WINDOWS ] || [ $new_x -gt $max_x ] || [ $new_y -gt $max_y ]; then
            window_count=1
            current_x=$((DISPLAY_OFFSET_X + INIT_X))
            current_y=$((DISPLAY_OFFSET_Y + INIT_Y))
        else
            current_x=$new_x
            current_y=$new_y
        fi
    fi

    # Save state
    echo "$window_count $current_x $current_y" > "$STATE_FILE"

    # Launch floating alacritty (DPI-aware)
    alacritty-dpi --class floating -o window.position.x=$current_x -o window.position.y=$current_y &
  '';
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    environment.systemPackages = [
      hydrix-brightness
      hydrix-vibrancy
      hydrix-float-terminal
    ];


    home-manager.users.${username} = { pkgs, ... }: {
      xsession.windowManager.i3 = {
        enable = true;
        package = pkgs.i3;

        config = {
          modifier = mod;

          # Fonts handled by Stylix

          # Gaps (scaled)
          # Note: gaps are updated by display-setup to match runtime DPI from scaling.json
          # The values here are defaults; display-setup modifies the config file directly
          # Formula: bar_gaps + bar_height (gap around bar, windows start immediately after)
          gaps = {
            inner = sc.gaps;
            outer = sc.outerGaps;  # Matches barGaps when outerGapsMatchBar=true, else 0
            top = sc.barGaps + sc.barHeight;
            bottom = if config.hydrix.graphical.ui.bottomBar then sc.barGaps + sc.barHeight else 0;
          };

          # Border (scaled)
          window.border = sc.border;
          floating.border = sc.border;

          # Focus
          focus.followMouse = false;

          # Floating modifier
          floating.modifier = mod;

          # Default workspace layout
          workspaceLayout = "default";

          # Workspace output assignments (set in hydrix-config)
          workspaceOutputAssign = [];

          # Keybindings — provided by user-config shared/i3.nix
          # Use lib.mkOptionDefault in your keybindings to merge with HM defaults
          keybindings = lib.mkOptionDefault {};

          # Resize mode
          modes = {
            resize = {
              "h" = "resize shrink width 15 px or 15 ppt";
              "j" = "resize grow height 15 px or 15 ppt";
              "k" = "resize shrink height 15 px or 15 ppt";
              "l" = "resize grow width 15 px or 15 ppt";
              "Left" = "resize shrink width 2 px or 2 ppt";
              "Up" = "resize grow height 2 px or 2 ppt";
              "Down" = "resize shrink height 2 px or 2 ppt";
              "Right" = "resize grow width 2 px or 2 ppt";
              "Return" = "mode default";
              "Escape" = "mode default";
              "${mod}+r" = "mode default";
            };
          };

          # Startup applications
          # Note: xsession.nix handles early startup (SPICE, xcape, xmodmap)
          # dunst is started by services.dunst (Home Manager)
          # picom is started by services.picom (Home Manager)
          # polybar is started by services.polybar (Home Manager)
          startup = [
            # Start on workspace 1 (not some random workspace)
            { command = "i3-msg workspace 1"; notification = false; }

            # xss-lock: hooks into systemd-logind for suspend/resume handling
            # -l transfers sleep lock to locker (suspend waits for lock)
            # Uses lock-instant for suspend (pre-cached background, instant)
            # Manual lock (Mod+Shift+e) uses regular lock script with fresh screenshot
            { command = "${pkgs.xss-lock}/bin/xss-lock -l -- lock-instant"; notification = false; }

            # Restore pywal colors on i3 reload
            { command = "wal -Rnq"; always = true; notification = false; }
            { command = "xrdb -merge ~/.Xresources"; always = true; notification = false; }
            { command = "xrdb -merge ~/.cache/wal/colors.Xresources"; always = true; notification = false; }

            # Restore wallpaper
            { command = "~/.fehbg"; always = true; notification = false; }
          ];

          # Window rules
          window.commands = [
            { criteria = { instance = "floating"; }; command = "floating enabled"; }
            { criteria = { instance = "floating"; }; command = "resize set 800 450"; }
            { criteria = { class = "Polybar"; }; command = "border pixel 0"; }
            { criteria = { class = "Polybar"; }; command = "floating enable"; }
            { criteria = { class = "Polybar"; }; command = "sticky enable"; }
            { criteria = { class = "splash-cover"; }; command = "fullscreen enable"; }
            { criteria = { class = "splash-cover"; }; command = "border pixel 0"; }
            { criteria = { class = "splash-cover"; }; command = "floating enable"; }
            { criteria = { class = "splash-cover"; }; command = "sticky enable"; }
          ];

          # Disable focus for certain windows
          focus.newWindow = "smart";

          # Disable default i3 bar (we use polybar)
          bars = [];
        };

        # Extra config for things HM module doesn't support
        extraConfig = ''
          # Remove window title bars, use pixel borders only
          default_border pixel 2
          default_floating_border pixel 2

          # Colors from Xresources
          set_from_resource $border i3wm.color4 #ffffff
          set_from_resource $fg i3wm.color7 #ffffff
          set_from_resource $bg i3wm.color0 #f0f0f0
          set_from_resource $al i3wm.color8 #ff0000
          set_from_resource $c1 i3wm.color3 #f0f0f0
          set_from_resource $c2 i3wm.color0 #f0f0f0

          # Window colors (format: border background text indicator child_border)
          # Unfocused windows use $bg to blend borders with background (appears borderless)
          # Note: #00000000 renders as black in i3, not transparent
          client.focused          $border    $bg        $fg      $border    $border
          client.focused_inactive $bg        $bg        $c2      $bg        $bg
          client.unfocused        $bg        $bg        $c2      $bg        $bg
          client.urgent           $al        $al        $al      $al        $al

          # Polybar - no focus
          no_focus [class="Polybar"]
          no_focus [class="splash-cover"]

          # VM xpra windows - i3 handles borders (colored by vm-focus-daemon)
          # Title format: [type] app_title (set by vm-app --title='[type] @title@')
          for_window [title="^\[browsing\]"] border pixel ${toString sc.border}
          for_window [title="^\[pentest\]"] border pixel ${toString sc.border}
          for_window [title="^\[comms\]"] border pixel ${toString sc.border}
          for_window [title="^\[dev\]"] border pixel ${toString sc.border}
          for_window [title="^\[lurking\]"] border pixel ${toString sc.border}

          # Tiling drag
          tiling_drag modifier

          # Hide borders when fullscreen or only one container visible
          # hide_edge_borders smart
        '';
      };
    };
  };
}
