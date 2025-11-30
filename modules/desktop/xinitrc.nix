{ config, pkgs, lib, ... }:

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

  # Deploy all config files to user home directory
  home-manager.users.traum = {
    # X session bootstrap
    home.file.".xinitrc" = {
      source = ../../configs/xorg/.xinitrc;
      executable = true;
    };
    home.file.".Xmodmap".source = ../../configs/xorg/.Xmodmap;
    home.file.".xsessionrc".source = ../../configs/xorg/.xsessionrc;

    # Template files (processed by .xinitrc on X start)
    home.file.".config/i3/config.template".source = ../../configs/i3/config.template;
    home.file.".config/i3/config.base".source = ../../configs/i3/config.base;
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

    # Fish shell configuration
    home.file.".config/fish/config.fish".source = ../../configs/fish/config.fish;
    home.file.".config/fish/fish_variables".source = ../../configs/fish/fish_variables;
    # Fish functions
    home.file.".config/fish/functions" = {
      source = ../../configs/fish/functions;
      recursive = true;
    };

    # Other application configs
    home.file.".config/zathura/zathurarc".source = ../../configs/zathura/zathurarc;
    home.file.".config/starship/starship.toml".source = ../../configs/starship/starship.toml;
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
  };

  # Note: The .xinitrc script will:
  # 1. Restore pywal colors (wal -Rn)
  # 2. Detect VM vs host (hostname check)
  # 3. Load display configuration variables
  # 4. Generate actual configs from templates using sed
  # 5. Start i3 window manager
}
