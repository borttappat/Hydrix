# Host Lockdown Module
# Apply this module to any existing host to enable lockdown mode
# Removes host internet access and sets up isolated VM bridges
#
# Usage in your machine config:
#   imports = [ ../modules/lockdown/host-lockdown.nix ];
#   hydrix.lockdown.enable = true;
#
# Or build a lockdown specialisation:
#   specialisation.lockdown.configuration = {
#     imports = [ ../modules/lockdown/host-lockdown.nix ];
#     hydrix.lockdown.enable = true;
#   };
#
# To boot into lockdown: select "lockdown" from boot menu or
#   nixos-rebuild switch --flake '.#zeph' --specialisation lockdown
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.hydrix.lockdown;
in {
  imports = [
    ./bridges.nix
    ../base/virt.nix  # Includes libvirtd, virt-manager, virt-install, etc.
  ];

  options.hydrix.lockdown = {
    # Additional options beyond bridges.nix
    disableHostNetworking = mkOption {
      type = types.bool;
      default = true;
      description = "Disable host's default route and internet access";
    };

    preserveLocalServices = mkOption {
      type = types.listOf types.str;
      default = [ "sshd" "libvirtd" ];
      description = "Services to keep running in lockdown mode";
    };

    managementBridgeHostIP = mkOption {
      type = types.str;
      default = "10.100.0.1";
      description = "Host's IP on the management bridge (for SSH from VMs)";
    };

    autoStartRouter = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically start the router VM on lockdown boot";
    };

    routerVmImage = mkOption {
      type = types.str;
      default = "/var/lib/libvirt/images/router-vm.qcow2";
      description = "Path to the router VM image";
    };

    routerVmMemory = mkOption {
      type = types.int;
      default = 2048;
      description = "Memory allocation for router VM in MB";
    };

    routerVmCpus = mkOption {
      type = types.int;
      default = 2;
      description = "Number of vCPUs for router VM";
    };
  };

  config = mkIf cfg.enable {
    # Force-disable NetworkManager's external connectivity
    networking = mkIf cfg.disableHostNetworking {
      # Remove default gateway - host cannot reach internet
      defaultGateway = mkForce null;
      defaultGateway6 = mkForce null;

      # Disable DHCP on physical interfaces
      useDHCP = mkForce false;

      # Keep NetworkManager but in a restricted mode
      networkmanager = {
        enable = mkForce true;
        # Don't manage our isolated bridges
        unmanaged = [
          "interface-name:br-*"
          "interface-name:virbr*"
        ];
      };
    };

    # Give host an IP on management bridge for VM access
    systemd.network.networks."25-br-mgmt-host" = mkIf cfg.enable {
      matchConfig.Name = "br-mgmt";
      address = [ "${cfg.managementBridgeHostIP}/24" ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
    };

    # Firewall adjustments for lockdown
    networking.firewall = mkIf cfg.enable {
      enable = mkForce true;

      # Only allow inbound from management network
      extraCommands = mkAfter ''
        # Drop all forwarding from host (router VM handles this)
        iptables -P FORWARD DROP

        # Only accept SSH from management network
        iptables -A INPUT -i br-mgmt -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -j DROP

        # Block host from initiating external connections
        # (except to VM networks for management)
        iptables -A OUTPUT -o br-mgmt -j ACCEPT
        iptables -A OUTPUT -o br-pentest -j ACCEPT
        iptables -A OUTPUT -o br-office -j ACCEPT
        iptables -A OUTPUT -o br-browse -j ACCEPT
        iptables -A OUTPUT -o br-dev -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        # Block everything else outbound
        iptables -A OUTPUT -j DROP
      '';
    };

    # Disable IP forwarding on host (router VM does this)
    boot.kernel.sysctl = mkIf cfg.disableHostNetworking {
      "net.ipv4.ip_forward" = mkForce 0;
      "net.ipv6.conf.all.forwarding" = mkForce 0;
    };

    # Ensure critical services stay running
    systemd.services = mkIf cfg.enable {
      # Make sure libvirtd starts
      libvirtd.wantedBy = mkForce [ "multi-user.target" ];

      # Auto-start router VM on lockdown boot
      lockdown-router-autostart = mkIf cfg.autoStartRouter {
        description = "Auto-start router VM for lockdown mode";
        wantedBy = [ "multi-user.target" ];
        after = [ "libvirtd.service" "libvirt-lockdown-networks.service" ];
        requires = [ "libvirtd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -e

          ROUTER_IMAGE="${cfg.routerVmImage}"
          ROUTER_NAME="lockdown-router"

          # Wait for libvirt to be fully ready
          sleep 3

          # Check if router VM is already defined
          if ! ${pkgs.libvirt}/bin/virsh dominfo "$ROUTER_NAME" >/dev/null 2>&1; then
            echo "Defining router VM..."

            # Check if image exists
            if [ ! -f "$ROUTER_IMAGE" ]; then
              echo "ERROR: Router VM image not found at $ROUTER_IMAGE"
              echo "Please build and deploy the router VM first:"
              echo "  nix build '.#router-vm'"
              echo "  sudo cp result/nixos.qcow2 $ROUTER_IMAGE"
              exit 1
            fi

            # Define the VM with all bridges attached
            ${pkgs.libvirt}/bin/virt-install \
              --name "$ROUTER_NAME" \
              --memory ${toString cfg.routerVmMemory} \
              --vcpus ${toString cfg.routerVmCpus} \
              --disk path="$ROUTER_IMAGE",format=qcow2,bus=virtio \
              --import \
              --os-variant nixos-unstable \
              --network bridge=br-wan,model=virtio \
              --network bridge=br-mgmt,model=virtio \
              --network bridge=br-pentest,model=virtio \
              --network bridge=br-office,model=virtio \
              --network bridge=br-browse,model=virtio \
              --network bridge=br-dev,model=virtio \
              --graphics spice \
              --video virtio \
              --channel spicevmc,target_type=virtio,name=com.redhat.spice.0 \
              --noautoconsole \
              --autostart \
              --print-xml > /tmp/router-vm.xml

            ${pkgs.libvirt}/bin/virsh define /tmp/router-vm.xml
            rm /tmp/router-vm.xml
          fi

          # Start the VM if not already running
          if [ "$(${pkgs.libvirt}/bin/virsh domstate "$ROUTER_NAME" 2>/dev/null)" != "running" ]; then
            echo "Starting router VM..."
            ${pkgs.libvirt}/bin/virsh start "$ROUTER_NAME"
          else
            echo "Router VM already running"
          fi

          # Enable autostart
          ${pkgs.libvirt}/bin/virsh autostart "$ROUTER_NAME" 2>/dev/null || true

          echo "Lockdown router VM started successfully"
        '';
      };

      # Reminder service on login
      lockdown-notice = {
        description = "Lockdown mode notice";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "lockdown-router-autostart.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          echo ""
          echo "╔════════════════════════════════════════════════════════════╗"
          echo "║                    LOCKDOWN MODE ACTIVE                    ║"
          echo "╠════════════════════════════════════════════════════════════╣"
          echo "║  Host internet access: DISABLED                            ║"
          echo "║  Router VM: ${if cfg.autoStartRouter then "AUTO-STARTED" else "Manual start required"}                                 ║"
          echo "║  Management IP: ${cfg.managementBridgeHostIP}                              ║"
          echo "╠════════════════════════════════════════════════════════════╣"
          echo "║  Networks:                                                 ║"
          echo "║    br-mgmt    → 10.100.0.x (management, no internet)       ║"
          echo "║    br-pentest → 10.100.1.x (client VPN)                    ║"
          echo "║    br-office  → 10.100.2.x (corporate VPN)                 ║"
          echo "║    br-browse  → 10.100.3.x (privacy VPN)                   ║"
          echo "║    br-dev     → 10.100.4.x (direct/configurable)           ║"
          echo "╠════════════════════════════════════════════════════════════╣"
          echo "║  SSH to router: ssh traum@10.100.0.253                     ║"
          echo "║  VPN status:    vpn-status (on router)                     ║"
          echo "╚════════════════════════════════════════════════════════════╝"
          echo ""
        '';
      };
    };

    # Add lockdown indicator to shell prompt
    programs.bash.promptInit = mkIf cfg.enable (mkAfter ''
      if [ -f /etc/LOCKDOWN_MODE ]; then
        PS1="[LOCKDOWN] $PS1"
      fi
    '');

    # Create lockdown mode indicator file
    environment.etc."LOCKDOWN_MODE".text = mkIf cfg.enable ''
      Lockdown mode enabled
      Host internet access: disabled
      Management IP: ${cfg.managementBridgeHostIP}
      Router VM required for external connectivity
    '';

    # Packages for lockdown management
    environment.systemPackages = mkIf cfg.enable (with pkgs; [
      bridge-utils
      iproute2
    ]);

    # Warning if trying to use network tools
    environment.shellAliases = mkIf cfg.enable {
      curl = "echo '[LOCKDOWN] Host has no internet. Use a VM.' && false";
      wget = "echo '[LOCKDOWN] Host has no internet. Use a VM.' && false";
      ping-external = "echo '[LOCKDOWN] Host has no internet. Use a VM.' && false";
    };
  };
}
