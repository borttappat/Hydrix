{ config, pkgs, lib, ... }:

let
  # Detect username dynamically
  # For host: reads from local/host.nix
  # For VMs: defaults to "user"
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";
  hostConfigPath = "${basePath}/local/host.nix";

  # Use local config username if available (host), otherwise "user" (VM)
  hostConfig = if builtins.pathExists hostConfigPath
    then import hostConfigPath
    else null;

  username = if hostConfig != null && hostConfig ? username
    then hostConfig.username
    else "user";
in
{
  # X session bootstrap and config file deployment
  #
  # This module:
  # 1. Enables startx (type "x" at TTY to start X)
  # 2. Deploys .xinitrc for X session initialization
  # 3. Deploys all template files for runtime config generation
  # 4. Deploys supporting configs (fish, zathura, ranger, etc.)

  # Enable startx
  services.xserver.displayManager.startx.enable = true;

  # Automatically backup conflicting files when home-manager tries to manage them
  home-manager.backupFileExtension = "hm-backup";

  # Deploy all config files to user home directory
  home-manager.users.${username} = {
    # Set home-manager state version (must match system stateVersion or use latest)
    home.stateVersion = "25.05";

    # X session bootstrap
    home.file.".xinitrc" = {
      source = ../../configs/xorg/.xinitrc;
      executable = true;
    };
    home.file.".Xmodmap".source = ../../configs/xorg/.Xmodmap;
    home.file.".xsessionrc".source = ../../configs/xorg/.xsessionrc;

    # Template files (processed by i3launch.sh on X start)
    home.file.".config/i3/config.template".source = ../../configs/i3/config.template;
    home.file.".config/alacritty/alacritty.toml.template".source = ../../configs/alacritty/alacritty.toml.template;
    home.file.".config/polybar/config.ini.template".source = ../../configs/polybar/config.ini.template;
    home.file.".config/dunst/dunstrc.template".source = ../../configs/dunst/dunstrc.template;
    home.file.".config/rofi/config.rasi.template".source = ../../configs/rofi/config.rasi.template;

    # Display configuration
    home.file.".config/display-config.json".source = ../../configs/display-config.json;

    # Scripts for template processing and display config
    home.file.".config/scripts/load-display-config.sh" = {
      source = ../../scripts/load-display-config.sh;
      executable = true;
    };
    home.file.".config/scripts/load-display-config.fish" = {
      source = ../../scripts/load-display-config.fish;
      executable = true;
    };
    home.file.".config/scripts/autostart.sh" = {
      source = ../../scripts/autostart.sh;
      executable = true;
    };
    home.file.".config/scripts/alacritty.sh" = {
      source = ../../scripts/alacritty.sh;
      executable = true;
    };
    home.file.".config/scripts/detect-monitors.sh" = {
      source = ../../scripts/detect-monitors.sh;
      executable = true;
    };
    home.file.".config/scripts/workspace-setup.sh" = {
      source = ../../scripts/workspace-setup.sh;
      executable = true;
    };
    home.file.".config/scripts/refresh-display-config.sh" = {
      source = ../../scripts/refresh-display-config.sh;
      executable = true;
    };
    home.file.".config/scripts/rofi.sh" = {
      source = ../../scripts/rofi.sh;
      executable = true;
    };
    home.file.".config/scripts/float_window.sh" = {
      source = ../../scripts/float_window.sh;
      executable = true;
    };
    home.file.".config/scripts/scaled-app" = {
      source = ../../scripts/scaled-app;
      executable = true;
    };
    home.file.".config/scripts/lock.sh" = {
      source = ../../scripts/lock.sh;
      executable = true;
    };

    # Fish shell configuration is managed by fish-home.nix
    # Only deploy fish_variables and functions here to avoid conflicts
    home.file.".config/fish/fish_variables".source = ../../configs/fish/fish_variables;
    home.file.".config/fish/functions" = {
      source = ../../configs/fish/functions;
      recursive = true;
    };

    # Other application configs
    home.file.".config/zathura/zathurarc".source = ../../configs/zathura/zathurarc;
    # starship.toml is deployed by fish-home.nix
    home.file.".config/picom/picom.conf".source = ../../configs/picom/picom.conf;
    home.file.".config/htop/htoprc".source = ../../configs/htop/htoprc;

    # Ranger file manager
    home.file.".config/ranger/rifle.conf".source = ../../configs/ranger/rifle.conf;
    home.file.".config/ranger/rc.conf".source = ../../configs/ranger/rc.conf;
    home.file.".config/ranger/scope.sh" = {
      source = ../../configs/ranger/scope.sh;
      executable = true;
    };

    # Joshuto file manager
    home.file.".config/joshuto/joshuto.toml".source = ../../configs/joshuto/joshuto.toml;
    home.file.".config/joshuto/mimetype.toml".source = ../../configs/joshuto/mimetype.toml;
    home.file.".config/joshuto/preview_file.sh" = {
      source = ../../configs/joshuto/preview_file.sh;
      executable = true;
    };

    # Pywal dunst template
    home.file.".config/wal/templates/dunstrc".source = ../../configs/wal/templates/dunstrc;

    # Firefox configuration templates (processed by .xinitrc)
    # Note: Firefox profile directory may vary - using generic path
    home.file.".config/firefox/${username}/chrome/userChrome.css.template".source = ../../configs/firefox/traum/chrome/userChrome.css.template;
    home.file.".config/firefox/${username}/chrome/userContent.css.template".source = ../../configs/firefox/traum/chrome/userContent.css.template;
    home.file.".config/firefox/${username}/user.js.template".source = ../../configs/firefox/traum/user.js.template;
    home.file.".mozilla/firefox/profiles.ini".source = ../../configs/firefox/profiles.ini;

    # Obsidian configuration templates (deployed by deploy-obsidian-config script)
    home.file.".config/obsidian-templates/appearance.json.template".source = ../../configs/obsidian/appearance.json.template;
    home.file.".config/obsidian-templates/snippets/cozette-font.css.template".source = ../../configs/obsidian/snippets/cozette-font.css.template;
  };

  # Note: The .xinitrc script will:
  # 1. Restore pywal colors (wal -Rn)
  # 2. Detect VM vs host (hostname check)
  # 3. Load display configuration variables
  # 4. Generate actual configs from templates using sed (i3, polybar, alacritty, dunst, firefox)
  # 5. Start i3 window manager
}
