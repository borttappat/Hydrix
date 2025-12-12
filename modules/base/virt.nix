# Virtualization configuration (for hosts, not VMs)
{ config, pkgs, lib, ... }:

{
  options = {
    virtualisation = {
      useDocker = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use Docker instead of Podman";
      };
      mainUser = lib.mkOption {
        type = lib.types.str;
        default = "traum";
        description = "Main user for virtualization permissions";
      };
      enableLookingGlass = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Looking Glass for GPU passthrough";
      };
    };
  };

  config = {
    # Resolve mbedtls security warning
    nixpkgs.config.permittedInsecurePackages = [ "mbedtls-2.28.10" ];

    # SPICE agent
    services.spice-vdagentd.enable = true;

    # Core virtualization
    virtualisation = {
      libvirtd = {
        enable = true;
        qemu = {
          package = pkgs.qemu_kvm;
          ovmf = {
            enable = true;
            packages = [ pkgs.OVMFFull.fd ];
          };
          swtpm.enable = true;
          runAsRoot = true;
        };
        onBoot = "start";
        onShutdown = "shutdown";
      };

      docker = lib.mkIf config.virtualisation.useDocker {
        enable = true;
        autoPrune = {
          enable = true;
          dates = "weekly";
          flags = [ "--all" ];
        };
        daemon.settings = {
          data-root = "/var/lib/docker";
          storage-driver = "overlay2";
        };
      };

      podman = lib.mkIf (!config.virtualisation.useDocker) {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    # Networking for VMs
    networking = {
      firewall = {
        allowedTCPPorts = [
          16509 16514  # libvirt (secure)
          5900 5901 5902 5903  # VNC
          3389  # RDP
        ] ++ lib.optionals config.virtualisation.enableLookingGlass [
          9999  # Looking Glass SPICE
        ];
        allowedUDPPorts = [ 8472 ];
        checkReversePath = "loose";
        # Trust both libvirt default bridge (virbr0) and Hydrix bridges (br-*)
        trustedInterfaces = [ "virbr0" "br-mgmt" "br-pentest" "br-office" "br-browse" "br-dev" ];
      };

      nat = {
        enable = true;
        internalInterfaces = [ "virbr0" ];
      };
    };

    # Kernel parameters for virtualization
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
      "vm.max_map_count" = 2147483647;
      "kernel.unprivileged_userns_clone" = 1;
    };

    # Virtualization packages
    environment.systemPackages = with pkgs; [
      qemu_kvm
      virt-manager
      virt-viewer
      libvirt
      libosinfo
      guestfs-tools
      spice-gtk
      spice-vdagent
      spice-protocol
      swtpm
      virtiofsd
      win-virtio
      win-spice
      bridge-utils
      iproute2
      bind.dnsutils
    ] ++ lib.optionals config.virtualisation.useDocker [
      docker-compose
      lazydocker
    ] ++ lib.optionals config.virtualisation.enableLookingGlass [
      looking-glass-client
    ];

    # Add user to virtualization groups
    users.users.${config.virtualisation.mainUser}.extraGroups =
      [ "libvirtd" "kvm" "qemu" ]
      ++ lib.optional config.virtualisation.useDocker "docker";

    # Libvirt service setup
    systemd.services.libvirtd = {
      path = with pkgs; [ bridge-utils iproute2 ];
      preStart = ''
        mkdir -p /var/lib/libvirt/{qemu/networks/autostart,images,dnsmasq}
        chmod 755 /var/lib/libvirt/{qemu/networks{,/autostart},images,dnsmasq}
      '';
    };

    # Default libvirt network
    environment.etc."libvirt/qemu/networks/default.xml".text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <network>
        <name>default</name>
        <forward mode="nat">
          <nat>
            <port start='1024' end='65535'/>
          </nat>
        </forward>
        <bridge name="virbr0" stp='on' delay='0'/>
        <dns enable="yes">
          <forwarder addr="1.1.1.1"/>
          <forwarder addr="8.8.8.8"/>
          <forwarder addr="9.9.9.9"/>
        </dns>
        <ip address="192.168.122.1" netmask="255.255.255.0">
          <dhcp>
            <range start="192.168.122.10" end="192.168.122.200"/>
            <lease expiry="24" unit="hours"/>
          </dhcp>
        </ip>
      </network>
    '';
  };
}
