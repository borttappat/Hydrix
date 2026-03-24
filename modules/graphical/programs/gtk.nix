# GTK Theme Configuration
#
# Home Manager module for GTK theming.
# This affects GTK applications including:
# - Firefox file picker dialog
# - virt-manager
# - PCManFM and other file managers
# - Any GTK-based application
#
# Stylix handles colors automatically. This module configures:
# - GTK theme (dark mode)
# - Icon theme
# - Cursor theme
# - Font settings

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;


in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, config, ... }: {
      # GTK 2/3/4 Configuration
      gtk = {
        enable = true;

        # Font handled by Stylix
        # font = {
        #   name = fontName;
        #   size = fontSize;
        # };

        # Use dark theme
        gtk2.extraConfig = ''
          gtk-application-prefer-dark-theme = 1
        '';

        gtk3.extraConfig = {
          gtk-application-prefer-dark-theme = true;
          gtk-decoration-layout = "menu:close";
        };

        gtk4.extraConfig = {
          gtk-application-prefer-dark-theme = true;
          gtk-decoration-layout = "menu:close";
        };

        # Icon theme
        iconTheme = {
          package = pkgs.papirus-icon-theme;
          name = "Papirus-Dark";
        };

        # Cursor theme
        cursorTheme = {
          package = pkgs.vanilla-dmz;
          name = "Vanilla-DMZ";
          size = 24;
        };
      };

      # Qt configuration - let Stylix handle theme via qtct
      # Don't override platformTheme.name as Stylix sets it to "qtct"
      qt = {
        enable = true;
        # style.name handled by Stylix
      };

      # Install theme packages
      home.packages = with pkgs; [
        # Theme packages
        papirus-icon-theme
        vanilla-dmz

        # GTK settings tools
        lxappearance

        # dconf for virt-manager settings
        dconf
      ];

      # virt-manager specific settings via dconf
      dconf.settings = {
        "org/virt-manager/virt-manager" = {
          xmleditor-enabled = true;
        };

        "org/virt-manager/virt-manager/console" = {
          # Use left Super as grab key (avoids conflicting with mod key)
          grab-keys = "65515";
          scaling = 2;  # Scale to fit
          resize-guest = 1;  # Auto-resize guest
        };

        "org/virt-manager/virt-manager/confirm" = {
          forcepoweroff = false;
          removedev = false;
          unapplied-dev = false;
        };

        "org/virt-manager/virt-manager/stats" = {
          enable-cpu-poll = true;
          enable-disk-poll = true;
          enable-memory-poll = true;
          enable-net-poll = true;
        };

        "org/virt-manager/virt-manager/vmlist-fields" = {
          cpu-usage = true;
          disk-usage = false;
          host-cpu-usage = true;
          memory-usage = true;
          network-traffic = true;
        };

        # GTK file chooser settings
        "org/gtk/settings/file-chooser" = {
          show-hidden = true;
          sort-directories-first = true;
          location-mode = "path-bar";
        };
      };
    };
  };
}
