# QEMU guest configuration
{ config, lib, pkgs, ... }:

{
  # VM guest services
  virtualisation.vmware.guest.enable = true;
  services.qemuGuest.enable = true;
  services.qemu-guest-agent.enable = true;  # Modern QEMU guest agent for host-VM communication
  services.spice-vdagentd.enable = true;

  # X11 video drivers for VMs
  services.xserver = {
    videoDrivers = [ "virtio" "qxl" "vmware" "modesetting" ];
    displayManager.sessionCommands = ''
      ${pkgs.xorg.xrandr}/bin/xrandr --newmode "2560x1440" 312.25 2560 2752 3024 3488 1440 1443 1448 1493 -hsync +vsync 2>/dev/null || true
      ${pkgs.xorg.xrandr}/bin/xrandr --addmode Virtual-1 2560x1440 2>/dev/null || true
      ${pkgs.xorg.xrandr}/bin/xrandr --output Virtual-1 --mode 2560x1440 2>/dev/null || true
      ${pkgs.xorg.xrandr}/bin/xrandr --auto
      ${pkgs.spice-vdagent}/bin/spice-vdagent -x &
    '';
  };

  # Virtio kernel modules
  boot.initrd.availableKernelModules = [
    "virtio_balloon"
    "virtio_blk"
    "virtio_pci"
    "virtio_ring"
    "virtio_net"
    "virtio_scsi"
    "virtio_console"
  ];

  # Disable power management for VMs
  powerManagement = {
    enable = false;
    cpuFreqGovernor = lib.mkDefault "performance";
  };

  # Disable services not needed in VMs
  services = {
    thermald.enable = false;
    tlp.enable = false;
  };

  # zram for VMs
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    algorithm = "zstd";
  };

  # VM tools
  environment.systemPackages = with pkgs; [
    open-vm-tools
    spice-vdagent
    spice-gtk
  ];

  # Networking
  networking = {
    firewall.allowPing = true;
    useDHCP = lib.mkDefault true;
  };

  # Boot settings for VMs
  boot.loader.timeout = lib.mkDefault 1;
  boot.kernelParams = [
    "quiet"
    "console=tty1"
    "console=ttyS0,115200n8"
  ];

  # SSH for remote access
  services.openssh = {
    enable = true;
    settings = {
      X11Forwarding = true;
    };
  };
}
