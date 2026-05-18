# Core Modules - Shared by ALL systems (host + VMs)
#
# These modules contain configuration that every Hydrix system needs.
# Settings are read from config.hydrix.* options.
{ ... }:

{
  imports = [
    ./nix.nix
    ./packages.nix
    ./audio.nix
    ./shell.nix
  ];
}
