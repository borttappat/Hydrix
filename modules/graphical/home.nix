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
    ./programs/alacritty.nix
    ./programs/fish.nix
    ./programs/i3.nix
    ./programs/polybar.nix
    ./programs/rofi.nix
    ./programs/dunst.nix
    ./programs/picom.nix
    ./programs/zathura.nix
    ./programs/vim.nix
    ./programs/firefox.nix
    ./programs/starship.nix
    ./programs/ranger.nix
    ./programs/obsidian.nix
    ./programs/gtk.nix
  ];

  config = lib.mkIf config.hydrix.graphical.enable {
    # Home Manager user configuration
    # Note: xsession is configured in xsession.nix
    # Note: i3 window manager is configured in i3.nix
    home-manager.users.${username} = { pkgs, ... }: {
      home.stateVersion = "25.05";

      # Make variables available to program modules
      home.sessionVariables = {
        HYDRIX_IS_VM = if isVM then "1" else "0";
        HYDRIX_MOD_KEY = modKey;
      };

      # Common packages available to user
      home.packages = with pkgs; [
        # Terminal utilities
        tmux
        fzf
        jq
        starship  # Prompt (also enabled via programs.starship but explicit for PATH)

        # File managers (configured separately)
        ranger
        joshuto

        # Clipboard (useful in all graphical environments including xpra)
        xclip
        xsel

        # Notifications
        libnotify

        # Pywal for color experimentation
        pywal
      ] ++ lib.optionals (!isMicrovm) [
        # Standalone + host: WM utilities and screenshot tools
        xdotool
        unclutter
        scrot
        slop
      ];
    };
  };
}
