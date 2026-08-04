# Host Modules - Configuration for the physical host machine
#
# All settings are read from config.hydrix.* options.
# No direct imports from local/ files.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./users.nix
    ./vfio.nix
    ./networking.nix
    ./router.nix
    ./libvirt       # libvirtd, QEMU, virt-manager (standalone VMs)
    ./services.nix
    ./scripts.nix
    ./specialisations.nix
    ./disko.nix
    ./hardware/intel.nix
    ./hardware/amd.nix
    ./hardware/asus.nix
    ./webcam-passthrough.nix
  ];
}
