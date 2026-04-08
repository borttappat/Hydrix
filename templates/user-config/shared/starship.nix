# Starship Prompt — User Configuration
#
# Symlinks configs/starship/starship.toml to ~/.config/starship.toml at build time.
# Edit configs/starship/starship.toml to customise your prompt.
# Reference: https://starship.rs/config/

{ config, lib, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { ... }: {
      xdg.configFile."starship.toml".source = lib.mkForce ../configs/starship/starship.toml;

      # -------------------------------------------------------------------
      # Starship environment variables (optional)
      # -------------------------------------------------------------------
      # home.sessionVariables = {
      #   STARSHIP_LOG = "error";
      # };
    };
  };
}
