# Home Manager Configuration Aggregator
#
# Central module that configures all user-level programs via Home Manager.
# Colors come from wal at runtime by default; Stylix (opt-in, see stylix.nix)
# will additionally auto-theme most of these if the consuming flake supplies it.
#
# This replaces:
# - modules/desktop/xinitrc.nix (template deployment)
# - modules/shell/fish-home.nix
# - modules/desktop/firefox.nix
# - Most configs/*.template files
{
  config,
  lib,
  pkgs,
  hasStylix ? false,
  ...
}: let
  username = config.hydrix.username;
  hostStateVersion = config.system.stateVersion;

  # Detect if we're in a VM (for keybinding differences)
  # "host" is not a VM, it's the physical machine
  isVM = config.hydrix.vmType != null && config.hydrix.vmType != "host";
  modKey =
    if isVM
    then "Mod1"
    else "Mod4";
in {
  imports = [
    ../programs/alacritty.nix
    ../programs/fish.nix
    ../programs/dunst.nix
    ../programs/zathura.nix
    ../programs/firefox.nix
    ../programs/gtk.nix
  ];

  config = lib.mkIf config.hydrix.graphical.enable {
    # Home Manager user configuration
    home-manager.users.${username} = {pkgs, ...}:
      lib.mkMerge [
        (lib.optionalAttrs hasStylix {stylix.enableReleaseChecks = false;})
        {
          home.stateVersion = hostStateVersion;

          # Make variables available to program modules
          home.sessionVariables = {
            HYDRIX_IS_VM =
              if isVM
              then "1"
              else "0";
            HYDRIX_MOD_KEY = modKey;
          };

          # Common packages available to user
          # Note: starship, ranger, joshuto, vim are configured in hydrix-config/modules/
          home.packages = with pkgs; [
            # Terminal utilities
            tmux
            fzf
            jq

            # Notifications
            libnotify

            # Pywal for color experimentation
            pywal
          ];
        }
      ];
  };
}
