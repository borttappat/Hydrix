#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly HYDRIX_DIR="$PROJECT_DIR"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"
readonly GENERATED_DIR="$PROJECT_DIR/generated"
readonly ROUTER_MODULE_DIR="$PROJECT_DIR/modules/router"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Hydrix setup - Complete end-to-end machine configuration and VM deployment

This script performs the COMPLETE workflow:
1. Hardware detection (IOMMU, WiFi device, PCI slots)
2. Generate router credentials (random password, SSH keys)
3. Build router VM with credentials baked in
4. Build pentest VM base image (two-stage: base + shaping)
5. Generate machine-specific VFIO configs
6. Create machine profile (profiles/machines/[machine].nix)
7. Update flake.nix with machine configuration
8. Generate deployment scripts
9. Stage all generated files in git
10. Deploy router VM with WiFi passthrough (if in router/maximalism mode)
11. Deploy pentest VM (if in maximalism mode)

OPTIONS:
    --machine-name NAME     Machine name for configs (default: auto-detect)
    --vm-name NAME          Pentest VM name (default: pentest-vm-auto)
    --skip-router          Skip router VM build/deploy
    --skip-pentest         Skip pentest VM build/deploy
    --force-rebuild        Force rebuild even if VMs exist
    --help                 Show this help

EXAMPLES:
    # Full automated setup (recommended) - does EVERYTHING
    $0

    # Quick pentest-only setup
    $0 --skip-router

    # Custom machine setup
    $0 --machine-name zephyrus --vm-name pentest-grief

OUTPUT FILES:
    - generated/modules/[machine]-consolidated.nix (VFIO + specialisations)
    - profiles/machines/[machine].nix (machine profile)
    - flake.nix (updated with nixosConfiguration.[machine])
    - generated/scripts/autostart-router-vm.sh
    - /var/lib/libvirt/images/router-vm-passthrough.qcow2
    - /var/lib/libvirt/images/[vm-name].qcow2

AFTER SETUP:
    Rebuild your system with your chosen mode:

    sudo nixos-rebuild switch --flake ~/Hydrix#[machine] --impure
    sudo nixos-rebuild switch --flake ~/Hydrix#[machine] --specialisation router --impure
    sudo nixos-rebuild switch --flake ~/Hydrix#[machine] --specialisation maximalism --impure
EOF
}

# Default values
MACHINE_NAME=""
MACHINE_MODEL=""
VM_NAME="pentest-vm-auto"
SKIP_ROUTER=false
SKIP_PENTEST=false
SKIP_DOTFILES=false
FORCE_REBUILD=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --machine-name)
            MACHINE_NAME="$2"
            shift 2
            ;;
        --vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        --skip-router)
            SKIP_ROUTER=true
            shift
            ;;
        --skip-pentest)
            SKIP_PENTEST=true
            shift
            ;;
        --skip-dotfiles)
            SKIP_DOTFILES=true
            shift
            ;;
        --force-rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

check_prerequisites() {
    log "=== Checking Prerequisites ==="

    if [[ $EUID -eq 0 ]]; then
        error "Don't run this as root"
    fi

    # Note: Hydrix doesn't require dotfiles directory

    local missing=()
    for cmd in nix virsh virt-install openssl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
    fi

    if ! groups | grep -q libvirt; then
        error "User not in libvirt group. Run: sudo usermod -a -G libvirt $USER && newgrp libvirt"
    fi

    if ! sudo systemctl is-active --quiet libvirtd; then
        log "Starting libvirtd..."
        sudo systemctl start libvirtd
    fi

    log "Prerequisites verified"
}

auto_detect_machine() {
    log "=== Auto-detecting Machine Configuration ==="

    if [[ -z "$MACHINE_NAME" ]]; then
        local vendor=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs || echo "")
        local model=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs || echo "")
        local hostname=$(hostname)

        if [[ -n "$model" ]]; then
            local model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')

            if echo "$model_lower" | grep -q "zenbook"; then
                MACHINE_NAME="zenbook"
                MACHINE_MODEL="zenbook"
            elif echo "$model_lower" | grep -q "zephyrus"; then
                MACHINE_NAME="zephyrus"
                MACHINE_MODEL="zephyrus"
            elif echo "$model_lower" | grep -q "razer"; then
                MACHINE_NAME="razer"
                MACHINE_MODEL="razer"
            elif echo "$vendor" | grep -qi "schenker"; then
                MACHINE_NAME="xmg"
                MACHINE_MODEL="xmg"
            elif echo "$vendor" | grep -qi "asus"; then
                MACHINE_NAME="asus"
                MACHINE_MODEL="asus"
            else
                MACHINE_NAME=$(echo "$model_lower" | sed 's/[^a-z0-9]//g' | cut -c1-10)
                MACHINE_MODEL="$MACHINE_NAME"
            fi
        else
            MACHINE_NAME="$hostname"
            MACHINE_MODEL="$hostname"
        fi
    fi

    if [[ -z "$MACHINE_MODEL" ]]; then
        MACHINE_MODEL="$MACHINE_NAME"
    fi

    log "Machine: $MACHINE_NAME"
    log "Model Pattern: $MACHINE_MODEL"
}

step1_hardware_detection() {
    log "=== STEP 1: Hardware Detection ==="

    cd "$PROJECT_DIR"

    if ! ./scripts/hardware-identify.sh; then
        error "Hardware detection failed"
    fi

    if [[ -f "hardware-results.env" ]]; then
        source hardware-results.env
        log "Hardware Score: ${COMPATIBILITY_SCORE:-0}/10"
        log "WiFi Device: ${PRIMARY_INTERFACE:-unknown} (${PRIMARY_ID:-unknown})"
        log "PCI Slot: ${PRIMARY_PCI:-unknown}"

        if [[ ${COMPATIBILITY_SCORE:-0} -lt 5 ]]; then
            error "Hardware compatibility too low (${COMPATIBILITY_SCORE:-0}/10) for reliable operation"
        fi
    else
        error "Hardware detection did not produce results"
    fi

    success "Hardware detection completed"
}

step2_generate_router_credentials() {
    if [[ "$SKIP_ROUTER" == true ]]; then
        log "=== STEP 2: Skipping Router Credentials (--skip-router) ==="
        return
    fi

    log "=== STEP 2: Generate Router Credentials ==="

    # Check if credentials already exist and are recent
    if [[ -f "$PROJECT_DIR/router-credentials.env" ]] && [[ "$FORCE_REBUILD" == false ]]; then
        log "Router credentials already exist - using existing"
        source "$PROJECT_DIR/router-credentials.env"
        log "Router user: $ROUTER_USER"
        return
    fi

    ROUTER_USER="${USER:-traum}"
    log "Router user: $ROUTER_USER"

    # Generate secure password
    ROUTER_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
    log "Generated router password: $ROUTER_PASSWORD"

    # Check for SSH key
    SSH_KEY_CONTENT=""
    SSH_PASSWORD_AUTH="true"
    if [[ -f "$HOME/.ssh/id_rsa.pub" ]] || [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        SSH_KEY_PATH=$(find "$HOME/.ssh" -name "*.pub" -type f | head -1)
        SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH")
        SSH_PASSWORD_AUTH="false"
        log "Found SSH key: $SSH_KEY_PATH"
    else
        log "No SSH key found, using password auth"
    fi

    # Save credentials
    cat > "$PROJECT_DIR/router-credentials.env" << EOF
ROUTER_USER=$ROUTER_USER
ROUTER_PASSWORD=$ROUTER_PASSWORD
SSH_KEY_CONTENT=$SSH_KEY_CONTENT
SSH_PASSWORD_AUTH=$SSH_PASSWORD_AUTH
EOF

    chmod 600 "$PROJECT_DIR/router-credentials.env"
    success "Router credentials generated"
}

step3_build_router_vm() {
    if [[ "$SKIP_ROUTER" == true ]]; then
        ROUTER_SKIP_MSG="[!] Router VM: Skipped (--skip-router)"
        return
    fi

    log "=== STEP 3: Build Router VM ==="

    cd "$PROJECT_DIR"

    # Check if router VM already built
    if [[ "$FORCE_REBUILD" == false ]] && [[ -f "router-vm-result/nixos.qcow2" ]]; then
        log "Router VM already built - using existing"
        ROUTER_SIZE=$(du -h router-vm-result/nixos.qcow2 | cut -f1)
        ROUTER_BUILD_MSG="[+] Router VM: Using existing build (${ROUTER_SIZE})"
        return
    fi

    log "Building router VM with dynamic WiFi detection..."

    # Load hardware and credentials
    source "$PROJECT_DIR/hardware-results.env"
    source "$PROJECT_DIR/router-credentials.env"

    # Create router VM config with template
    local router_config="$ROUTER_MODULE_DIR/router-vm-config.nix"
    log "Templating router VM configuration..."

    cat > "$router_config" << 'ROUTEREOF'
{ config, lib, pkgs, modulesPath, ... }:
{
  nixpkgs.config.allowUnfree = true;

  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi"
  ];

  boot.kernelParams = [
    "console=tty1"
    "console=ttyS0,115200n8"
  ];

  system.stateVersion = "25.05";

  networking = {
    hostName = "router-vm";
    useDHCP = false;
    enableIPv6 = false;

    networkmanager.enable = true;
    wireless.enable = false;

    # Management bridge interface
    interfaces.enp1s0 = {
      ipv4.addresses = [{
        address = "192.168.100.253";
        prefixLength = 24;
      }];
    };

    # Guest network interfaces
    interfaces.enp2s0 = {
      ipv4.addresses = [{
        address = "192.168.101.253";
        prefixLength = 24;
      }];
    };

    interfaces.enp3s0 = {
      ipv4.addresses = [{
        address = "192.168.102.253";
        prefixLength = 24;
      }];
    };

    interfaces.enp4s0 = {
      ipv4.addresses = [{
        address = "192.168.103.253";
        prefixLength = 24;
      }];
    };

    interfaces.enp5s0 = {
      ipv4.addresses = [{
        address = "192.168.104.253";
        prefixLength = 24;
      }];
    };

    nat = {
      enable = true;
      externalInterface = "";
      internalInterfaces = [ "enp1s0" "enp2s0" "enp3s0" "enp4s0" "enp5s0" ];
    };

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 67 68 ];
    };
  };

  # Dynamic WiFi interface detection and NAT configuration
  systemd.services.wifi-detect-and-configure = {
    description = "Detect WiFi interface and configure NAT";
    after = [ "network.target" ];
    before = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      WIFI_IFACE=$(ls /sys/class/net/ | grep -E '^wl' | head -1)
      if [ -z "$WIFI_IFACE" ]; then
        echo "ERROR: No WiFi interface found!"
        exit 1
      fi
      echo "Found WiFi interface: $WIFI_IFACE"

      ${pkgs.iptables}/bin/iptables -t nat -F POSTROUTING
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.101.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.102.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.103.0/24 -o "$WIFI_IFACE" -j MASQUERADE
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.104.0/24 -o "$WIFI_IFACE" -j MASQUERADE

      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp1s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp2s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp3s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp4s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i enp5s0 -o "$WIFI_IFACE" -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp1s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp2s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp3s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp4s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$WIFI_IFACE" -o enp5s0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    '';
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;

  environment.systemPackages = with pkgs; [
    pciutils usbutils iw wirelesstools networkmanager
    dhcpcd iptables bridge-utils tcpdump nettools nano
    dnsmasq
  ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  services.dnsmasq = {
    enable = true;
    settings = {
      interface = ["enp2s0" "enp3s0" "enp4s0" "enp5s0"];
      dhcp-range = [
        "enp2s0,192.168.101.10,192.168.101.100,24h"
        "enp3s0,192.168.102.10,192.168.102.100,24h"
        "enp4s0,192.168.103.10,192.168.103.100,24h"
        "enp5s0,192.168.104.10,192.168.104.100,24h"
      ];
      dhcp-option = [
        "enp2s0,option:router,192.168.101.253"
        "enp2s0,option:dns-server,192.168.101.253"
        "enp3s0,option:router,192.168.102.253"
        "enp3s0,option:dns-server,192.168.102.253"
        "enp4s0,option:router,192.168.103.253"
        "enp4s0,option:dns-server,192.168.103.253"
        "enp5s0,option:router,192.168.104.253"
        "enp5s0,option:dns-server,192.168.104.253"
      ];
      server = ["8.8.8.8" "1.1.1.1"];
      bind-interfaces = true;
      log-dhcp = true;
      log-queries = true;
    };
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = __SSH_PASSWORD_AUTH__;
  };

  services.getty.autologinUser = "__ROUTER_USER__";

  users.users.__ROUTER_USER__ = {
    isNormalUser = true;
    password = "__ROUTER_PASSWORD__";
    extraGroups = [ "wheel" "networkmanager" ];
    __SSH_KEYS__
  };
}
ROUTEREOF

    # Perform substitutions
    sed -i "s|__SSH_PASSWORD_AUTH__|$SSH_PASSWORD_AUTH|g" "$router_config"
    sed -i "s|__ROUTER_USER__|$ROUTER_USER|g" "$router_config"
    sed -i "s|__ROUTER_PASSWORD__|$ROUTER_PASSWORD|g" "$router_config"

    # Handle SSH keys with proper escaping
    if [[ -n "$SSH_KEY_CONTENT" ]]; then
        SSH_KEY_ESCAPED=$(echo "$SSH_KEY_CONTENT" | sed 's/[\/&]/\\&/g')
        sed -i "s|__SSH_KEYS__|openssh.authorizedKeys.keys = [ \"$SSH_KEY_ESCAPED\" ];|" "$router_config"
    else
        sed -i "s|__SSH_KEYS__|# No SSH keys configured|" "$router_config"
    fi

    log "Router config templated successfully"

    # Build router VM with dedicated output link
    log "Building router VM qcow2..."
    if ! nix build .#router-vm --out-link router-vm-result --print-build-logs; then
        error "Router VM build failed"
    fi

    if [[ -f "router-vm-result/nixos.qcow2" ]]; then
        ROUTER_SIZE=$(du -h router-vm-result/nixos.qcow2 | cut -f1)
        ROUTER_BUILD_MSG="[+] Router VM: Built successfully (${ROUTER_SIZE})"
        log "Router VM built: $ROUTER_SIZE"
    else
        error "Router VM build failed - no qcow2 found"
    fi

    success "Router VM build completed"
}

step4_generate_consolidated_config() {
    log "=== STEP 4: Generate CONSOLIDATED Configuration ==="

    source "$PROJECT_DIR/hardware-results.env"

    mkdir -p "$GENERATED_DIR/modules"

    local output_file="$GENERATED_DIR/modules/${MACHINE_NAME}-consolidated.nix"
    local vm_image_path="$PROJECT_DIR/base-image-result/nixos.qcow2"
    local username="${USER:-$(whoami)}"

    log "Generating SINGLE consolidated module..."
    log "  Machine: $MACHINE_NAME"
    log "  VM Name: $VM_NAME"
    log "  Hardware: $PRIMARY_ID ($PRIMARY_PCI)"
    log "  Driver: $PRIMARY_DRIVER"
    log ""
    log "This ONE file will contain:"
    log "  [+] VFIO/Hardware passthrough (conditional - only in router/maximalism modes)"
    log "  [+] Router specialization (router VM + networking)"
    log "  [+] Maximalism specialization (router + pentest VMs)"
    log "  [+] Status commands for all modes"
    log "  [+] Base mode: Normal network operation (VFIO disabled)"

    # Generate consolidated module directly (embedded template)
    cat > "$output_file" << CONSOLIDATEDEOF
# Consolidated Machine Configuration for ${MACHINE_NAME}
# Generated by machine-kickstart-v2.sh on $(date)
# Contains: Conditional VFIO passthrough + Router services + Maximalism specialization
# Hardware: ${PRIMARY_ID} (${PRIMARY_PCI})
# Base mode: Normal WiFi/network operation (VFIO disabled)
# Router/Maximalism modes: VFIO passthrough enabled for VM isolation

{ config, lib, pkgs, ... }:
let
  # Detect if we're in router or maximalism mode
  isRouterMode = config.system.nixos.label == "router-setup" || config.system.nixos.label == "maximalism-setup";
in
{
  # ===== VFIO PASSTHROUGH CONFIGURATION (Conditional - only for router/maximalism) =====
  boot.kernelParams = lib.mkIf isRouterMode [
    "intel_iommu=on"
    "iommu=pt"
    "vfio-pci.ids=${PRIMARY_ID}"
  ];

  boot.kernelModules = lib.mkIf isRouterMode [ "vfio" "vfio_iommu_type1" "vfio_pci" ];

  # Enable libvirtd (always available for VM management, but VFIO only in router modes)
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = lib.mkForce pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
  };

  # ===== ROUTER SPECIALIZATION =====
  specialisation.router.configuration = {
    system.nixos.label = lib.mkForce "router-setup";

    # Router mode: WiFi blacklisted for passthrough
    boot.blacklistedKernelModules = [ "${PRIMARY_DRIVER}" ];

    # Router networking bridges
    networking.bridges.virbr1.interfaces = [];
    networking.interfaces.virbr1 = {
      ipv4.addresses = [{
        address = "192.168.100.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr2.interfaces = [];
    networking.interfaces.virbr2 = {
      ipv4.addresses = [{
        address = "192.168.101.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr3.interfaces = [];
    networking.interfaces.virbr3 = {
      ipv4.addresses = [{
        address = "192.168.102.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr4.interfaces = [];
    networking.interfaces.virbr4 = {
      ipv4.addresses = [{
        address = "192.168.103.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr5.interfaces = [];
    networking.interfaces.virbr5 = {
      ipv4.addresses = [{
        address = "192.168.104.1";
        prefixLength = 24;
      }];
    };

    # Default route through router VM
    networking.defaultGateway = {
      address = "192.168.100.253";
      interface = "virbr1";
    };

    # Firewall rules for bridge networking
    networking.firewall = {
      extraCommands = ''
        # Management bridge (virbr1)
        iptables -A FORWARD -i virbr1 -j ACCEPT
        iptables -A FORWARD -o virbr1 -j ACCEPT
        iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j MASQUERADE

        # VM network bridges (virbr2-virbr5)
        iptables -A FORWARD -i virbr2 -j ACCEPT
        iptables -A FORWARD -o virbr2 -j ACCEPT
        iptables -A FORWARD -i virbr3 -j ACCEPT
        iptables -A FORWARD -o virbr3 -j ACCEPT
        iptables -A FORWARD -i virbr4 -j ACCEPT
        iptables -A FORWARD -o virbr4 -j ACCEPT
        iptables -A FORWARD -i virbr5 -j ACCEPT
        iptables -A FORWARD -o virbr5 -j ACCEPT

        # Allow inter-bridge communication through router VM
        iptables -A FORWARD -i virbr2 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr2 -j ACCEPT
        iptables -A FORWARD -i virbr3 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr3 -j ACCEPT
        iptables -A FORWARD -i virbr4 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr4 -j ACCEPT
        iptables -A FORWARD -i virbr5 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr5 -j ACCEPT
      '';
      trustedInterfaces = [ "virbr1" "virbr2" "virbr3" "virbr4" "virbr5" ];
    };

    # Router VM autostart service
    systemd.services.router-vm-autostart = {
      description = "Auto-start router VM with WiFi passthrough";
      after = [
        "libvirtd.service"
        "network.target"
        "network-online.target"
      ];
      wants = [ "libvirtd.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/home/${username}/Hydrix/generated/scripts/autostart-router-vm.sh";
        RemainAfterExit = true;
        User = "root";
        TimeoutStartSec = "120s";
        Environment = "PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin";
      };
    };

    # Router status command
    environment.systemPackages = with pkgs; lib.mkAfter [
      virt-manager
      (writeShellScriptBin "router-status" ''
        echo "ROUTER MODE Status"
        echo "=================="
        echo ""

        echo "Router VM Status:"
        sudo virsh list --all | grep router || echo "Router VM not found"
        echo ""

        echo "Network Status:"
        echo "  Router Bridge: \$(ip link show virbr1 2>/dev/null | grep -o 'state [A-Z]*' || echo 'DOWN')"
        echo "  Default Route: \$(ip route | grep default | awk '{print \$5}' | head -1 || echo 'unknown')"
        echo ""

        echo "Hardware Status:"
        echo "  WiFi Blacklisted: \$(lsmod | grep ${PRIMARY_DRIVER} > /dev/null && echo 'NO (loaded)' || echo 'YES (blacklisted)')"
        echo "  PCI Device: ${PRIMARY_PCI} (${PRIMARY_ID})"
        echo ""

        echo "Quick Actions:"
        echo "  Router Console: sudo virsh console router-vm-passthrough"
        echo "  VM Manager:     virt-manager"
        echo "  Switch to base: sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME}"
      '')
    ];
  };

  # ===== MAXIMALISM SPECIALIZATION =====
  specialisation.maximalism.configuration = {
    system.nixos.label = lib.mkForce "maximalism-setup";

    # Router configuration (inherited from router specialization)
    boot.blacklistedKernelModules = [ "${PRIMARY_DRIVER}" ];

    # Router networking bridges (duplicated for maximalism)
    networking.bridges.virbr1.interfaces = [];
    networking.interfaces.virbr1 = {
      ipv4.addresses = [{
        address = "192.168.100.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr2.interfaces = [];
    networking.interfaces.virbr2 = {
      ipv4.addresses = [{
        address = "192.168.101.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr3.interfaces = [];
    networking.interfaces.virbr3 = {
      ipv4.addresses = [{
        address = "192.168.102.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr4.interfaces = [];
    networking.interfaces.virbr4 = {
      ipv4.addresses = [{
        address = "192.168.103.1";
        prefixLength = 24;
      }];
    };

    networking.bridges.virbr5.interfaces = [];
    networking.interfaces.virbr5 = {
      ipv4.addresses = [{
        address = "192.168.104.1";
        prefixLength = 24;
      }];
    };

    # Default route through router VM
    networking.defaultGateway = {
      address = "192.168.100.253";
      interface = "virbr1";
    };

    # Firewall rules for bridge networking (duplicated)
    networking.firewall = {
      extraCommands = ''
        # Management bridge (virbr1)
        iptables -A FORWARD -i virbr1 -j ACCEPT
        iptables -A FORWARD -o virbr1 -j ACCEPT
        iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j MASQUERADE

        # VM network bridges (virbr2-virbr5)
        iptables -A FORWARD -i virbr2 -j ACCEPT
        iptables -A FORWARD -o virbr2 -j ACCEPT
        iptables -A FORWARD -i virbr3 -j ACCEPT
        iptables -A FORWARD -o virbr3 -j ACCEPT
        iptables -A FORWARD -i virbr4 -j ACCEPT
        iptables -A FORWARD -o virbr4 -j ACCEPT
        iptables -A FORWARD -i virbr5 -j ACCEPT
        iptables -A FORWARD -o virbr5 -j ACCEPT

        # Allow inter-bridge communication
        iptables -A FORWARD -i virbr2 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr2 -j ACCEPT
        iptables -A FORWARD -i virbr3 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr3 -j ACCEPT
        iptables -A FORWARD -i virbr4 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr4 -j ACCEPT
        iptables -A FORWARD -i virbr5 -o virbr1 -j ACCEPT
        iptables -A FORWARD -i virbr1 -o virbr5 -j ACCEPT
      '';
      trustedInterfaces = [ "virbr1" "virbr2" "virbr3" "virbr4" "virbr5" ];
    };

    # Router VM autostart service (from router specialization)
    systemd.services.router-vm-autostart = {
      description = "Auto-start router VM with WiFi passthrough";
      after = [
        "libvirtd.service"
        "network.target"
        "network-online.target"
      ];
      wants = [ "libvirtd.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/home/${username}/Hydrix/generated/scripts/autostart-router-vm.sh";
        RemainAfterExit = true;
        User = "root";
        TimeoutStartSec = "120s";
        Environment = "PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin";
      };
    };

    # Pentest VM autostart service (in addition to router)
    systemd.services.${VM_NAME}-autostart = {
      description = "Auto-start ${VM_NAME} pentest VM";
      after = [
        "router-vm-autostart.service"
        "libvirtd.service"
        "network.target"
        "network-online.target"
      ];
      wants = [ "router-vm-autostart.service" "libvirtd.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        TimeoutStartSec = "120s";
        Environment = "PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin";
      };

      script = ''
        log() { echo "[\$(date +%H:%M:%S)] Pentest VM Autostart: \$*"; }

        VIRSH="/run/current-system/sw/bin/virsh"
        SYSTEMCTL="/run/current-system/sw/bin/systemctl"

        log "Starting ${VM_NAME} autostart process..."

        # Wait for router VM to be ready
        log "Waiting for router VM to be ready..."
        sleep 10

        # Ensure pentest VM image exists
        PENTEST_IMAGE_PATH="${vm_image_path}"
        TARGET_IMAGE="/var/lib/libvirt/images/${VM_NAME}.qcow2"

        if [[ -f "\$PENTEST_IMAGE_PATH" && ! -f "\$TARGET_IMAGE" ]]; then
          log "Copying pentest VM image to libvirt images directory..."
          sudo mkdir -p /var/lib/libvirt/images
          sudo cp "\$PENTEST_IMAGE_PATH" "\$TARGET_IMAGE"
          if id "libvirt-qemu" >/dev/null 2>&1; then
            sudo chown libvirt-qemu:kvm "\$TARGET_IMAGE"
          else
            sudo chmod 644 "\$TARGET_IMAGE"
          fi
          log "Pentest VM image copied successfully"
        fi

        # Check if libvirtd is running
        if ! \$SYSTEMCTL is-active --quiet libvirtd; then
          log "Starting libvirtd service..."
          \$SYSTEMCTL start libvirtd
          sleep 3
        fi

        sleep 2

        # Check if VM exists
        if ! \$VIRSH --connect qemu:///system list --all | grep -q "${VM_NAME}"; then
          log "ERROR: Pentest VM '${VM_NAME}' not found"
          log "Please ensure the VM is properly deployed"
          exit 1
        fi

        # Check and start VM
        vm_state=\$(\$VIRSH --connect qemu:///system list --all | grep "${VM_NAME}" | awk '{print \$3}' || echo "unknown")
        log "Pentest VM current state: \$vm_state"

        case "\$vm_state" in
          "running")
            log "${VM_NAME} is already running"
            ;;
          "paused")
            log "${VM_NAME} is paused, resuming..."
            if \$VIRSH --connect qemu:///system resume "${VM_NAME}" 2>&1; then
              log "${VM_NAME} resumed successfully"
              sleep 2
            else
              # Check if VM is actually running (race condition)
              sleep 1
              current_state=\$(\$VIRSH --connect qemu:///system domstate "${VM_NAME}" || echo "unknown")
              if [ "\$current_state" = "running" ]; then
                log "${VM_NAME} transitioned to running state (race condition handled)"
              else
                log "ERROR: Failed to resume ${VM_NAME} (current state: \$current_state)"
                exit 1
              fi
            fi
            ;;
          "shut"|"shutoff")
            log "Starting ${VM_NAME}..."
            if \$VIRSH --connect qemu:///system start "${VM_NAME}" 2>&1; then
              log "${VM_NAME} started successfully"
              sleep 2
            else
              # Check if VM is actually running (race condition)
              sleep 1
              current_state=\$(\$VIRSH --connect qemu:///system domstate "${VM_NAME}" || echo "unknown")
              if [ "\$current_state" = "running" ]; then
                log "${VM_NAME} transitioned to running state (race condition handled)"
              else
                log "ERROR: Failed to start ${VM_NAME} (current state: \$current_state)"
                exit 1
              fi
            fi
            ;;
          *)
            log "${VM_NAME} in unexpected state: \$vm_state"
            log "Attempting to start anyway..."
            if \$VIRSH --connect qemu:///system start "${VM_NAME}" 2>&1; then
              log "${VM_NAME} started despite unexpected state"
              sleep 2
            else
              # Check if VM is actually running (race condition)
              sleep 1
              current_state=\$(\$VIRSH --connect qemu:///system domstate "${VM_NAME}" || echo "unknown")
              if [ "\$current_state" = "running" ]; then
                log "${VM_NAME} transitioned to running state (race condition handled)"
              else
                log "ERROR: Failed to start ${VM_NAME} (current state: \$current_state)"
                exit 1
              fi
            fi
            ;;
        esac

        # Verification
        if \$VIRSH --connect qemu:///system list | grep -q "${VM_NAME}.*running"; then
          log " [+] ${VM_NAME} is running and ready"
          log " [+] Router VM also running for network isolation"
        else
          log " [!] ${VM_NAME} startup verification failed"
          exit 1
        fi

        log "${VM_NAME} autostart completed successfully"
      '';
    };

    # Enhanced status command for maximalism mode
    environment.systemPackages = with pkgs; lib.mkAfter [
      virt-manager

      (writeShellScriptBin "maximalism-status" ''
        echo "MAXIMALISM MODE Status"
        echo "======================"
        echo ""

        echo "Router VM Status:"
        sudo virsh list --all | grep router || echo "Router VM not found"
        echo ""

        echo "Pentest VM (${VM_NAME}) Status:"
        sudo virsh list --all | grep "${VM_NAME}" || echo "${VM_NAME} not found"
        echo ""

        echo "Network Status:"
        echo "  Router Bridge: \$(ip link show virbr1 2>/dev/null | grep -o 'state [A-Z]*' || echo 'DOWN')"
        echo "  Default Route: \$(ip route | grep default | awk '{print \$5}' | head -1 || echo 'unknown')"
        echo ""

        echo "Quick Actions:"
        echo "  Start ${VM_NAME}:         sudo virsh start ${VM_NAME}"
        echo "  Stop ${VM_NAME}:          sudo virsh shutdown ${VM_NAME}"
        echo "  Router Console:           sudo virsh console router-vm-passthrough"
        echo "  ${VM_NAME} Console:       sudo virsh console ${VM_NAME}"
        echo "  VM Manager:               virt-manager"
        echo "  Switch to router:         sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME} --specialisation router"
        echo "  Switch to base:           sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME}"
      '')
    ];
  };

  # ===== BASE CONFIGURATION (Always Enabled) =====
  environment.systemPackages = with pkgs; lib.mkAfter [
    virt-manager
    virt-viewer
    libvirt
    qemu
    OVMF
    spice-gtk

    # Status command for current mode detection
    (writeShellScriptBin "vm-status" ''
      echo "${MACHINE_NAME} VM Status"
      echo "======================"
      echo ""

      # Detect current specialisation
      if [[ -L /run/current-system/specialisation ]]; then
        ACTIVE_SPEC=\$(readlink /run/current-system/specialisation | xargs basename 2>/dev/null || echo "none")
        echo "Current Mode: \$ACTIVE_SPEC"
      else
        echo "Current Mode: base (no specialisation active)"
      fi
      echo ""

      echo "Available Specialisations:"
      echo "  base        - Normal laptop mode (WiFi enabled)"
      echo "  router      - Router VM only (WiFi passthrough)"
      echo "  maximalism  - Router + Pentest VMs (full setup)"
      echo ""

      echo "Quick Switch Commands:"
      echo "  sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME}"
      echo "  sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME} --specialisation router"
      echo "  sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME} --specialisation maximalism"
      echo ""

      # Show running VMs regardless of mode
      echo "Currently Running VMs:"
      sudo virsh list --name 2>/dev/null | grep -v '^\$' || echo "  No VMs running"
    '')
  ];
}
CONSOLIDATEDEOF

    success "[+] CONSOLIDATED CONFIGURATION GENERATED!"
    log ""
    log "Generated SINGLE module: $output_file"
    log ""
    log "This ONE file contains:"
    log "  [+] VFIO/Hardware passthrough (conditional - only in router/maximalism modes)"
    log "  [+] Router specialization (router VM + networking)"
    log "  [+] Maximalism specialization (router + pentest VMs)"
    log "  [+] Status commands for all modes"
    log "  [+] Base mode: Normal network operation (VFIO disabled)"
    log ""
    log "Simply import: ./router-generated/${MACHINE_NAME}-consolidated.nix"
}

step5_build_pentest_vm() {
    if [[ "$SKIP_PENTEST" == true ]]; then
        PENTEST_SKIP_MSG="[!] Pentest VM: Skipped (--skip-pentest)"
        return
    fi

    log "=== STEP 5: Build Pentest VM ==="

    cd "$PROJECT_DIR"

    local pentest_vm_result="base-image-result/nixos.qcow2"

    if [[ "$FORCE_REBUILD" == false ]] && [[ -f "$pentest_vm_result" ]]; then
        log "Pentest VM base already built - using existing"
        PENTEST_SIZE=$(du -h "$pentest_vm_result" | cut -f1)
        PENTEST_BUILD_MSG="[+] Pentest VM Base: Using existing build (${PENTEST_SIZE})"
        return
    fi

    log "Building pentest VM base (minimal image with shaping service)..."

    if ! nix build .#pentest-vm-base --out-link base-image-result --print-build-logs; then
        error "Pentest VM base build failed"
    fi

    if [[ -f "$pentest_vm_result" ]]; then
        PENTEST_SIZE=$(du -h "$pentest_vm_result" | cut -f1)
        PENTEST_BUILD_MSG="[+] Pentest VM Base: Built successfully (${PENTEST_SIZE})"
        log "Pentest VM base built: $PENTEST_SIZE"
    else
        error "Pentest VM base build failed - no qcow2 found at $pentest_vm_result"
    fi

    success "Pentest VM build completed"
}

show_build_summary() {
    log ""
    success " VM BUILD SUMMARY "
    log "======================"
    log ""
    log "${ROUTER_BUILD_MSG:-[!] Router VM: Not built}"
    log "${ROUTER_SKIP_MSG:-}"
    log ""
    log "${PENTEST_BUILD_MSG:-[!] Pentest VM: Not built}"
    log "${PENTEST_SKIP_MSG:-}"
    log ""

    if [[ -n "${ROUTER_SIZE:-}" && -n "${PENTEST_SIZE:-}" ]]; then
        local router_gb=$(echo "${ROUTER_SIZE}" | sed 's/G$//' | cut -d'.' -f1)
        local pentest_gb=$(echo "${PENTEST_SIZE}" | sed 's/G$//' | cut -d'.' -f1)
        if [[ "$router_gb" =~ ^[0-9]+$ ]] && [[ "$pentest_gb" =~ ^[0-9]+$ ]]; then
            local total_size=$((router_gb + pentest_gb))
            log " Total VM storage: ~${total_size}GB (${ROUTER_SIZE} + ${PENTEST_SIZE})"
        fi
    fi
    log ""
}

step6_create_machine_profile() {
    log "=== STEP 6: Create Machine Profile ==="

    local profile_path="$PROJECT_DIR/profiles/machines/${MACHINE_NAME}.nix"

    if [[ -f "$profile_path" ]]; then
        log "Machine profile already exists: $profile_path"
        return
    fi

    mkdir -p "$PROJECT_DIR/profiles/machines"

    log "Creating machine profile: ${MACHINE_NAME}.nix"

    cat > "$profile_path" << PROFILEEOF
# ${MACHINE_NAME} - Machine-specific configuration
# Auto-generated by setup.sh on $(date)

{ config, lib, pkgs, ... }:

{
  # Import router-generated consolidated configuration
  # This contains VFIO passthrough, router specialisation, and maximalism specialisation
  imports = [
    ../../generated/modules/${MACHINE_NAME}-consolidated.nix
  ];

  # Machine-specific settings can be added here
  # Examples:
  # - NVIDIA/AMD GPU configuration
  # - ASUS-specific tools (asusctl, supergfxctl)
  # - Power management tuning
  # - Display scaling
}
PROFILEEOF

    success "Machine profile created: $profile_path"
}

step7_update_flake() {
    log "=== STEP 7: Update Flake Configuration ==="

    local flake_path="$PROJECT_DIR/flake.nix"

    # Check if machine configuration already exists in flake
    if grep -q "^      ${MACHINE_NAME} = " "$flake_path"; then
        log "Machine configuration already exists in flake.nix"
        return
    fi

    log "Adding ${MACHINE_NAME} configuration to flake.nix"

    # Find the line with "zephyrus = nixpkgs.lib.nixosSystem" and add new config before it
    # We'll insert after the "nixosConfigurations = {" line

    local temp_file=$(mktemp)
    local added=false

    while IFS= read -r line; do
        echo "$line" >> "$temp_file"

        # After "nixosConfigurations = {", add the new machine config
        if [[ "$line" =~ "nixosConfigurations = {" ]] && [[ "$added" == false ]]; then
            cat >> "$temp_file" << FLAKEEOF

      # ${MACHINE_NAME} - Auto-generated configuration
      # Build with: sudo nixos-rebuild switch --flake .#${MACHINE_NAME} --impure
      ${MACHINE_NAME} = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index

          # Base system configuration
          ./modules/base/configuration.nix
          ./modules/base/hardware-config.nix

          # Machine-specific configuration (imports generated consolidated module)
          ./profiles/machines/${MACHINE_NAME}.nix

          # Core functionality modules (matching dotfiles exactly)
          ./modules/wm/i3.nix
          ./modules/shell/packages.nix
          ./modules/base/services.nix
          ./modules/base/users.nix
          ./modules/theming/colors.nix
          ./modules/base/virt.nix
          ./modules/base/audio.nix
        ];
      };
FLAKEEOF
            added=true
        fi
    done < "$flake_path"

    if [[ "$added" == true ]]; then
        mv "$temp_file" "$flake_path"
        success "Flake configuration updated with ${MACHINE_NAME}"
    else
        rm "$temp_file"
        log "Could not find insertion point in flake.nix - manual update required"
    fi
}

step8_generate_deployment_scripts() {
    if [[ "$SKIP_ROUTER" == true ]]; then
        log "=== STEP 8: Skipping Deployment Scripts (--skip-router) ==="
        return
    fi

    log "=== STEP 8: Generate Deployment Scripts ==="

    source "$PROJECT_DIR/hardware-results.env"

    mkdir -p "$GENERATED_DIR/scripts"

    # Generate router autostart script
    cat > "$GENERATED_DIR/scripts/autostart-router-vm.sh" << 'AUTOSTARTEOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly VM_NAME="router-vm-passthrough"
log() { echo "[$(date +%H:%M:%S)] Router Autostart: $*"; }

VIRSH="/run/current-system/sw/bin/virsh"
SYSTEMCTL="/run/current-system/sw/bin/systemctl"

log "Starting router VM autostart process..."

if ! $SYSTEMCTL is-active --quiet libvirtd; then
    log "Starting libvirtd service..."
    $SYSTEMCTL start libvirtd
    sleep 3
fi

sleep 2

if ! $VIRSH --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    log "ERROR: Router VM '$VM_NAME' not found"
    log "Please run deploy-router-vm.sh first"
    exit 1
fi

vm_state=$($VIRSH --connect qemu:///system list --all | grep "$VM_NAME" | awk '{print $3}' || echo "unknown")
log "Router VM current state: $vm_state"

case "$vm_state" in
    "running")
        log "Router VM is already running"
        ;;
    "paused")
        log "Router VM is paused, resuming..."
        if $VIRSH --connect qemu:///system resume "$VM_NAME" 2>&1; then
            log "Router VM resumed successfully"
            sleep 2
        else
            # Check if VM is actually running (race condition)
            sleep 1
            current_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" || echo "unknown")
            if [ "$current_state" = "running" ]; then
                log "Router VM transitioned to running state (race condition handled)"
            else
                log "ERROR: Failed to resume router VM (current state: $current_state)"
                exit 1
            fi
        fi
        ;;
    "shut"|"shutoff")
        log "Starting router VM..."
        if $VIRSH --connect qemu:///system start "$VM_NAME" 2>&1; then
            log "Router VM started successfully"
            sleep 2
        else
            # Check if VM is actually running (race condition)
            sleep 1
            current_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" || echo "unknown")
            if [ "$current_state" = "running" ]; then
                log "Router VM transitioned to running state (race condition handled)"
            else
                log "ERROR: Failed to start router VM (current state: $current_state)"
                exit 1
            fi
        fi
        ;;
    *)
        log "Router VM in unexpected state: $vm_state"
        log "Attempting to start anyway..."
        if $VIRSH --connect qemu:///system start "$VM_NAME" 2>&1; then
            log "Router VM started despite unexpected state"
            sleep 2
        else
            # Check if VM is actually running (race condition)
            sleep 1
            current_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" || echo "unknown")
            if [ "$current_state" = "running" ]; then
                log "Router VM transitioned to running state (race condition handled)"
            else
                log "ERROR: Failed to start router VM (current state: $current_state)"
                exit 1
            fi
        fi
        ;;
esac

if $VIRSH --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
    log "[+] Router VM is running and ready"
    log "[+] Management interface: 192.168.100.253"
else
    log "[!] Router VM startup verification failed"
    exit 1
fi

log "Router VM autostart completed successfully"
AUTOSTARTEOF

    chmod +x "$GENERATED_DIR/scripts/autostart-router-vm.sh"

    success "Deployment scripts generated"
}

step9_git_stage_files() {
    log "=== STEP 9: Stage Generated Files in Git ==="

    cd "$PROJECT_DIR"

    local files_to_add=(
        ".gitignore"
        "generated/modules/${MACHINE_NAME}-consolidated.nix"
        "profiles/machines/${MACHINE_NAME}.nix"
        "generated/scripts/autostart-router-vm.sh"
        "flake.nix"
        # Note: credentials and hardware results are gitignored for security
    )

    log "Staging generated files..."
    for file in "${files_to_add[@]}"; do
        if [[ -f "$file" ]]; then
            git add "$file" 2>/dev/null && log "  [+] $file" || log "  [!] $file (not in repo or already staged)"
        fi
    done

    success "Generated files staged in git"
}

step10_deploy_router_vm() {
    if [[ "$SKIP_ROUTER" == true ]]; then
        log "=== STEP 10: Skipping Router VM Deployment ==="
        return
    fi

    log "=== STEP 10: Deploy Router VM ==="

    # Check if bridge interfaces exist (only available in router/maximalism mode)
    if ! ip link show virbr1 &>/dev/null; then
        log "Bridge interfaces not found - system not in router/maximalism mode"
        log "Skipping VM deployment - will happen automatically after rebuild"
        return
    fi

    if sudo virsh --connect qemu:///system list --all | grep -q "router-vm-passthrough"; then
        if [[ "$FORCE_REBUILD" == false ]]; then
            log "Router VM already deployed - skipping"
            success "Using existing router VM"
            return
        else
            log "Force rebuild - removing existing router VM"
            sudo virsh --connect qemu:///system destroy router-vm-passthrough 2>/dev/null || true
            sudo virsh --connect qemu:///system undefine router-vm-passthrough --nvram 2>/dev/null || true
        fi
    fi

    local router_image="$PROJECT_DIR/router-vm-result/nixos.qcow2"
    if [[ ! -f "$router_image" ]]; then
        error "Router VM image not found: $router_image"
    fi

    source "$PROJECT_DIR/hardware-results.env"

    local vm_name="router-vm-passthrough"
    local target_image="/var/lib/libvirt/images/$vm_name.qcow2"

    log "Deploying router VM with WiFi passthrough..."

    sudo mkdir -p /var/lib/libvirt/images
    sudo cp "$router_image" "$target_image"

    if id "libvirt-qemu" >/dev/null 2>&1; then
        sudo chown libvirt-qemu:kvm "$target_image"
    else
        sudo chmod 644 "$target_image"
    fi

    log "Creating router VM with WiFi passthrough (PCI: $PRIMARY_PCI)..."
    sudo virt-install \
        --connect qemu:///system \
        --name="$vm_name" \
        --memory=2048 \
        --vcpus=2 \
        --disk "$target_image,device=disk,bus=virtio" \
        --os-variant=nixos-unstable \
        --boot=hd \
        --nographics \
        --network bridge=virbr1,model=virtio \
        --network bridge=virbr2,model=virtio \
        --network bridge=virbr3,model=virtio \
        --network bridge=virbr4,model=virtio \
        --network bridge=virbr5,model=virtio \
        --hostdev "pci_${PRIMARY_PCI//:/_}" \
        --noautoconsole \
        --import

    success "Router VM deployment completed"
}

step11_deploy_pentest_vm() {
    if [[ "$SKIP_PENTEST" == true ]]; then
        log "=== STEP 11: Skipping Pentest VM Deployment ==="
        return
    fi

    log "=== STEP 11: Deploy Pentest VM ==="

    # Check if bridge interfaces exist (only available in maximalism mode)
    if ! ip link show virbr1 &>/dev/null; then
        log "Bridge interfaces not found - system not in maximalism mode"
        log "Skipping VM deployment - will happen automatically after rebuild"
        return
    fi

    if sudo virsh --connect qemu:///system list --all | grep -q "\\b$VM_NAME\\b"; then
        if [[ "$FORCE_REBUILD" == false ]]; then
            log "Pentest VM already deployed - skipping"
            success "Using existing pentest VM"
            return
        else
            log "Force rebuild - removing existing pentest VM"
            sudo virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
            sudo virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
        fi
    fi

    local pentest_image="$PROJECT_DIR/base-image-result/nixos.qcow2"
    if [[ ! -f "$pentest_image" ]]; then
        error "Pentest VM image not found at: $pentest_image"
    fi

    log "Deploying pentest VM with auto-allocation..."
    if ! ./scripts/deploy-pentest-vm-auto.sh --name "$VM_NAME" --image "$pentest_image" --50; then
        error "Pentest VM deployment failed"
    fi

    success "Pentest VM deployment completed"
}

show_completion_summary() {
    log ""
    success " MACHINE SETUP COMPLETED! "
    log "=========================="
    log ""
    log "Configuration:"
    log "  Machine: $MACHINE_NAME"
    log "  VM Name: $VM_NAME"
    log ""

    log "VMs:"
    if [[ "$SKIP_ROUTER" == false ]]; then
        log "  [+] Router VM: router-vm-passthrough"
    else
        log "  [!] Router VM: Skipped"
    fi
    if [[ "$SKIP_PENTEST" == false ]]; then
        log "  [+] Pentest VM: $VM_NAME"
    else
        log "  [!] Pentest VM: Skipped"
    fi
    log ""

    log "Generated Files:"
    log "  [+] generated/modules/${MACHINE_NAME}-consolidated.nix (staged)"
    log "      (VFIO + router + maximalism specialisations)"
    log "  [+] profiles/machines/${MACHINE_NAME}.nix (staged)"
    log "      (Machine profile - auto-imports consolidated module)"
    log "  [+] flake.nix updated with nixosConfiguration.${MACHINE_NAME} (staged)"
    log "  [+] generated/scripts/autostart-router-vm.sh (staged)"
    log "  [!] hardware-results.env, hardware-results.json (gitignored - sensitive)"
    log "  [!] router-credentials.env (gitignored - contains passwords)"
    log ""

    log "System is READY! Next steps:"
    log ""
    log "1. Rebuild into router or maximalism mode (creates bridge interfaces):"
    log ""
    log "   Router Mode (router VM with WiFi passthrough):"
    log "     sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME} --specialisation router --impure"
    log ""
    log "   Maximalism Mode (router + pentest VMs):"
    log "     sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME} --specialisation maximalism --impure"
    log ""
    log "2. After rebuild, re-run setup.sh to deploy VMs:"
    log "     cd ~/Hydrix && ./scripts/setup.sh"
    log "   (VMs can only be created once bridge interfaces exist)"
    log ""
    log "3. Future boots: VMs will auto-start via systemd services"
    log ""
    log "4. Check status anytime: vm-status"
    log ""
    log "5. Switch back to Base Mode (normal laptop):"
    log "     sudo nixos-rebuild switch --flake ~/Hydrix#${MACHINE_NAME} --impure"
    log ""

    success "Setup complete! Rebuild with specialisation, then re-run setup.sh to deploy VMs."
}

main() {
    log ""
    log "[*] HYDRIX MACHINE SETUP [*]"
    log "============================="
    log ""
    log "Complete VM automation with integrated router build logic"
    log ""

    check_prerequisites
    auto_detect_machine

    log ""
    log "Configuration Summary:"
    log "  Machine: $MACHINE_NAME ($MACHINE_MODEL)"
    log "  VM Name: $VM_NAME"
    log "  Force Rebuild: $FORCE_REBUILD"
    log ""

    if [[ "$FORCE_REBUILD" == false ]]; then
        read -p "Continue with setup? [Y/n]: " -r
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            log "Setup cancelled by user"
            exit 0
        fi
    fi

    # Execute all steps
    step1_hardware_detection
    step2_generate_router_credentials
    step3_build_router_vm
    step4_generate_consolidated_config
    step5_build_pentest_vm
    show_build_summary
    step6_create_machine_profile
    step7_update_flake
    step8_generate_deployment_scripts
    step9_git_stage_files
    step10_deploy_router_vm     # Skips if not in router/maximalism mode
    step11_deploy_pentest_vm    # Skips if not in maximalism mode
    show_completion_summary

    log ""
    success "[+] Machine setup completed successfully!"
}

main "$@"
