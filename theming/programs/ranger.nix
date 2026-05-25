# Ranger File Manager Configuration
#
# Home Manager module for Ranger file manager.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.ranger = {
        enable = true;

        settings = {
          # Preview
          preview_images = true;
          preview_images_method = "kitty";
          preview_files = true;
          preview_directories = true;
          collapse_preview = true;

          # Display
          draw_borders = "both";
          column_ratios = "1,3,4";
          hidden_filter = "^\\.|\\.pyc$|~$";
          show_hidden = false;
          confirm_on_delete = "multiple";

          # Behavior
          autosave_bookmarks = true;
          save_console_history = true;
          mouse_enabled = true;
          tilde_in_titlebar = true;

          # Sorting
          sort = "natural";
          sort_case_insensitive = true;
          sort_directories_first = true;

          # VCS
          vcs_aware = true;
          vcs_backend_git = "enabled";
        };

        mappings = {
          # Quick navigation
          gh = "cd ~";
          gH = "cd ${config.hydrix.paths.configDir}";
          gd = "cd ~/Downloads";
          gD = "cd ~/Documents";
          gp = "cd ~/Pictures";
          gv = "cd ~/Videos";
          gc = "cd ~/.config";
          gn = "cd /nix/store";

          # Operations
          DD = "shell mv %s ~/.local/share/Trash/files/";
          X = "shell extract %s";
          Z = "shell tar -cvzf %f.tar.gz %s";

          # Toggle settings
          zh = "set show_hidden!";
          zp = "set preview_files!";
          zi = "set preview_images!";
        };

        rifle = [
          # Web
          { condition = "ext x?html?, has firefox, X, flag f"; command = "firefox -- \"$@\""; }

          # Text
          { condition = "mime ^text, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }
          { condition = "ext py, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }
          { condition = "ext nix, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }

          # Images
          { condition = "mime ^image, has feh, X, flag f"; command = "feh -- \"$@\""; }
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
        ];
      };

      # Joshuto as alternative file manager
      # Note: Config is handled by Stylix if it targets joshuto,
      # otherwise uses joshuto's defaults
      home.packages = [ pkgs.joshuto ];
    };
  };
}
