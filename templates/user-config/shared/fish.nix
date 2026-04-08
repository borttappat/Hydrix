# Fish Shell — User Customizations
#
# The framework (fish.nix) provides: abbreviations, functions, vi bindings,
# fzf/zoxide integration, lockdown git wrapper, fish colors.
#
# Add your own abbreviations, functions, and shell init here.
# These merge with the framework-provided ones (no conflict for new keys).
# To override a framework abbreviation, use lib.mkForce.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.fish = {

        # -----------------------------------------------------------------------
        # Additional shell abbreviations
        # -----------------------------------------------------------------------
        # Merge with framework defaults — just add new keys here.
        # shellAbbrs = {
        #   myalias = "some long command";
        #   myproj  = "cd ~/projects/myproject";
        # };

        # -----------------------------------------------------------------------
        # Additional interactive shell init
        # lib.mkAfter ensures it runs after the framework's init block.
        # -----------------------------------------------------------------------
        # interactiveShellInit = lib.mkAfter ''
        #   # Your shell init here
        # '';

        # -----------------------------------------------------------------------
        # Additional functions
        # -----------------------------------------------------------------------
        # functions = {
        #   myfunc = ''
        #     echo "Hello, $argv"
        #   '';
        # };

      };
    };
  };
}
