# Picom Compositor Configuration
#
# Home Manager module for Picom compositor.
# Supports two animation modes:
# - none: Standard picom with fading only (xrender, no blur)
# - modern: Picom v12 with bouncy animations (xrender, overshoot curves)
#
# Configure via hydrix.graphical.ui.compositor.animations option.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";

  # Scaling values
  sc = config.hydrix.graphical.scaling.computed;

  # Compositor settings
  animationMode = config.hydrix.graphical.ui.compositor.animations;

  # Opacity settings
  opacityCfg = config.hydrix.graphical.ui.opacity;

  # Generate opacity rules from options
  excludeRules = map (class: "100:class_g = '${class}'") opacityCfg.exclude;
  customRules = lib.mapAttrsToList (class: opacity: "${toString opacity}:class_g = '${class}'") opacityCfg.rules;
  allOpacityRules = excludeRules ++ customRules;

  # Generate blur exclude list
  blurExclude = [
    "window_type = 'dock'"
    "window_type = 'desktop'"
  ] ++ map (class: "class_g = '${class}'") opacityCfg.exclude;

  # Modern animations config (picom v12 syntax)
  # Uses xrender backend, vsync=false for snappiness, no blur for performance
  modernPicomConfig = pkgs.writeText "picom-modern.conf" ''
    # Modern picom v12 with animations
    backend = "xrender";
    vsync = false;
    use-damage = true;
    crop-shadow-to-monitor = true;

    # Shadows
    shadow = true;
    shadow-radius = ${toString sc.shadowRadius};
    shadow-opacity = 0.75;
    shadow-offset-x = ${toString (0 - sc.shadowOffset)};
    shadow-offset-y = ${toString (0 - sc.shadowOffset)};

    # Corners
    corner-radius = ${toString sc.cornerRadius};
    round-borders = 2;
    detect-rounded-corners = true;

    # Opacity
    active-opacity = ${toString opacityCfg.active};
    inactive-opacity = ${toString opacityCfg.inactive};
    frame-opacity = 1.0;
    inactive-opacity-override = false;

    # General
    detect-client-opacity = true;
    detect-transient = true;

    # Bouncy animations (subtle overshoot curves)
    animations = (
      {
        triggers = ["close"];
        opacity = {
          curve = "cubic-bezier(0.2,0,0.8,1)";
          duration = 0.2;
          start = "window-raw-opacity-before";
          end = 0;
        };
        shadow-opacity = "opacity";
        offset-x = "(1 - scale-x) / 2 * window-width";
        offset-y = "(1 - scale-y) / 2 * window-height";
        scale-x = {
          curve = "cubic-bezier(0.4,0,1,1)";
          duration = 0.25;
          start = 1;
          end = 0.5;
        };
        scale-y = {
          curve = "cubic-bezier(0.4,0,1,1)";
          duration = 0.25;
          start = 1;
          end = 0.5;
        };
        shadow-scale-x = "scale-x";
        shadow-scale-y = "scale-y";
        shadow-offset-x = "offset-x";
        shadow-offset-y = "offset-y";
      },
      {
        triggers = ["open"];
        opacity = {
          curve = "cubic-bezier(0,1,1,1)";
          duration = 0.1;
          start = 0;
          end = "window-raw-opacity";
        };
        shadow-opacity = "opacity";
        offset-x = "(1 - scale-x) / 2 * window-width";
        offset-y = "(1 - scale-y) / 2 * window-height";
        scale-x = {
          curve = "cubic-bezier(0,1.1,0.3,1)";
          duration = 0.25;
          start = 0.7;
          end = 1;
        };
        scale-y = {
          curve = "cubic-bezier(0,1.1,0.3,1)";
          duration = 0.25;
          start = 0.7;
          end = 1;
        };
        shadow-scale-x = "scale-x";
        shadow-scale-y = "scale-y";
        shadow-offset-x = "offset-x";
        shadow-offset-y = "offset-y";
      },
      {
        triggers = ["show"];
        opacity = {
          curve = "cubic-bezier(0.22,1,0.36,1)";
          duration = 0.2;
          start = 0;
          end = "window-raw-opacity";
        };
        offset-x = {
          curve = "cubic-bezier(0.22,1,0.36,1)";
          duration = 0.2;
          start = 80;
          end = 0;
        };
        shadow-opacity = "opacity";
        shadow-offset-x = "offset-x";
      },
      {
        triggers = ["hide"];
        opacity = {
          curve = "cubic-bezier(0.4,0,1,1)";
          duration = 0.15;
          start = "window-raw-opacity-before";
          end = 0;
        };
        offset-x = {
          curve = "cubic-bezier(0.4,0,1,1)";
          duration = 0.15;
          start = 0;
          end = -80;
        };
        shadow-opacity = "opacity";
        shadow-offset-x = "offset-x";
      },
      {
        triggers = ["geometry"];
        scale-x = {
          curve = "cubic-bezier(0,0,0,1.1)";
          duration = 0.2;
          start = "window-width-before / window-width";
          end = 1;
        };
        scale-y = {
          curve = "cubic-bezier(0,0,0,1.1)";
          duration = 0.2;
          start = "window-height-before / window-height";
          end = 1;
        };
        offset-x = {
          curve = "cubic-bezier(0,0,0,1.1)";
          duration = 0.2;
          start = "window-x-before - window-x";
          end = 0;
        };
        offset-y = {
          curve = "cubic-bezier(0,0,0,1.1)";
          duration = 0.2;
          start = "window-y-before - window-y";
          end = 0;
        };
        shadow-scale-x = "scale-x";
        shadow-scale-y = "scale-y";
        shadow-offset-x = "offset-x";
        shadow-offset-y = "offset-y";
      }
    );

    # Rules - window-specific settings including opacity
    rules = (
      # Polybar and dock: no shadows, no corners, simple fade
      {
        match = "class_g = 'Polybar' || window_type = 'dock'";
        animations = (
          {
            triggers = ["open", "show"];
            opacity = { curve = "cubic-bezier(0,1,1,1)"; duration = 0.1; start = 0; end = "window-raw-opacity"; };
          },
          {
            triggers = ["close", "hide"];
            opacity = { curve = "cubic-bezier(0,1,1,1)"; duration = 0.1; start = "window-raw-opacity-before"; end = 0; };
          }
        );
        corner-radius = 0;
        shadow = false;
      },
      {
        match = "window_type = 'desktop'";
        shadow = false;
        corner-radius = 0;
      },
      {
        match = "_GTK_FRAME_EXTENTS@";
        shadow = false;
      },
      # Excluded windows: always fully opaque
      # Note: Don't add catch-all focused/unfocused rules here - they break animations
      # Global active-opacity/inactive-opacity (lines 59-60) handle focus-based opacity
      ${lib.concatMapStringsSep ",\n      " (class: ''
      {
        match = "class_g = '${class}'";
        opacity = 1.0;
      }'') opacityCfg.exclude}${lib.optionalString (opacityCfg.rules != {}) ",\n      ${
        lib.concatMapStringsSep ",\n      " (class: ''
      {
        match = "class_g = '${class}'";
        opacity = ${toString (opacityCfg.rules.${class} / 100.0)};
      }'') (lib.attrNames opacityCfg.rules)
      }"}
    )
  '';

in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      # "none" mode: Use Home Manager services.picom (no animations, fading only)
      services.picom = lib.mkIf (animationMode == "none") {
        enable = !isVM;
        package = pkgs.picom;

        # Backend (xrender for CPU-only systems)
        backend = "xrender";
        vSync = false;

        # Shadows (scaled)
        shadow = true;
        shadowOffsets = [ (0 - sc.shadowOffset) (0 - sc.shadowOffset) ];
        shadowOpacity = 0.99;
        shadowExclude = [
          "name = 'Notification'"
          "class_g = 'Conky'"
          "class_g ?= 'Notify-osd'"
          "class_g = 'Cairo-clock'"
          "class_g = 'Dunst'"
          "class_g = 'Rofi'"
          "_GTK_FRAME_EXTENTS@"
        ];

        # Fading
        fade = true;
        fadeSteps = [ 0.02 0.01 ];
        fadeDelta = 2;

        # Opacity
        activeOpacity = opacityCfg.active;
        inactiveOpacity = opacityCfg.inactive;
        opacityRules = allOpacityRules;

        # Window type settings
        wintypes = {
          tooltip = { fade = true; shadow = true; opacity = 0.75; focus = true; };
          dock = { shadow = false; };
          dnd = { shadow = false; };
          popup_menu = { opacity = 0.8; };
          dropdown_menu = { opacity = 0.8; };
        };

        settings = {
          # Blur disabled with xrender (use glx backend if blur needed)
          blur-background = false;

          # Shadows
          shadow-radius = sc.shadowRadius;

          # Opacity
          frame-opacity = 1.0;
          inactive-opacity-override = false;
          inactive-dim = 0.0;

          # Corners
          corner-radius = sc.cornerRadius;
          round-borders = 2;
          rounded-corners-exclude = [
            "window_type = 'dock'"
            "window_type = 'desktop'"
          ];

          # General
          use-damage = true;
          crop-shadow-to-monitor = true;
          detect-rounded-corners = true;
          detect-client-opacity = true;
          detect-transient = true;
          log-level = "warn";
        };
      };

      # "modern" mode: Use custom systemd service with modern animations
      systemd.user.services.picom = lib.mkIf (animationMode == "modern" && !isVM) {
        Unit = {
          Description = "Picom compositor (modern animations)";
          After = [ "graphical-session-pre.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${pkgs.picom}/bin/picom --config ${modernPicomConfig}";
          Restart = "on-failure";
          RestartSec = 3;
        };
        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      };
    };
  };
}
