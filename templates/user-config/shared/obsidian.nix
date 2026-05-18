# Obsidian — User Configuration
#
# Controls whether Obsidian is installed on the host and which vaults
# receive the Hydrix CSS theme snippet (fonts + colorscheme).
#
# The framework auto-generates the snippet from the active colorscheme and
# font settings. It is deployed to each vault's .obsidian/snippets/ directory
# and enabled via appearance.json.
#
# vaultPaths are relative to $HOME, e.g.:
#   [ "notes" "hack_the_world" "projects/my-vault" ]

{ lib, ... }:

{
  # Install Obsidian on the host system
  hydrix.graphical.obsidian.hostEnable = lib.mkDefault false;

  # Vaults to deploy the Hydrix CSS theme snippet to
  # hydrix.graphical.obsidian.vaultPaths = lib.mkDefault [
  #   "notes"
  #   "hack_the_world"
  # ];
}
