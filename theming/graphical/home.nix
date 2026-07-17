# Home Manager Configuration Aggregator
#
# Central module that configures all user-level programs via Home Manager.
# Stylix will automatically theme most of these when enabled.
#
# This replaces:
# - modules/desktop/xinitrc.nix (template deployment)
# - modules/shell/fish-home.nix
# - modules/desktop/firefox.nix
# - Most configs/*.template files

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;

  # Detect if we're in a VM (for keybinding differences)
  # "host" is not a VM, it's the physical machine
  isVM = config.hydrix.vmType != null && config.hydrix.vmType != "host";
  modKey = if isVM then "Mod1" else "Mod4";

  isHost = config.hydrix.vmType == null || config.hydrix.vmType == "host";
  isMicrovm = !isHost && !config.hydrix.graphical.standalone;

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
    # Note: xsession is configured in xsession.nix
    # Note: i3 window manager is configured in i3.nix
    home-manager.users.${username} = { pkgs, ... }: {
      home.stateVersion = "26.05";
      stylix.enableReleaseChecks = false;

      # Make variables available to program modules
      home.sessionVariables = {
        HYDRIX_IS_VM = if isVM then "1" else "0";
        HYDRIX_MOD_KEY = modKey;
      };

      # Common packages available to user
      # Note: starship, ranger, joshuto, vim are configured in hydrix-config/shared/
      home.packages = with pkgs; [
        # Terminal utilities
        tmux
        fzf
        jq

        # Notifications
        libnotify

        # Pywal for color experimentation
        pywal
      ] ++ lib.optionals (!isMicrovm && config.hydrix.i3.enable) [
        # X11/i3 utilities — not needed under Wayland
        xclip
        xsel
        xdotool
        unclutter
        scrot
        slop
      ];
    };
  };
}
