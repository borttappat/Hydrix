# __NAME_CAP__ Profile Packages
#
# Profile-specific package set. Add packages for this VM here.
# Core VM packages (editors, shell, utils) are in shared/vm-packages.nix.
# Custom packages pulled via vm-sync live in packages/default.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Add your packages here
  ];
}
