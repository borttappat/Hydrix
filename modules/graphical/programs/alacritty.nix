# Alacritty Terminal Configuration
#
# Home Manager module for Alacritty terminal emulator.
# Colors are automatically applied by Stylix (when vmColors disabled).
# Font size uses appSizes.alacritty from fonts.nix (overrides Stylix default).
#
# VM Color Inheritance:
# When hydrix.vmColors.enable is true, Stylix alacritty target is disabled and we set:
# - Background: from host colorscheme (config.hydrix.vmColors.hostColorscheme)
# - Text colors: from VM's own colorscheme (hydrix.colorscheme)
# This makes terminal text the visual differentiator between host and VM windows.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;

  # Scaling values
  sc = config.hydrix.graphical.scaling.computed;

  # Font configuration from unified options
  # Note: Runtime font size is handled by alacrittyDpi launcher reading scaling.json
  # This static value is only used if launched directly
  fontCfg = config.hydrix.graphical.font;
  fontSize = fontCfg.overrides.alacritty or fontCfg.size;

  # VM Colors support
  vmColorsEnabled = config.hydrix.vmColors.enable;
  vmColorscheme = config.hydrix.colorscheme;
  hostColorscheme = config.hydrix.vmColors.hostColorscheme;

  # Resolve colorscheme paths (user dir first, then framework)
  resolve = config.hydrix.resolveColorscheme;

  # Parse host colorscheme for background (when vmColors enabled)
  hostBackground = if vmColorsEnabled && hostColorscheme != null then
    let
      jsonPath = resolve hostColorscheme;
    in if builtins.pathExists jsonPath then
      let
        data = builtins.fromJSON (builtins.readFile jsonPath);
        special = data.special or {};
      in special.background or data.colors.color0
    else null
  else null;

  # Parse VM's colorscheme for colors (text + background fallback)
  # Only used when vmColors.enable is true
  vmTextColors = if vmColorsEnabled && vmColorscheme != null then
    let
      jsonPath = resolve vmColorscheme;
    in if builtins.pathExists jsonPath then
      let
        data = builtins.fromJSON (builtins.readFile jsonPath);
        colors = data.colors;
        special = data.special or {};
        # Foreground from special or fallback to color7
        fg = special.foreground or colors.color7;
        # Background from special or fallback to color0
        bg = special.background or colors.color0;
      in {
        foreground = fg;
        background = bg;
        # Normal colors (color0-7)
        normal = {
          black = colors.color0;
          red = colors.color1;
          green = colors.color2;
          yellow = colors.color3;
          blue = colors.color4;
          magenta = colors.color5;
          cyan = colors.color6;
          white = colors.color7;
        };
        # Bright colors (color8-15)
        bright = {
          black = colors.color8;
          red = colors.color9 or colors.color1;
          green = colors.color10 or colors.color2;
          yellow = colors.color11 or colors.color3;
          blue = colors.color12 or colors.color4;
          magenta = colors.color13 or colors.color5;
          cyan = colors.color14 or colors.color6;
          white = colors.color15 or colors.color7;
        };
      }
    else null
  else null;

  # Generate build-time alacritty colors TOML for VM fallback
  # This is the initial color set before runtime colors are pushed via vsock
  # Uses host background if available, otherwise VM's own background
  effectiveBackground = if hostBackground != null then hostBackground
    else if vmTextColors != null then vmTextColors.background
    else null;

  buildTimeAlacrittyToml = if (vmColorsEnabled && vmTextColors != null && effectiveBackground != null) then ''
    # Build-time alacritty colors (fallback, overridden at runtime by write-alacritty-colors)
    [colors.primary]
    background = "${effectiveBackground}"
    foreground = "${vmTextColors.foreground}"

    [colors.normal]
    black = "${vmTextColors.normal.black}"
    red = "${vmTextColors.normal.red}"
    green = "${vmTextColors.normal.green}"
    yellow = "${vmTextColors.normal.yellow}"
    blue = "${vmTextColors.normal.blue}"
    magenta = "${vmTextColors.normal.magenta}"
    cyan = "${vmTextColors.normal.cyan}"
    white = "${vmTextColors.normal.white}"

    [colors.bright]
    black = "${vmTextColors.bright.black}"
    red = "${vmTextColors.bright.red}"
    green = "${vmTextColors.bright.green}"
    yellow = "${vmTextColors.bright.yellow}"
    blue = "${vmTextColors.bright.blue}"
    magenta = "${vmTextColors.bright.magenta}"
    cyan = "${vmTextColors.bright.cyan}"
    white = "${vmTextColors.bright.white}"
  '' else null;

in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # Bake build-time alacritty colors to /etc for VM import fallback
    # This ensures alacritty has correct colors even before init-wal-cache runs
    environment.etc."hydrix-alacritty-colors.toml" = lib.mkIf (buildTimeAlacrittyToml != null) {
      text = buildTimeAlacrittyToml;
    };

    home-manager.users.${username} = { pkgs, ... }: {
      programs.alacritty = {
        enable = true;

        settings = {
          # Font size is now handled dynamically by the alacrittyDpi launcher
          # which reads from ~/.config/hydrix/scaling.json
          # This static value is only used if launched directly (not via i3 keybind)
          font.size = lib.mkForce fontSize;
          # Selection
          selection = {
            save_to_clipboard = true;
          };

          # General
          general = {
            live_config_reload = true;
            ipc_socket = true;
          } // lib.optionalAttrs vmColorsEnabled {
            # Single import: colors-runtime.toml is the sole color source for VMs.
            # Written by init-wal-cache (VM colorscheme default) or vsock handler
            # (host bg + VM text colors). No /etc/ import — avoids priority conflicts.
            import = [
              "~/.config/alacritty/colors-runtime.toml"
            ];
          };

          # Environment
          env = {
            TERM = "xterm-256color";
          };

          # Cursor
          cursor = {
            thickness = 0.35;
            unfocused_hollow = false;
            blink_timeout = 0;
            blink_interval = 500;
            style = {
              shape = "Underline";
              blinking = "Always";
            };
          };

          # Font configuration - handled by Stylix
          # Uncomment to override Stylix fonts:
          # font = {
          #   size = fontSize;
          #   builtin_box_drawing = false;
          #   offset = { x = 0; y = 0; };
          #   normal = { family = fontName; style = "Regular"; };
          #   bold = { family = fontName; style = "Bold"; };
          #   italic = { family = fontName; style = "Italic"; };
          #   bold_italic = { family = fontName; style = "Bold Italic"; };
          # };

          # Keyboard bindings
          keyboard.bindings = [
            { action = "Paste"; key = "V"; mods = "Control|Shift"; }
            { action = "Copy"; key = "C"; mods = "Control|Shift"; }
            { action = "PasteSelection"; key = "Insert"; mods = "Shift"; }
            { action = "ResetFontSize"; key = "Key0"; mods = "Control"; }
            { action = "IncreaseFontSize"; key = "Equals"; mods = "Control"; }
            { action = "IncreaseFontSize"; key = "Plus"; mods = "Control"; }
            { action = "DecreaseFontSize"; key = "Minus"; mods = "Control"; }
          ];

          # Window
          # Alacritty handles its own opacity (excluded from picom rules).
          # This keeps text 100% sharp while having transparent background.
          # Host and VMs use the same opacity for consistency.
          #
          # Opacity priority: overlayOverrides.alacritty > alacritty (legacy) > overlay
          #
          # resize_increments: Disabled for VMs to prevent xpra edge artifacts.
          # When enabled, alacritty snaps content to character cell boundaries,
          # leaving small gaps at right/bottom edges that xpra captures as artifacts.
          window = let
            opacityCfg = config.hydrix.graphical.ui.opacity;
            # Use overlayOverrides.alacritty if set, else legacy alacritty option, else overlay
            effectiveOpacity = opacityCfg.overlayOverrides.alacritty or opacityCfg.alacritty;
          in {
            opacity = lib.mkForce effectiveOpacity;
            dynamic_padding = true;
            resize_increments = !vmColorsEnabled;  # Disable for VMs to fix xpra artifacts
            class = {
              general = "Alacritty";
              instance = "Alacritty";
            };
            padding = { x = sc.padding; y = sc.padding + 2; };
          };

          # Selection colors - use CellForeground to keep original text colors visible
          # VM colors are NOT set here - they come from colors-runtime.toml import
          # (written at runtime by write-alacritty-colors, with /etc fallback for first boot)
          colors = {
            selection = {
              text = lib.mkForce "CellForeground"; # Keep original text colors instead of inverting
            };
          };
        };
      };
    };
  };
}
