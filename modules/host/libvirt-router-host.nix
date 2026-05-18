# Libvirt Router Host Module
# Host-side module that spawns and manages the libvirt router VM
#
# This is the HOST-side management. For the VM's NixOS config, see:
#   modules/vm/libvirt-router.nix
#
# Options are defined centrally in modules/options.nix under:
#   hydrix.router.libvirt.*  - VM resource settings and WAN config
#   hydrix.router.autostart  - shared autostart flag
#   hydrix.networking.bridges - bridge list (shared with microvm path)
#
# The module handles:
#   - Generating libvirt XML from Nix options
#   - Auto-detecting WiFi for PCI passthrough (or falling back to macvtap)
#   - Starting/managing the VM via systemd
#   - Integrating with specialisations (disabled in fallback mode)

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.hydrix;
  routerCfg = cfg.router;
  libvirtCfg = routerCfg.libvirt;
  netCfg = cfg.networking;

  # Generate libvirt XML for the router VM
  # This is generated at build time, but WAN device detection happens at runtime
  routerXml = pkgs.writeText "router-vm.xml" ''
    <domain type='kvm'>
      <name>${libvirtCfg.vmName}</name>
      <memory unit='MiB'>${toString libvirtCfg.memory}</memory>
      <vcpu>${toString libvirtCfg.vcpus}</vcpu>
      <os>
        <type arch='x86_64' machine='q35'>hvm</type>
        <boot dev='hd'/>
      </os>
      <features>
        <acpi/>
        <apic/>
      </features>
      <cpu mode='host-passthrough'/>
      <clock offset='utc'/>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>destroy</on_crash>
      <devices>
        <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='${libvirtCfg.image}'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        ${concatMapStringsSep "\n        " (bridge: ''
        <interface type='bridge'>
          <source bridge='${bridge}'/>
          <model type='virtio'/>
        </interface>'') netCfg.bridges}
        <graphics type='spice' autoport='yes'>
          <listen type='address' address='127.0.0.1'/>
        </graphics>
        <video>
          <model type='virtio'/>
        </video>
        <channel type='unix'>
          <target type='virtio' name='org.qemu.guest_agent.0'/>
        </channel>
        <console type='pty'>
          <target type='serial' port='0'/>
        </console>
        <!-- PCI_PASSTHROUGH_PLACEHOLDER - replaced at runtime if WiFi detected -->
      </devices>
    </domain>
  '';

  # Script to detect WAN interface and configure passthrough
  wanDetectionScript = pkgs.writeShellScript "router-wan-detect" ''
    set -euo pipefail

    STATE_DIR="/var/lib/hydrix/router"
    mkdir -p "$STATE_DIR"

    log() { echo "[router-wan-detect] $*"; }

    # Detect WiFi PCI device
    detect_wifi_pci() {
      # Method 1: Find wireless interface and get its PCI address
      for iface in /sys/class/net/wl*; do
        [ -e "$iface" ] || continue
        local name=$(basename "$iface")
        if [ -d "$iface/device" ]; then
          local pci_path=$(readlink -f "$iface/device" 2>/dev/null || true)
          local pci_addr=$(basename "$pci_path" 2>/dev/null || echo "")
          if [ -n "$pci_addr" ] && [ "$pci_addr" != "device" ]; then
            echo "$pci_addr"
            return 0
          fi
        fi
      done

      # Method 2: Scan PCI directly for wireless devices
      ${pkgs.pciutils}/bin/lspci -D -nn 2>/dev/null | \
        grep -iE 'network.*wireless|wireless.*network|wi-fi|802\.11' | \
        head -1 | awk '{print $1}' || true
    }

    # Detect first physical ethernet (for macvtap fallback)
    detect_ethernet() {
      for iface in /sys/class/net/*; do
        local name=$(basename "$iface")
        # Skip virtual interfaces
        [[ "$name" == "lo" ]] && continue
        [[ "$name" == br-* ]] && continue
        [[ "$name" == virbr* ]] && continue
        [[ "$name" == veth* ]] && continue
        [[ "$name" == docker* ]] && continue
        [[ "$name" == wl* ]] && continue
        # Check if it's physical (has a device link)
        [ -d "$iface/device" ] || continue
        echo "$name"
        return 0
      done
    }

    WAN_MODE="${libvirtCfg.wan.mode}"
    WAN_DEVICE="${if libvirtCfg.wan.device != null then libvirtCfg.wan.device else ""}"
    PREFER_WIRELESS="${boolToString libvirtCfg.wan.preferWireless}"

    WAN_TYPE=""
    WAN_VALUE=""

    case "$WAN_MODE" in
      auto)
        if [ -n "$WAN_DEVICE" ]; then
          # User specified device, detect type
          if [[ "$WAN_DEVICE" =~ ^[0-9a-f]{4}: ]]; then
            WAN_TYPE="pci"
            WAN_VALUE="$WAN_DEVICE"
          else
            WAN_TYPE="macvtap"
            WAN_VALUE="$WAN_DEVICE"
          fi
        else
          # Auto-detect: prefer WiFi PCI passthrough
          if [ "$PREFER_WIRELESS" = "true" ]; then
            WIFI_PCI=$(detect_wifi_pci)
            if [ -n "$WIFI_PCI" ]; then
              WAN_TYPE="pci"
              WAN_VALUE="$WIFI_PCI"
              log "Auto-detected WiFi at $WIFI_PCI"
            fi
          fi

          # Fallback to macvtap on ethernet
          if [ -z "$WAN_TYPE" ]; then
            ETH=$(detect_ethernet)
            if [ -n "$ETH" ]; then
              WAN_TYPE="macvtap"
              WAN_VALUE="$ETH"
              log "No WiFi found, using macvtap on $ETH"
            fi
          fi

          if [ -z "$WAN_TYPE" ]; then
            log "ERROR: No suitable WAN interface found"
            exit 1
          fi
        fi
        ;;

      pci-passthrough)
        WAN_TYPE="pci"
        WAN_VALUE="''${WAN_DEVICE:-$(detect_wifi_pci)}"
        if [ -z "$WAN_VALUE" ]; then
          log "ERROR: PCI passthrough requested but no WiFi device found"
          exit 1
        fi
        ;;

      macvtap)
        WAN_TYPE="macvtap"
        WAN_VALUE="''${WAN_DEVICE:-$(detect_ethernet)}"
        if [ -z "$WAN_VALUE" ]; then
          log "ERROR: macvtap requested but no ethernet device found"
          exit 1
        fi
        ;;

      none)
        WAN_TYPE="none"
        WAN_VALUE=""
        log "WAN disabled - router will have no internet uplink"
        ;;
    esac

    log "WAN: $WAN_TYPE = $WAN_VALUE"
    echo "$WAN_TYPE" > "$STATE_DIR/wan_type"
    echo "$WAN_VALUE" > "$STATE_DIR/wan_value"
  '';

in {
  config = mkIf (cfg.vmType == "host" && routerCfg.type == "libvirt") {
    # Rebuild script for libvirt router
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "rebuild-libvirt-router" ''
        set -euo pipefail

        ROUTER_IMAGE="${libvirtCfg.image}"
        ROUTER_VM="${libvirtCfg.vmName}"

        # Auto-detect flake location
        if [[ -n "''${HYDRIX_FLAKE_DIR:-}" ]]; then
          FLAKE_DIR="$HYDRIX_FLAKE_DIR"
        elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
          FLAKE_DIR="$HOME/hydrix-config"
        elif [[ -f "$HOME/Hydrix/flake.nix" ]]; then
          FLAKE_DIR="$HOME/Hydrix"
        else
          echo "Error: No Hydrix config found" >&2
          exit 1
        fi

        cd "$FLAKE_DIR"

        echo "=== Rebuilding Libvirt Router VM ==="

        # Build new router image
        echo "[1/4] Building router image..."
        if command -v nom &> /dev/null; then
          nom build .#router --out-link router-result
        else
          nix build .#router --out-link router-result
        fi

        # Stop router VM if running
        echo "[2/4] Stopping router VM..."
        sudo ${pkgs.libvirt}/bin/virsh destroy "$ROUTER_VM" 2>/dev/null || true
        sleep 2

        # Replace old image with new one
        echo "[3/4] Deploying new image..."
        sudo rm -f "$ROUTER_IMAGE"

        # Handle both qcow2 and raw formats
        if [[ -f router-result/nixos.qcow2 ]]; then
          sudo cp router-result/nixos.qcow2 "$ROUTER_IMAGE"
        elif [[ -f router-result/nixos.raw ]]; then
          echo "  Converting raw image to qcow2..."
          sudo ${pkgs.qemu}/bin/qemu-img convert -f raw -O qcow2 router-result/nixos.raw "$ROUTER_IMAGE"
        else
          echo "ERROR: No image found in build result"
          ls -la router-result/
          exit 1
        fi
        sudo chmod 644 "$ROUTER_IMAGE"

        # Clean up build link
        rm -f router-result

        echo "[4/4] Starting router VM..."
        sudo ${pkgs.libvirt}/bin/virsh start "$ROUTER_VM"

        echo ""
        echo "=== Libvirt Router VM Rebuilt ==="
        echo "Management IP: 192.168.100.253"
        echo "Console: sudo virsh console $ROUTER_VM"
      '')
    ];

    # State directory for runtime info
    systemd.tmpfiles.rules = [
      "d /var/lib/hydrix 0755 root root -"
      "d /var/lib/hydrix/router 0755 root root -"
    ];

    # WAN detection service (runs before router spawn)
    systemd.services.hydrix-router-wan-detect = {
      description = "Detect WAN interface for Hydrix router VM";
      after = [ "network.target" ];
      before = [ "hydrix-router-spawn.service" ];
      wantedBy = mkIf routerCfg.autostart [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = with pkgs; [ pciutils iproute2 coreutils gnugrep gawk ];
      script = "${wanDetectionScript}";
    };

    # Router VM spawn/manage service
    systemd.services.hydrix-router-spawn = {
      description = "Spawn and manage Hydrix router VM";
      after = [ "libvirtd.service" "network.target" "hydrix-router-wan-detect.service" ];
      requires = [ "libvirtd.service" "hydrix-router-wan-detect.service" ];
      wantedBy = mkIf routerCfg.autostart [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "180s";
      };

      path = with pkgs; [ libvirt iproute2 coreutils gnused gnugrep ];

      script = ''
        set -euo pipefail

        STATE_DIR="/var/lib/hydrix/router"
        VM_NAME="${libvirtCfg.vmName}"
        VM_IMAGE="${libvirtCfg.image}"
        BASE_XML="${routerXml}"

        log() { echo "[hydrix-router-spawn] $*"; }

        # Wait for bridges to exist
        log "Waiting for bridges..."
        for br in ${concatStringsSep " " netCfg.bridges}; do
          TIMEOUT=60
          ELAPSED=0
          while ! ip link show "$br" >/dev/null 2>&1; do
            if [ $ELAPSED -ge $TIMEOUT ]; then
              log "ERROR: Timeout waiting for bridge $br"
              exit 1
            fi
            sleep 1
            ELAPSED=$((ELAPSED + 1))
          done
          log "  + $br exists"
        done

        # Check for router VM image
        if [ ! -f "$VM_IMAGE" ]; then
          log "ERROR: Router VM image not found at $VM_IMAGE"
          log "Build with: cd ~/hydrix-config && nix build .#router"
          log "Then copy:  sudo cp result/nixos.qcow2 $VM_IMAGE"
          exit 1
        fi

        # Read WAN detection results
        WAN_TYPE=$(cat "$STATE_DIR/wan_type" 2>/dev/null || echo "none")
        WAN_VALUE=$(cat "$STATE_DIR/wan_value" 2>/dev/null || echo "")

        log "WAN type: $WAN_TYPE, value: $WAN_VALUE"

        # Generate final XML with WAN device
        FINAL_XML="/tmp/router-vm-$$.xml"
        cp "$BASE_XML" "$FINAL_XML"

        if [ "$WAN_TYPE" = "pci" ] && [ -n "$WAN_VALUE" ]; then
          # Parse PCI address (format: 0000:02:00.0 or 02:00.0)
          PCI_FULL="$WAN_VALUE"
          [[ "$PCI_FULL" != *:*:* ]] && PCI_FULL="0000:$PCI_FULL"

          PCI_DOMAIN=$(echo "$PCI_FULL" | cut -d: -f1)
          PCI_BUS=$(echo "$PCI_FULL" | cut -d: -f2)
          PCI_SLOT=$(echo "$PCI_FULL" | cut -d: -f3 | cut -d. -f1)
          PCI_FUNC=$(echo "$PCI_FULL" | cut -d. -f2)

          # Convert hex to decimal for libvirt
          PCI_DOMAIN_DEC=$((16#$PCI_DOMAIN))
          PCI_BUS_DEC=$((16#$PCI_BUS))
          PCI_SLOT_DEC=$((16#$PCI_SLOT))
          PCI_FUNC_DEC=$PCI_FUNC

          # Single-line XML for sed compatibility
          HOSTDEV_XML="<hostdev mode='subsystem' type='pci' managed='yes'><source><address domain='0x$PCI_DOMAIN' bus='0x$PCI_BUS' slot='0x$PCI_SLOT' function='0x$PCI_FUNC'/></source></hostdev>"

          sed -i "s|<!-- PCI_PASSTHROUGH_PLACEHOLDER[^>]*-->|$HOSTDEV_XML|" "$FINAL_XML"
          log "Added PCI passthrough for $PCI_FULL"

        elif [ "$WAN_TYPE" = "macvtap" ] && [ -n "$WAN_VALUE" ]; then
          MACVTAP_XML="<interface type='direct'><source dev='$WAN_VALUE' mode='bridge'/><model type='virtio'/></interface>"

          sed -i "s|<!-- PCI_PASSTHROUGH_PLACEHOLDER[^>]*-->|$MACVTAP_XML|" "$FINAL_XML"
          log "Added macvtap interface on $WAN_VALUE"

        else
          # Remove placeholder, no WAN
          sed -i '/<!-- PCI_PASSTHROUGH_PLACEHOLDER/d' "$FINAL_XML"
          log "No WAN interface configured"
        fi

        # Undefine existing VM if it exists (to update config)
        if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
          VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
          if [ "$VM_STATE" = "running" ]; then
            log "Stopping existing router VM..."
            virsh destroy "$VM_NAME" 2>/dev/null || true
            sleep 2
          fi
          log "Removing old VM definition..."
          virsh undefine "$VM_NAME" 2>/dev/null || true
        fi

        # Define and start VM
        log "Defining router VM..."
        virsh define "$FINAL_XML"
        rm -f "$FINAL_XML"

        log "Starting router VM..."
        virsh start "$VM_NAME"

        # Enable autostart in libvirt
        virsh autostart "$VM_NAME" 2>/dev/null || true

        # Verify it's running
        sleep 2
        VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
        if [ "$VM_STATE" = "running" ]; then
          log "Router VM running successfully"
          log "Management IP: 192.168.100.253 (once DHCP configured)"
        else
          log "WARNING: Router VM state is $VM_STATE"
          exit 1
        fi
      '';
    };

    # Stop service to cleanly shutdown router VM
    systemd.services.hydrix-router-spawn.serviceConfig.ExecStop = pkgs.writeShellScript "router-stop" ''
      VM_NAME="${libvirtCfg.vmName}"
      if ${pkgs.libvirt}/bin/virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
        echo "Shutting down router VM..."
        ${pkgs.libvirt}/bin/virsh shutdown "$VM_NAME" 2>/dev/null || true
        # Wait up to 30s for graceful shutdown
        for i in $(seq 1 30); do
          if ! ${pkgs.libvirt}/bin/virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
            echo "Router VM stopped gracefully"
            exit 0
          fi
          sleep 1
        done
        # Force stop if graceful shutdown failed
        echo "Forcing router VM stop..."
        ${pkgs.libvirt}/bin/virsh destroy "$VM_NAME" 2>/dev/null || true
      fi
    '';
  };
}
