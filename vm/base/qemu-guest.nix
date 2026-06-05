# QEMU guest configuration
#
# X11 display setup (services.xserver) is gated on hydrix.i3.enable — Hydrix is
# Wayland/Hyprland-first. When i3 is enabled, the default modeline targets 2560x1440;
# to use a different resolution, override services.xserver.displayManager.sessionCommands
# in your hydrix-config modules (e.g. modules/i3.nix):
#
#   services.xserver.displayManager.sessionCommands = lib.mkForce ''
#     xrandr --newmode "1920x1080" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync 2>/dev/null || true
#     xrandr --addmode Virtual-1 1920x1080 2>/dev/null || true
#     xrandr --output Virtual-1 --mode 1920x1080 2>/dev/null || true
#     xrandr --auto
#     spice-vdagent -x &
#   '';
#
{ config, lib, pkgs, ... }:

{
  # VM guest services — always present regardless of display mode
  virtualisation.vmware.guest.enable = true;
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  # X11 video drivers and resolution setup — only active when hydrix.i3.enable = true.
  # Wayland/Hyprland VMs do not use services.xserver for their primary display.
  services.xserver = lib.mkIf config.hydrix.i3.enable {
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

}
