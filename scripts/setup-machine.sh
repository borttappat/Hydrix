#!/run/current-system/sw/bin/bash
# setup-machine.sh - Automated new machine setup for Hydrix
#
# This script automatically:
# 1. Detects hostname and CPU platform (Intel/AMD)
# 2. Creates complete machine profile with VFIO/specialisations
# 3. Updates flake.nix with new machine entry
# 4. Builds router VM image and installs to libvirt storage
# 5. Generates autostart script
# 6. Git adds generated files
# 7. Builds system configuration
#
# Boot Modes Generated:
#   - Default: Router mode (WiFi passed to VM, bridges active)
#   - Fallback: Emergency WiFi mode (re-enables WiFi, normal NetworkManager)
#   - Lockdown: Full isolation (10.100.x.x, VPN routing, host blocked)
#
# Usage: ./scripts/setup-machine.sh [OPTIONS]
#
# Options:
#   --force-rebuild    Force rebuild of router VM even if it exists
#   --skip-router      Skip router VM build (useful for testing)
#   -h, --help         Show this help

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly GENERATED_DIR="$PROJECT_DIR/generated"

# Options
FORCE_REBUILD=false
SKIP_ROUTER=false

# Logging
log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }
warn() { echo "[WARN] $*"; }

# ========== AUTO-DETECTION FUNCTIONS ==========

detect_hostname() {
    local hostname
    hostname=$(hostnamectl hostname 2>/dev/null || hostname)

    # Sanitize hostname for use in Nix identifiers
    # Remove any characters that aren't alphanumeric or hyphen
    hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')

    if [[ -z "$hostname" ]]; then
        error "Could not detect hostname"
    fi

    echo "$hostname"
}

detect_cpu_platform() {
    # Returns "intel" or "amd" based on CPU vendor
    local cpu_vendor
    cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')

    case "$cpu_vendor" in
        GenuineIntel)
            echo "intel"
            ;;
        AuthenticAMD)
            echo "amd"
            ;;
        *)
            warn "Unknown CPU vendor: $cpu_vendor - defaulting to intel"
            echo "intel"
            ;;
    esac
}

get_iommu_param() {
    local platform="$1"
    case "$platform" in
        intel)
            echo "intel_iommu=on"
            ;;
        amd)
            echo "amd_iommu=on"
            ;;
        *)
            echo "intel_iommu=on"
            ;;
    esac
}

# ========== PREREQUISITE CHECKS ==========

check_prerequisites() {
    log "Checking prerequisites..."

    if [[ $EUID -eq 0 ]]; then
        error "Don't run this as root"
    fi

    local missing=()
    for cmd in nix git jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
    fi

    # Check we're in the Hydrix directory
    if [[ ! -f "$PROJECT_DIR/flake.nix" ]]; then
        error "flake.nix not found - are you in the Hydrix directory?"
    fi

    log "Prerequisites OK"
}

# ========== CHECK IF MACHINE ALREADY EXISTS ==========

check_machine_exists() {
    local machine_name="$1"
    local flake_path="$PROJECT_DIR/flake.nix"

    if grep -q "^[[:space:]]*${machine_name}[[:space:]]*=" "$flake_path"; then
        return 0  # exists
    fi
    return 1  # does not exist
}

# ========== HARDWARE DETECTION ==========

run_hardware_detection() {
    log "Running hardware detection..."

    cd "$PROJECT_DIR"

    if [[ -x "$SCRIPT_DIR/hardware-identify.sh" ]]; then
        if ! "$SCRIPT_DIR/hardware-identify.sh"; then
            error "Hardware detection failed"
        fi
    else
        error "hardware-identify.sh not found or not executable"
    fi

    if [[ ! -f "$PROJECT_DIR/hardware-results.env" ]]; then
        error "Hardware detection did not produce results"
    fi

    source "$PROJECT_DIR/hardware-results.env"

    if [[ ${COMPATIBILITY_SCORE:-0} -lt 5 ]]; then
        warn "Hardware compatibility score is low (${COMPATIBILITY_SCORE:-0}/10)"
        warn "Router VM passthrough may not work reliably"
    fi

    log "Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID) on $PRIMARY_PCI"
    log "Driver: $PRIMARY_DRIVER"
    log "Compatibility: ${COMPATIBILITY_SCORE:-0}/10"
}

# ========== GENERATE MACHINE PROFILE ==========
# This generates a complete machine profile with all VFIO/specialisation config inline
# No separate consolidated.nix file needed

generate_machine_profile() {
    local machine_name="$1"
    local cpu_platform="$2"
    local profile_path="$PROJECT_DIR/profiles/machines/${machine_name}.nix"

    log "Generating machine profile: ${machine_name}.nix"

    source "$PROJECT_DIR/hardware-results.env"

    local iommu_param
    iommu_param=$(get_iommu_param "$cpu_platform")

    mkdir -p "$PROJECT_DIR/profiles/machines"

    log "  Machine: $machine_name"
    log "  CPU Platform: $cpu_platform"
    log "  IOMMU Param: $iommu_param"
    log "  WiFi Device: $PRIMARY_ID ($PRIMARY_PCI)"
    log "  Driver: $PRIMARY_DRIVER"

    cat > "$profile_path" << MACHINEEOF
# ${machine_name} - Machine-specific configuration
# Auto-generated by setup-machine.sh on $(date)
# CPU Platform: ${cpu_platform}
# Hardware: ${PRIMARY_ID} (${PRIMARY_PCI})
#
# Architecture:
#   - BASE CONFIG = Router mode (WiFi passed to VM, bridges active)
#   - Host creates bridges, Router VM handles ALL networking
#   - Specialisations: fallback (re-enable WiFi) and lockdown (VPN isolation)
#
# Boot Modes:
#   - Default boot: Router mode with 192.168.x.x (simple NAT)
#   - Fallback: Re-enables WiFi, normal NetworkManager (emergency)
#   - Lockdown: 10.100.x.x with VPN policy routing, host isolated

{ config, pkgs, lib, ... }:

{
  imports = [
    # Theming system (dynamic for host machine)
    ../../modules/theming/dynamic.nix
    ../../modules/desktop/xinitrc.nix
  ];

  # Override hostname for this machine
  networking.hostName = lib.mkForce "${machine_name}";

  # ===== BASE CONFIG = ROUTER MODE (Default Boot) =====
  # WiFi is blacklisted and passed through to router VM
  # This is the normal operating mode

  # VFIO setup for WiFi passthrough
  boot.kernelParams = [
    "${iommu_param}"
    "iommu=pt"
    "vfio-pci.ids=${PRIMARY_ID}"
  ];
  boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];
  boot.blacklistedKernelModules = [ "${PRIMARY_DRIVER}" ];

  # Disable NetworkManager - router VM handles networking
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce false;

  # Enable libvirtd for VM management
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

  # Create bridges for VM networking
  networking.bridges.br-mgmt.interfaces = [];
  networking.bridges.br-pentest.interfaces = [];
  networking.bridges.br-office.interfaces = [];
  networking.bridges.br-browse.interfaces = [];
  networking.bridges.br-dev.interfaces = [];

  # Host gets IP on management bridge only (for router VM communication)
  networking.interfaces.br-mgmt.ipv4.addresses = [{
    address = "192.168.100.1";
    prefixLength = 24;
  }];

  # Default route through router VM
  networking.defaultGateway = {
    address = "192.168.100.253";
    interface = "br-mgmt";
  };

  # Minimal firewall - trust bridges, router handles the rest
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "br-mgmt" "br-pentest" "br-office" "br-browse" "br-dev" ];
  };

  # Router VM autostart service
  systemd.services.router-vm-autostart = {
    description = "Auto-start router VM with NIC passthrough";
    after = [ "libvirtd.service" "network.target" "sys-devices-virtual-net-br\\x2dmgmt.device" ];
    wants = [ "libvirtd.service" ];
    requires = [ "sys-devices-virtual-net-br\\x2dmgmt.device" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "180s";
    };
    script = ''
      set -euo pipefail

      VM_NAME="router-vm"
      VM_IMAGE="/var/lib/libvirt/images/router-vm.qcow2"
      PCI_ADDR="${PRIMARY_PCI#0000:}"

      log() { echo "[router-vm-autostart] \\\$*"; }

      # Wait for all bridges to exist (with timeout)
      log "Waiting for bridges..."
      TIMEOUT=60
      ELAPSED=0
      for br in br-mgmt br-pentest br-office br-browse br-dev; do
        while ! /run/current-system/sw/bin/ip link show "\\\$br" >/dev/null 2>&1; do
          if [ \\\$ELAPSED -ge \\\$TIMEOUT ]; then
            log "ERROR: Timeout waiting for bridge \\\$br"
            exit 1
          fi
          sleep 1
          ELAPSED=\\\$((ELAPSED + 1))
        done
        log "  + \\\$br exists"
      done

      # Check for router VM image
      if [ ! -f "\\\$VM_IMAGE" ]; then
        log "ERROR: Router VM image not found at \\\$VM_IMAGE"
        log "Run: nix build ~/Hydrix#router-vm && sudo cp result/nixos.qcow2 \\\$VM_IMAGE"
        exit 1
      fi

      # Define VM if not already defined
      if ! /run/current-system/sw/bin/virsh dominfo "\\\$VM_NAME" >/dev/null 2>&1; then
        log "Defining router VM with PCI passthrough (\\\$PCI_ADDR)..."

        /run/current-system/sw/bin/virt-install \\
          --connect qemu:///system \\
          --name "\\\$VM_NAME" \\
          --memory 2048 \\
          --vcpus 2 \\
          --disk "path=\\\$VM_IMAGE,format=qcow2,bus=virtio" \\
          --import \\
          --os-variant nixos-unstable \\
          --network bridge=br-mgmt,model=virtio \\
          --network bridge=br-pentest,model=virtio \\
          --network bridge=br-office,model=virtio \\
          --network bridge=br-browse,model=virtio \\
          --network bridge=br-dev,model=virtio \\
          --hostdev "\\\$PCI_ADDR" \\
          --graphics spice \\
          --video virtio \\
          --noautoconsole \\
          --autostart \\
          --print-xml > /tmp/router-vm.xml

        /run/current-system/sw/bin/virsh define /tmp/router-vm.xml
        rm -f /tmp/router-vm.xml
        log "+ Router VM defined"
      else
        log "Router VM already defined"
      fi

      # Start VM if not running
      VM_STATE=\\\$(/run/current-system/sw/bin/virsh domstate "\\\$VM_NAME" 2>/dev/null || echo "unknown")
      if [ "\\\$VM_STATE" != "running" ]; then
        log "Starting router VM..."
        /run/current-system/sw/bin/virsh start "\\\$VM_NAME"
      fi

      # Enable autostart
      /run/current-system/sw/bin/virsh autostart "\\\$VM_NAME" 2>/dev/null || true

      # Verify VM is running
      sleep 2
      VM_STATE=\\\$(/run/current-system/sw/bin/virsh domstate "\\\$VM_NAME" 2>/dev/null || echo "unknown")
      if [ "\\\$VM_STATE" = "running" ]; then
        log "+ Router VM running (standard mode)"
        log "  Management: 192.168.100.253"
      else
        log "WARNING: Router VM state is \\\$VM_STATE"
        exit 1
      fi
    '';
  };

  # ===== FALLBACK SPECIALISATION =====
  # Emergency escape hatch - re-enables WiFi, disables VFIO and bridges
  # Use this if router mode fails or for debugging
  specialisation.fallback.configuration = {
    system.nixos.label = lib.mkForce "fallback";

    # Re-enable WiFi driver (un-blacklist)
    boot.blacklistedKernelModules = lib.mkOverride 10 [];

    # Re-enable NetworkManager for normal WiFi
    # mkOverride 10 beats mkForce (which is mkOverride 50)
    networking.networkmanager.enable = lib.mkOverride 10 true;
    networking.useDHCP = lib.mkOverride 10 true;

    # Remove bridges
    networking.bridges = lib.mkOverride 10 {};
    networking.interfaces = lib.mkOverride 10 {};
    networking.defaultGateway = lib.mkOverride 10 null;

    # Disable router VM autostart
    systemd.services.router-vm-autostart.enable = lib.mkOverride 10 false;

    # Standard firewall
    networking.firewall = lib.mkOverride 10 {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };

    environment.systemPackages = with pkgs; lib.mkAfter [
      (writeShellScriptBin "fallback-status" ''
        echo "FALLBACK MODE Status"
        echo "===================="
        echo ""
        echo "This is emergency fallback mode - normal WiFi networking."
        echo "VFIO passthrough disabled, bridges removed, router VM disabled."
        echo ""
        echo "Network interfaces:"
        ip -br addr
        echo ""
        echo "To return to router mode (requires reboot):"
        echo "  sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name}"
        echo "  sudo reboot"
      '')
    ];
  };

  # ===== LOCKDOWN SPECIALISATION =====
  # Full network isolation - host has NO internet access
  # Inherits everything from base router config (bridges, VFIO, etc.)
  # Only difference: host is completely blocked from internet
  specialisation.lockdown.configuration = {
    system.nixos.label = lib.mkForce "lockdown";

    # NO default gateway - host is fully isolated from internet
    # Bridges and router VM still work exactly like base config
    networking.defaultGateway = lib.mkOverride 10 null;

    # Strict firewall - host cannot reach internet directly
    networking.firewall = lib.mkOverride 10 {
      enable = true;
      trustedInterfaces = [ "br-mgmt" "br-pentest" "br-office" "br-browse" "br-dev" ];
      extraCommands = ''
        # Drop all forwarding - router VM handles this
        iptables -P FORWARD DROP

        # Host can only communicate with VMs on bridges
        iptables -A OUTPUT -o br-mgmt -j ACCEPT
        iptables -A OUTPUT -o br-pentest -j ACCEPT
        iptables -A OUTPUT -o br-office -j ACCEPT
        iptables -A OUTPUT -o br-browse -j ACCEPT
        iptables -A OUTPUT -o br-dev -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        # Block everything else outbound from host
        iptables -A OUTPUT -j DROP
      '';
    };

    # Disable IP forwarding on host - router VM handles all routing
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkOverride 10 0;
      "net.ipv6.conf.all.forwarding" = lib.mkOverride 10 0;
    };

    # Lockdown indicator file
    environment.etc."LOCKDOWN_MODE".text = ''
      Lockdown mode enabled
      Host internet access: DISABLED
      Router VM still handles all networking via bridges
    '';

    environment.systemPackages = with pkgs; lib.mkAfter [
      (writeShellScriptBin "lockdown-status" ''
        echo "LOCKDOWN MODE Status"
        echo "===================="
        echo ""
        echo "Host Internet: DISABLED (blocked by firewall)"
        echo "Router VM: \$(sudo virsh domstate router-vm 2>/dev/null || echo 'Not running')"
        echo "NIC Passthrough: ${PRIMARY_PCI} (${PRIMARY_ID})"
        echo ""
        echo "Network (same as router mode, host isolated):"
        echo "  br-mgmt:    192.168.100.0/24"
        echo "  br-pentest: 192.168.101.0/24"
        echo "  br-office:  192.168.102.0/24"
        echo "  br-browse:  192.168.103.0/24"
        echo "  br-dev:     192.168.104.0/24"
        echo ""
        echo "Bridges:"
        for br in br-mgmt br-pentest br-office br-browse br-dev; do
          state=\$(ip link show \$br 2>/dev/null | grep -o 'state [A-Z]*' || echo 'NOT FOUND')
          echo "  \$br: \$state"
        done
        echo ""
        echo "Host firewall blocks all outbound except bridge traffic."
        echo "VMs can still access internet through router VM."
      '')
    ];
  };

  # ===== COMMON PACKAGES (Always Enabled) =====
  environment.systemPackages = with pkgs; lib.mkAfter [
    virt-manager
    virt-viewer
    libvirt
    qemu
    OVMF
    spice-gtk
    virtiofsd

    # Status command for current mode detection
    (writeShellScriptBin "vm-status" ''
      echo "${machine_name} System Status"
      echo "========================="
      echo ""

      # Detect current specialisation
      if [[ -L /run/current-system/specialisation ]]; then
        ACTIVE_SPEC=\$(readlink /run/current-system/specialisation | xargs basename 2>/dev/null || echo "none")
        echo "Current Mode: \$ACTIVE_SPEC (specialisation)"
      else
        echo "Current Mode: ROUTER (base config - default)"
      fi
      echo ""

      echo "Network Status:"
      echo "  Bridges:"
      for br in br-mgmt br-pentest br-office br-browse br-dev; do
        if ip link show \$br &>/dev/null; then
          state=\$(ip link show \$br | grep -o 'state [A-Z]*')
          echo "    \$br: \$state"
        fi
      done
      echo ""

      echo "  Host IP: \$(ip -4 addr show br-mgmt 2>/dev/null | grep inet | awk '{print \$2}' || echo 'No bridge IP')"
      echo "  WiFi:    \$(ip link show ${PRIMARY_INTERFACE} 2>/dev/null && echo 'Present (fallback mode?)' || echo 'Passed to VM')"
      echo ""

      echo "Router VM: \$(sudo virsh domstate router-vm 2>/dev/null || echo 'Not running')"
      echo ""

      echo "Available Modes:"
      echo "  (default)  - Router mode: router VM handles networking, host has internet"
      echo "  fallback   - Emergency: Re-enables WiFi, normal NetworkManager"
      echo "  lockdown   - Isolated: Same as router but host blocked from internet"
      echo ""

      echo "Switching Modes (requires reboot for kernel changes):"
      echo "  sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name}"
      echo "  sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name} --specialisation fallback"
      echo "  sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name} --specialisation lockdown"
    '')

    # Router mode status
    (writeShellScriptBin "router-status" ''
      echo "ROUTER MODE Status"
      echo "=================="
      echo ""
      echo "Router VM: \$(sudo virsh domstate router-vm 2>/dev/null || echo 'Not running')"
      echo "Management IP: 192.168.100.1 (host) / 192.168.100.253 (router)"
      echo ""
      echo "Bridges:"
      for br in br-mgmt br-pentest br-office br-browse br-dev; do
        state=\$(ip link show \$br 2>/dev/null | grep -o 'state [A-Z]*' || echo 'NOT FOUND')
        echo "  \$br: \$state"
      done
      echo ""
      echo "Networks (192.168.x.x - router provides DHCP):"
      echo "  br-mgmt:    192.168.100.0/24"
      echo "  br-pentest: 192.168.101.0/24"
      echo "  br-office:  192.168.102.0/24"
      echo "  br-browse:  192.168.103.0/24"
      echo "  br-dev:     192.168.104.0/24"
    '')
  ];

  # ========== ADD MACHINE-SPECIFIC PACKAGES HERE ==========
  # environment.systemPackages = with pkgs; [
  #   # Example: NVIDIA tools
  #   # nvtopPackages.full
  #   # cudatoolkit
  #
  #   # Example: Power management
  #   # powertop
  #   # acpi
  # ];

  # ========== ADD HARDWARE-SPECIFIC SETTINGS HERE ==========
  # Examples:
  #
  # # NVIDIA GPU
  # hardware.nvidia = {
  #   modesetting.enable = true;
  #   # ...
  # };
  #
  # # Power management
  # services.tlp.enable = true;
  #
  # # Bluetooth
  # hardware.bluetooth.enable = true;
}
MACHINEEOF

    success "Machine profile created: $profile_path"
}

# ========== UPDATE FLAKE.NIX ==========

update_flake() {
    local machine_name="$1"
    local flake_path="$PROJECT_DIR/flake.nix"

    log "Updating flake.nix with ${machine_name} configuration..."

    # Check if machine configuration already exists
    if check_machine_exists "$machine_name"; then
        warn "Machine '$machine_name' already exists in flake.nix"
        warn "Skipping flake update"
        return
    fi

    # Create the new configuration block
    local new_config
    new_config=$(cat << FLAKEENTRY

      # ${machine_name} - Auto-generated configuration
      # Build with: ./nixbuild.sh (hostname: ${machine_name})
      ${machine_name} = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index
          home-manager.nixosModules.home-manager

          # Base system configuration
          ./modules/base/configuration.nix
          ./modules/base/hardware-config.nix

          # Machine-specific configuration (imports generated consolidated module)
          ./profiles/machines/${machine_name}.nix

          # Core functionality modules
          ./modules/wm/i3.nix
          ./modules/shell/packages.nix
          ./modules/base/services.nix
          ./modules/base/users.nix
          ./modules/theming/colors.nix
          ./modules/base/virt.nix
          ./modules/base/audio.nix
          ./modules/desktop/firefox.nix
        ];
      };
FLAKEENTRY
)

    # Find the line with "nixosConfigurations = {" and add new config after it
    local temp_file
    temp_file=$(mktemp)
    local added=false

    while IFS= read -r line; do
        echo "$line" >> "$temp_file"

        # After "nixosConfigurations = {", add the new machine config
        if [[ "$line" =~ "nixosConfigurations = {" ]] && [[ "$added" == false ]]; then
            echo "$new_config" >> "$temp_file"
            added=true
        fi
    done < "$flake_path"

    if [[ "$added" == true ]]; then
        mv "$temp_file" "$flake_path"
        success "Flake configuration updated with ${machine_name}"
    else
        rm "$temp_file"
        error "Could not find insertion point in flake.nix"
    fi
}

# ========== BUILD ROUTER VM ==========

build_router_vm() {
    log "Building router VM image..."

    cd "$PROJECT_DIR"

    local libvirt_image="/var/lib/libvirt/images/router-vm.qcow2"

    # Check if router VM already exists in libvirt storage (unless force rebuild)
    if [[ "$FORCE_REBUILD" != true ]] && [[ -f "$libvirt_image" ]]; then
        local size
        size=$(sudo du -h "$libvirt_image" | cut -f1)
        log "Router VM image already exists in libvirt storage: $size"
        log "Use --force-rebuild to rebuild"
        return
    fi

    # Force rebuild - remove existing image
    if [[ "$FORCE_REBUILD" == true ]]; then
        log "Force rebuild requested - removing cached images..."
        rm -f "router-vm-result" 2>/dev/null || true
        sudo rm -f "$libvirt_image" 2>/dev/null || true
    fi

    # Check if we have a cached build (and not forcing)
    if [[ "$FORCE_REBUILD" != true ]] && [[ -f "router-vm-result/nixos.qcow2" ]]; then
        local size
        size=$(du -h router-vm-result/nixos.qcow2 | cut -f1)
        log "Using cached router VM build: $size"
    else
        log "Building router VM (this may take several minutes)..."

        # Use nix-shell to ensure virtiofsd is available for nixos-generators qcow format
        if ! nix-shell -p virtiofsd --run "nix build .#router-vm --out-link router-vm-result"; then
            error "Router VM build failed"
        fi

        if [[ ! -f "router-vm-result/nixos.qcow2" ]]; then
            error "Router VM build failed - no qcow2 found"
        fi

        local size
        size=$(du -h router-vm-result/nixos.qcow2 | cut -f1)
        success "Router VM built: $size"
    fi

    # Copy to libvirt storage
    log "Installing router VM image to libvirt storage..."
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp "router-vm-result/nixos.qcow2" "$libvirt_image"
    sudo chmod 644 "$libvirt_image"

    local final_size
    final_size=$(sudo du -h "$libvirt_image" | cut -f1)
    success "Router VM installed: $libvirt_image ($final_size)"
}

# ========== GENERATE AUTOSTART SCRIPT ==========

generate_autostart_script() {
    log "Generating autostart script..."

    mkdir -p "$GENERATED_DIR/scripts"

    local script_path="$GENERATED_DIR/scripts/autostart-router-vm.sh"

    # Note: This script is kept for backwards compatibility but the actual
    # autostart logic is now embedded in the specialisation systemd services.
    # The consolidated config generates inline scripts for each mode.

    cat > "$script_path" << 'AUTOSTARTEOF'
#!/run/current-system/sw/bin/bash
# Legacy autostart script - actual autostart is handled by systemd services
# in the specialisation configuration. This script is kept for manual use.
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] Router: $*"; }

VIRSH="/run/current-system/sw/bin/virsh"

# Detect which router VM to use based on current mode
detect_router_vm() {
    if $VIRSH --connect qemu:///system list --all 2>/dev/null | grep -q "lockdown-router"; then
        echo "lockdown-router"
    elif $VIRSH --connect qemu:///system list --all 2>/dev/null | grep -q "router-vm"; then
        echo "router-vm"
    else
        echo ""
    fi
}

VM_NAME=$(detect_router_vm)

if [ -z "$VM_NAME" ]; then
    log "No router VM found. Please switch to a passthrough specialisation first."
    log "  sudo nixos-rebuild switch --specialisation maximalism"
    exit 1
fi

log "Found router VM: $VM_NAME"

vm_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" 2>/dev/null || echo "unknown")
log "Current state: $vm_state"

case "$vm_state" in
    "running")
        log "Router VM is already running"
        ;;
    "paused")
        log "Resuming paused router VM..."
        $VIRSH --connect qemu:///system resume "$VM_NAME"
        ;;
    "shut off"|"shutoff")
        log "Starting router VM..."
        $VIRSH --connect qemu:///system start "$VM_NAME"
        ;;
    *)
        log "Unexpected state: $vm_state - attempting start..."
        $VIRSH --connect qemu:///system start "$VM_NAME" 2>/dev/null || true
        ;;
esac

sleep 2

if $VIRSH --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
    log "Router VM is running"

    # Show appropriate management IP based on VM name
    if [[ "$VM_NAME" == "lockdown-router" ]]; then
        log "Management IP: 10.100.0.253 (lockdown mode)"
    else
        log "Management IP: 192.168.100.253 (standard mode)"
    fi
else
    log "WARNING: Router VM may not have started correctly"
    exit 1
fi
AUTOSTARTEOF

    chmod +x "$script_path"
    success "Autostart script generated: $script_path"
}

# ========== DEPLOY ROUTER VM ==========

deploy_router_vm() {
    log "Deploying router VM to libvirt..."

    source "$PROJECT_DIR/hardware-results.env"

    local vm_name="router-vm-passthrough"
    local vm_image_source="$PROJECT_DIR/router-vm-result/nixos.qcow2"
    local vm_image_dest="/var/lib/libvirt/images/$vm_name.qcow2"

    if [[ ! -f "$vm_image_source" ]]; then
        error "Router VM image not found: $vm_image_source"
    fi

    # Check if VM already exists
    if sudo virsh --connect qemu:///system list --all 2>/dev/null | grep -q "$vm_name"; then
        log "Router VM already deployed - removing for fresh deploy"
        sudo virsh --connect qemu:///system destroy "$vm_name" 2>/dev/null || true
        sudo virsh --connect qemu:///system undefine "$vm_name" --nvram 2>/dev/null || true
        sudo rm -f "$vm_image_dest"
    fi

    # Copy VM image
    log "Copying VM image to libvirt storage..."
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp "$vm_image_source" "$vm_image_dest"
    sudo chmod 644 "$vm_image_dest"

    # Format PCI ID for virt-install (0000:00:14.3 -> 00:14.3)
    local pci_short="${PRIMARY_PCI#0000:}"

    log "Deploying router VM with WiFi passthrough (PCI: $pci_short)..."

    # Note: This creates the VM definition but won't start it until bridges exist
    # The VM will autostart when booted into router mode
    if sudo virt-install \
        --connect qemu:///system \
        --name "$vm_name" \
        --memory 2048 \
        --vcpus 2 \
        --disk "$vm_image_dest,device=disk,bus=virtio" \
        --os-variant nixos-unstable \
        --boot hd \
        --nographics \
        --network bridge=br-mgmt,model=virtio \
        --network bridge=br-pentest,model=virtio \
        --network bridge=br-office,model=virtio \
        --network bridge=br-browse,model=virtio \
        --network bridge=br-dev,model=virtio \
        --hostdev "$pci_short" \
        --noautoconsole \
        --import 2>/dev/null; then
        success "Router VM deployed with WiFi passthrough!"
    else
        log "WiFi passthrough failed (bridges may not exist yet)"
        log "Creating VM definition without passthrough - will work after reboot into router mode"
        sudo virt-install \
            --connect qemu:///system \
            --name "$vm_name" \
            --memory 2048 \
            --vcpus 2 \
            --disk "$vm_image_dest,device=disk,bus=virtio" \
            --os-variant nixos-unstable \
            --boot hd \
            --nographics \
            --network network=default,model=virtio \
            --noautoconsole \
            --import 2>/dev/null || warn "VM definition creation deferred until after reboot"
    fi
}

# ========== BUILD SYSTEM ==========

build_system() {
    local machine_name="$1"

    log "Building system configuration (boot entry only - no immediate switch)..."

    cd "$PROJECT_DIR"

    # Use 'boot' instead of 'switch' for initial setup
    # This creates a boot entry without switching immediately, which:
    # - Preserves current network connectivity during setup
    # - Allows the setup to complete without VFIO breaking networking
    # - Requires a reboot to activate (safe transition)
    log "Running: nixos-rebuild boot --flake .#${machine_name}"
    if sudo nixos-rebuild boot --impure --show-trace --option warn-dirty false \
        --flake "$PROJECT_DIR#$machine_name"; then
        success "System built successfully - reboot to activate"
    else
        error "System build failed"
    fi
}

# ========== GIT STAGE FILES ==========

git_stage_files() {
    local machine_name="$1"

    log "Staging generated files in git..."

    cd "$PROJECT_DIR"

    local files_to_add=(
        "profiles/machines/${machine_name}.nix"
        "generated/scripts/autostart-router-vm.sh"
        "flake.nix"
    )

    for file in "${files_to_add[@]}"; do
        if [[ -f "$file" ]]; then
            git add "$file" 2>/dev/null && log "  [+] $file" || warn "  [!] $file (could not stage)"
        fi
    done

    success "Files staged in git"
}

# ========== SHOW COMPLETION SUMMARY ==========

show_completion_summary() {
    local machine_name="$1"
    local cpu_platform="$2"

    echo ""
    success "========================================"
    success "  MACHINE SETUP COMPLETED!"
    success "========================================"
    echo ""
    echo "Configuration:"
    echo "  Machine Name: $machine_name"
    echo "  CPU Platform: $cpu_platform"
    echo ""
    echo "Generated Files:"
    echo "  [+] profiles/machines/${machine_name}.nix (complete config)"
    echo "  [+] generated/scripts/autostart-router-vm.sh"
    echo "  [+] flake.nix (updated)"
    echo ""
    echo "Router VM:"
    if [[ -f "/var/lib/libvirt/images/router-vm.qcow2" ]]; then
        local size
        size=$(sudo du -h "/var/lib/libvirt/images/router-vm.qcow2" | cut -f1)
        echo "  [+] Installed: /var/lib/libvirt/images/router-vm.qcow2 ($size)"
    else
        echo "  [!] Not installed (run setup again or: nix build .#router-vm)"
    fi
    echo "  [i] Auto-starts on first boot into router mode"
    echo ""
    echo "========================================"
    echo "  ARCHITECTURE"
    echo "========================================"
    echo ""
    echo "  Host creates bridges ONLY (no IP routing):"
    echo "    br-mgmt, br-pentest, br-office, br-browse, br-dev"
    echo ""
    echo "  Router VM handles ALL networking:"
    echo "    - DHCP for each bridge network"
    echo "    - NAT to internet (via passthrough NIC)"
    echo "    - VPN policy routing (lockdown mode)"
    echo ""
    echo "========================================"
    echo "  NEXT STEPS"
    echo "========================================"
    echo ""
    echo "1. (Optional) Commit the changes:"
    echo "   git commit -m 'Add ${machine_name} machine configuration'"
    echo ""
    echo "2. Reboot into router mode:"
    echo "   sudo reboot"
    echo ""
    echo "   On reboot:"
    echo "   - System boots into router-setup (default)"
    echo "   - NIC driver blacklisted for passthrough"
    echo "   - Bridges created: br-mgmt, br-pentest, br-office, br-browse, br-dev"
    echo "   - Router VM auto-starts with NIC passthrough"
    echo "   - Router provides DHCP on 192.168.100-104.x"
    echo "   - Host gets internet via router (192.168.100.253)"
    echo ""
    echo "========================================"
    echo "  AVAILABLE MODES"
    echo "========================================"
    echo ""
    echo "    [DEFAULT] - Router mode"
    echo "      Router VM handles all networking"
    echo "      Host IP:   192.168.100.1"
    echo "      Router IP: 192.168.100.253"
    echo "      Host has internet access via router"
    echo ""
    echo "    lockdown - Host isolation"
    echo "      Same bridges and router VM as default"
    echo "      Host firewall blocks all outbound traffic"
    echo "      VMs can still access internet via router"
    echo ""
    echo "    fallback - Emergency escape hatch"
    echo "      Normal WiFi networking, no VFIO, no bridges"
    echo "      Use if router/lockdown modes fail"
    echo ""
    echo "  Switch between them:"
    echo "    sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name}"
    echo "    sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name} --specialisation lockdown"
    echo "    sudo nixos-rebuild boot --flake ~/Hydrix#${machine_name} --specialisation fallback"
    echo ""
}

# ========== ARGUMENT PARSING ==========

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automated machine setup for Hydrix VM isolation system.

Options:
  --force-rebuild    Force rebuild of router VM even if it exists
  --skip-router      Skip router VM build (useful for testing)
  -h, --help         Show this help

This script automatically:
  1. Detects hostname and CPU platform (Intel/AMD)
  2. Identifies network hardware for VFIO passthrough
  3. Generates complete machine profile (profiles/machines/[hostname].nix)
  4. Updates flake.nix with new machine entry
  5. Builds and installs router VM to libvirt storage
  6. Builds system with specialisations (fallback/lockdown)

After running, reboot to enter router mode (default) with router VM.

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-rebuild)
                FORCE_REBUILD=true
                shift
                ;;
            --skip-router)
                SKIP_ROUTER=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# ========== MAIN ==========

main() {
    parse_args "$@"

    echo ""
    log "========================================"
    log "  HYDRIX MACHINE SETUP"
    log "========================================"
    echo ""

    check_prerequisites

    # Auto-detect machine info
    local machine_name
    local cpu_platform

    machine_name=$(detect_hostname)
    cpu_platform=$(detect_cpu_platform)

    log "Detected hostname: $machine_name"
    log "Detected CPU platform: $cpu_platform ($(get_iommu_param "$cpu_platform"))"
    echo ""

    # Check if machine already exists
    if check_machine_exists "$machine_name"; then
        warn "Machine '$machine_name' already exists in flake.nix"
        echo ""
        read -p "Continue anyway? This will regenerate configs. [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Setup cancelled"
            exit 0
        fi
    fi

    # Run all setup steps
    run_hardware_detection
    generate_machine_profile "$machine_name" "$cpu_platform"
    update_flake "$machine_name"

    if [[ "$SKIP_ROUTER" == true ]]; then
        log "Skipping router VM build (--skip-router)"
    else
        build_router_vm
    fi

    generate_autostart_script
    git_stage_files "$machine_name"
    build_system "$machine_name"
    show_completion_summary "$machine_name" "$cpu_platform"
}

main "$@"
