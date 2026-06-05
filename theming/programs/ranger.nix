# Ranger File Manager Configuration
#
# Home Manager module for Ranger file manager.
# All settings and mappings use lib.mkDefault so hydrix-config modules can
# override any individual entry without lib.mkForce.
# Use hydrix.graphical.ranger.extraMappings / extraRifle to extend from config.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  rangerCfg = config.hydrix.graphical.ranger;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.ranger = {
        enable = lib.mkDefault true;

        settings = {
          # Preview
          preview_images        = lib.mkDefault true;
          preview_images_method = lib.mkDefault "kitty";
          preview_files         = lib.mkDefault true;
          preview_directories   = lib.mkDefault true;
          collapse_preview      = lib.mkDefault true;

          # Display
          draw_borders       = lib.mkDefault "both";
          column_ratios      = lib.mkDefault "1,3,4";
          hidden_filter      = lib.mkDefault "^\\.|\\.pyc$|~$";
          show_hidden        = lib.mkDefault false;
          confirm_on_delete  = lib.mkDefault "multiple";

          # Behavior
          autosave_bookmarks   = lib.mkDefault true;
          save_console_history = lib.mkDefault true;
          mouse_enabled        = lib.mkDefault true;
          tilde_in_titlebar    = lib.mkDefault true;

          # Sorting
          sort                   = lib.mkDefault "natural";
          sort_case_insensitive  = lib.mkDefault true;
          sort_directories_first = lib.mkDefault true;

          # VCS
          vcs_aware       = lib.mkDefault true;
          vcs_backend_git = lib.mkDefault "enabled";
        };

        mappings = lib.mkMerge [
          {
            # Quick navigation
            gh = lib.mkDefault "cd ~";
            gH = lib.mkDefault "cd ${config.hydrix.paths.configDir}";
            gd = lib.mkDefault "cd ~/Downloads";
            gD = lib.mkDefault "cd ~/Documents";
            gp = lib.mkDefault "cd ~/Pictures";
            gv = lib.mkDefault "cd ~/Videos";
            gc = lib.mkDefault "cd ~/.config";
            gn = lib.mkDefault "cd /nix/store";

            # Operations
            DD = lib.mkDefault "shell mv %s ~/.local/share/Trash/files/";
            X  = lib.mkDefault "shell extract %s";
            Z  = lib.mkDefault "shell tar -cvzf %f.tar.gz %s";

            # Toggle settings
            zh = lib.mkDefault "set show_hidden!";
            zp = lib.mkDefault "set preview_files!";
            zi = lib.mkDefault "set preview_images!";
          }
          rangerCfg.extraMappings
        ];

        rifle = [
          # Web
          { condition = "ext x?html?, has firefox, X, flag f"; command = "firefox -- \"$@\""; }

          # Text
          { condition = "mime ^text, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }
          { condition = "ext py, label editor";     command = "\${VISUAL:-$EDITOR} -- \"$@\""; }
          { condition = "ext nix, label editor";    command = "\${VISUAL:-$EDITOR} -- \"$@\""; }

          # Images
          { condition = "mime ^image, has feh, X, flag f";  command = "feh -- \"$@\""; }
          { condition = "mime ^image, has sxiv, X, flag f"; command = "sxiv -- \"$@\""; }

          # Video/Audio
          { condition = "mime ^video, has mpv, X, flag f"; command = "mpv -- \"$@\""; }
          { condition = "mime ^audio, has mpv, X, flag f"; command = "mpv -- \"$@\""; }

          # PDF
          { condition = "ext pdf, has zathura, X, flag f"; command = "zathura -- \"$@\""; }

          # Archives
          { condition = "ext tar|gz|bz2|xz|zip|rar|7z"; command = "extract \"$@\""; }

          # Fallback
          { condition = "mime ^text, label pager"; command = "\${PAGER:-less} -- \"$@\""; }
        ] ++ rangerCfg.extraRifle;
      };

      # Joshuto as alternative file manager
      # Note: Config is handled by Stylix if it targets joshuto,
      # otherwise uses joshuto's defaults
      home.packages = [ pkgs.joshuto ];
    };
  };
}
