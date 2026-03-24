# Common Configuration - Shared across all machines
#
# Settings here apply to ALL your machines.
# Machine-specific overrides go in machines/<hostname>.nix
#
# To use: uncomment the import in flake.nix:
#   modules = [ (machinesDir + "/${file}") ./shared/common.nix ];

{ config, lib, pkgs, ... }:

{
  # Example: Shared locale settings
  # hydrix.locale = {
  #   timezone = "Europe/Stockholm";
  #   language = "en_US.UTF-8";
  # };

  # Example: Packages installed on all machines
  # environment.systemPackages = with pkgs; [
  #   git
  #   neovim
  # ];

  # Example: Common user setup
  # users.users.${config.hydrix.username}.extraGroups = [ "docker" ];
}
