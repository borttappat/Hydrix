#!/run/current-system/sw/bin/bash
# hardware-identify.sh - Identify system requirements for VM router setup

set -euo pipefail

# Check if we have existing hardware results and are in router mode
if [[ -f "hardware-results.env" ]]; then
    if ip addr show virbr1 >/dev/null 2>&1 && [[ "$(ip route | grep default | awk '{print $5}' | head -1)" == "virbr1" ]]; then
        echo "Router mode detected - using existing hardware results"
        source hardware-results.env
        if [[ -n "${PRIMARY_INTERFACE:-}" && -n "${PRIMARY_PCI:-}" && -n "${PRIMARY_ID:-}" ]]; then
            echo "✓ Found: $PRIMARY_INTERFACE ($PRIMARY_ID) on $PRIMARY_PCI"
            echo "✓ Compatibility: ${COMPATIBILITY_SCORE:-0}/10"
            exit 0
        fi
    fi
fi

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root"
    exit 1
fi

echo "=== Hardware Identification for VM Router Setup ==="
echo

# 1. Check IOMMU support
echo "1. IOMMU Support:"
if sudo dmesg | grep -qi "iommu.*enabled\|intel-iommu.*enabled\|iommu.*force.*enabled\|dmar.*intel-iommu"; then
    echo "   ✓ IOMMU is enabled"
    # Double-check by looking for IOMMU groups
    if [[ -d "/sys/kernel/iommu_groups" ]] && [[ -n "$(ls /sys/kernel/iommu_groups/ 2>/dev/null)" ]]; then
        echo "   ✓ IOMMU groups found"
        IOMMU_OK=true
    else
        echo "   ⚠ IOMMU enabled but no groups found"
        IOMMU_OK=false
    fi
else
    # Fallback: check for IOMMU groups even if dmesg doesn't show clear enabled message
    if [[ -d "/sys/kernel/iommu_groups" ]] && [[ -n "$(ls /sys/kernel/iommu_groups/ 2>/dev/null)" ]]; then
        echo "   ✓ IOMMU is working (groups detected)"
        IOMMU_OK=true
    else
        echo "   ✗ IOMMU not enabled or not supported"
        IOMMU_OK=false
    fi
fi
echo

# 2. Find all network interfaces
echo "2. Network Interfaces:"
while read -r interface; do
        # Initialize variables for each interface
        pci_slot="unknown"
        vendor_device="unknown"
        driver="unknown"
    if [[ "$interface" != "lo" ]]; then
        echo "   Interface: $interface"
        
        # Check if it's a physical device
        if [[ -d "/sys/class/net/$interface/device" ]]; then
            # Get PCI slot
            pci_slot=$(basename "$(readlink "/sys/class/net/$interface/device" 2>/dev/null)" 2>/dev/null || echo "unknown")
            echo "     PCI Slot: $pci_slot"
            
            # Get device info
            if [[ "$pci_slot" != "unknown" ]]; then
                device_info=$(lspci -nn -s "$pci_slot" 2>/dev/null || echo "Device info not available")
                echo "     Device: $device_info"
                
                # Get vendor:device ID
                vendor_device=$(echo "$device_info" | grep -o '\[[0-9a-f]\{4\}:[0-9a-f]\{4\}\]' | tr -d '[]' || echo "unknown")
                echo "     ID: $vendor_device"
                
                # Check driver
                if [[ -r "/sys/class/net/$interface/device/uevent" ]]; then
                    driver=$(grep "DRIVER=" "/sys/class/net/$interface/device/uevent" | cut -d= -f2 2>/dev/null || echo "unknown")
                    echo "     Driver: $driver"
                fi
            fi
        else
            echo "     Type: Virtual interface"
        fi
        
        # Check if interface is up and has connectivity
        if ip link show "$interface" | grep -q "state UP"; then
            echo "     Status: UP"
            if [[ "$interface" == $(ip route | grep default | awk '{print $5}' | head -1) ]]; then
                echo "     Role: Primary (default route)"
                PRIMARY_INTERFACE="$interface"
                PRIMARY_PCI="$pci_slot"
                PRIMARY_ID="$vendor_device"
                PRIMARY_DRIVER="$driver"
            fi
        else
            echo "     Status: DOWN"
        fi
        echo
    fi
done < <(ls /sys/class/net/)

# 3. Check IOMMU groups for primary interface
if [[ "${PRIMARY_INTERFACE:-}" && "${PRIMARY_PCI:-}" && "$PRIMARY_PCI" != "unknown" ]]; then
    echo "3. IOMMU Group Analysis for Primary Interface ($PRIMARY_INTERFACE):"
    
    if [[ -L "/sys/bus/pci/devices/$PRIMARY_PCI/iommu_group" ]]; then
        iommu_group=$(basename "$(readlink "/sys/bus/pci/devices/$PRIMARY_PCI/iommu_group")")
        echo "   IOMMU Group: $iommu_group"
        
        echo "   Devices in this group:"
        group_devices=$(ls "/sys/kernel/iommu_groups/$iommu_group/devices/" 2>/dev/null || echo "")
        device_count=0
        
        for device in $group_devices; do
            device_count=$((device_count + 1))
            device_info=$(lspci -nn -s "$device" 2>/dev/null || echo "Unknown device")
            if [[ "$device" == "$PRIMARY_PCI" ]]; then
                echo "     $device: $device_info (PRIMARY NETWORK)"
            else
                echo "     $device: $device_info"
            fi
        done
        
        if [[ $device_count -eq 1 ]]; then
            echo "   ✓ Device is isolated (ideal for passthrough)"
            IOMMU_ISOLATED=true
        else
            echo "   ⚠ Device shares group with $((device_count - 1)) other devices"
            IOMMU_ISOLATED=false
        fi
    else
        echo "   ✗ Device not in any IOMMU group"
        IOMMU_ISOLATED=false
    fi
else
    echo "3. IOMMU Group Analysis:"
    echo "   ✗ No primary network interface found"
    IOMMU_ISOLATED=false
fi
echo

# 4. Alternative interfaces check
echo "4. Alternative Network Interfaces:"
alt_count=0
while read -r interface; do
        # Initialize variables for each interface
        pci_slot="unknown"
        vendor_device="unknown"
        driver="unknown"
    if [[ "$interface" != "lo" && "$interface" != "${PRIMARY_INTERFACE:-}" && -d "/sys/class/net/$interface/device" ]]; then
        echo "   Alternative: $interface"
        alt_count=$((alt_count + 1))
    fi
done < <(ls /sys/class/net/)

if [[ $alt_count -eq 0 ]]; then
    echo "   ✗ No alternative network interfaces found"
    echo "   Consider: USB-to-Ethernet adapter for fallback"
    ALT_INTERFACES=false
else
    echo "   ✓ $alt_count alternative interface(s) available for fallback"
    ALT_INTERFACES=true
fi
echo

# 5. Compatibility Assessment
echo "5. Compatibility Assessment:"
score=0

if [[ "$IOMMU_OK" == true ]]; then
    echo "   ✓ IOMMU support: +3 points"
    score=$((score + 3))
else
    echo "   ✗ IOMMU support: 0 points (REQUIRED)"
fi

if [[ "${PRIMARY_INTERFACE:-}" ]]; then
    echo "   ✓ Primary network interface found: +2 points"
    score=$((score + 2))
else
    echo "   ✗ Primary network interface: 0 points"
fi

if [[ "$IOMMU_ISOLATED" == true ]]; then
    echo "   ✓ IOMMU isolation: +3 points"
    score=$((score + 3))
elif [[ "${IOMMU_ISOLATED:-}" == false ]] && [[ "${PRIMARY_INTERFACE:-}" ]]; then
    echo "   ⚠ IOMMU shared group: +1 point"
    score=$((score + 1))
else
    echo "   ✗ IOMMU isolation: 0 points"
fi

if [[ "$ALT_INTERFACES" == true ]]; then
    echo "   ✓ Alternative interfaces: +2 points"
    score=$((score + 2))
else
    echo "   ✗ Alternative interfaces: 0 points"
fi

echo
echo "Total Score: $score/10"

if [[ $score -ge 8 ]]; then
    echo "✓ EXCELLENT: Setup should work reliably"
    recommendation="PROCEED"
elif [[ $score -ge 5 ]]; then
    echo "⚠ GOOD: Setup should work with some risks"
    recommendation="PROCEED_WITH_CAUTION"
else
    echo "✗ POOR: Setup likely to have significant issues"
    recommendation="REDESIGN_REQUIRED"
fi

# 6. Summary output for next steps
echo
echo "=== Summary ==="
echo "Primary Interface: ${PRIMARY_INTERFACE:-none}"
echo "PCI Slot: ${PRIMARY_PCI:-none}"
echo "Vendor:Device ID: ${PRIMARY_ID:-none}"
echo "Driver: ${PRIMARY_DRIVER:-none}"
echo "IOMMU Isolated: ${IOMMU_ISOLATED:-false}"
echo "Alternative Interfaces: ${ALT_INTERFACES:-false}"
echo "Recommendation: $recommendation"

# Save results for potential automation
cat > hardware-results.env << EOF
PRIMARY_INTERFACE=${PRIMARY_INTERFACE:-}
PRIMARY_PCI=${PRIMARY_PCI:-}
PRIMARY_ID=${PRIMARY_ID:-}
PRIMARY_DRIVER=${PRIMARY_DRIVER:-}
IOMMU_ISOLATED=${IOMMU_ISOLATED:-false}
ALT_INTERFACES=${ALT_INTERFACES:-false}
COMPATIBILITY_SCORE=$score
RECOMMENDATION=$recommendation
EOF

# Convert bash booleans to JSON booleans
iommu_isolated_json=$(if [[ "$IOMMU_ISOLATED" == true ]]; then echo "true"; else echo "false"; fi)
alt_interfaces_json=$(if [[ "$ALT_INTERFACES" == true ]]; then echo "true"; else echo "false"; fi)

# Save as JSON for Nix consumption
cat > hardware-results.json << JSONEOF
{
  "PRIMARY_INTERFACE": "${PRIMARY_INTERFACE:-}",
  "PRIMARY_PCI": "${PRIMARY_PCI:-}",
  "PRIMARY_ID": "${PRIMARY_ID:-}",
  "PRIMARY_DRIVER": "${PRIMARY_DRIVER:-}",
  "IOMMU_ISOLATED": $iommu_isolated_json,
  "ALT_INTERFACES": $alt_interfaces_json,
  "COMPATIBILITY_SCORE": $score,
  "RECOMMENDATION": "$recommendation"
}
JSONEOF

echo
echo "Results saved to: hardware-results.env and hardware-results.json"
