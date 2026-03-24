# VFIO Configuration - PCI passthrough for router VM
#
# Reads from hydrix.hardware.vfio.*
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  vfioCfg = cfg.hardware.vfio;
  platform = cfg.hardware.platform;
in {
  config = lib.mkIf (cfg.vmType == "host" && vfioCfg.enable) {
    # IOMMU kernel parameters
    boot.kernelParams = [
      # Platform-specific IOMMU
      (if platform == "intel" then "intel_iommu=on" else "amd_iommu=on")
      "iommu=pt"
    ] ++ (map (id: "vfio-pci.ids=${id}") vfioCfg.pciIds);

    # VFIO kernel modules
    boot.kernelModules = [
      "vfio"
      "vfio_iommu_type1"
      "vfio_pci"
      "br_netfilter"
    ];

    # Blacklist WiFi driver (passed to router VM)
    boot.blacklistedKernelModules = [ "iwlwifi" ];

    # Disable bridge netfilter (prevents VM traffic being filtered by host iptables)
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 0;
      "net.bridge.bridge-nf-call-ip6tables" = 0;
      "net.bridge.bridge-nf-call-arptables" = 0;
    };
  };
}
