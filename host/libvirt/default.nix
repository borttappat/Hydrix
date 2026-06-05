# Host Libvirt Modules
# Host-side configuration for libvirt VMs and the libvirt router.
# Gated internally on hydrix.libvirt.enable and hydrix.router.type.
{ ... }:

{
  imports = [
    ./virt.nix    # libvirtd, QEMU, virt-manager, build-base/deploy-vm scripts
    ./router.nix  # libvirt router host management (XML generation, systemd service)
  ];
}
