# Host Modules - Configuration for the physical host machine
#
# All settings are read from config.hydrix.* options.
# No direct imports from local/ files.
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  imports = [
    ./users.nix
    ./vfio.nix
    ./networking.nix
    ./router.nix
    ./libvirt-router-host.nix
    ./services.nix
    ./scripts.nix
    ./specialisations.nix
    ./disko.nix
    ./hardware/intel.nix
    ./hardware/amd.nix
    ./hardware/asus.nix
  ];
}
