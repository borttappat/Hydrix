# Host Libvirt Modules
# Host-side configuration for standalone libvirt VMs.
# Gated internally on hydrix.libvirt.enable.
{ ... }:

{
  imports = [
    ./virt.nix    # libvirtd, QEMU, virt-manager, build-base/deploy-vm scripts
  ];
}
