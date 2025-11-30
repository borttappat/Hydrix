#!/usr/bin/env bash

# Test script for nixbuild.sh machine detection logic
# This simulates different hardware configurations to verify detection works

echo "======================================"
echo "Testing nixbuild.sh Detection Logic"
echo "======================================"
echo ""

# Get actual system information
ARCH=$(uname -m)
VENDOR=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
MODEL=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
CHASSIS=$(hostnamectl | grep -i "Chassis" | awk -F': ' '{print $2}' | xargs)
HOSTNAME=$(hostnamectl hostname)

echo "Current System Information:"
echo "  Architecture: $ARCH"
echo "  Chassis: $CHASSIS"
echo "  Vendor: $VENDOR"
echo "  Model: $MODEL"
echo "  Hostname: $HOSTNAME"
echo ""

# Detect what configuration would be used
echo "Detection Results:"
echo ""

# ARM Detection
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || [[ "$VENDOR" == *"Apple"* && ("$ARCH" == *"arm"* || "$ARCH" == *"aarch"*) ]]; then
    echo "✓ Would build: armVM (ARM architecture detected)"
    exit 0
fi

# VM Detection
if [[ "$CHASSIS" == "vm" ]] || echo "$VENDOR" | grep -q "QEMU\|VMware"; then
    echo "✓ Detected as: Virtual Machine"

    if [[ "$HOSTNAME" =~ ^pentest- ]]; then
        echo "✓ Would build: vm-pentest"
    elif [[ "$HOSTNAME" =~ ^comms- ]]; then
        echo "✓ Would build: vm-comms"
    elif [[ "$HOSTNAME" =~ ^browsing- ]]; then
        echo "✓ Would build: vm-browsing"
    elif [[ "$HOSTNAME" =~ ^dev- ]]; then
        echo "✓ Would build: vm-dev"
    elif [[ "$HOSTNAME" =~ ^router- ]] || [[ "$HOSTNAME" == "router-vm" ]]; then
        echo "✓ Would build: vm-router"
    else
        echo "✗ Unknown VM type - hostname doesn't match expected pattern"
        echo "  Expected: pentest-*, comms-*, browsing-*, dev-*, router-*"
    fi
    exit 0
fi

# Physical Machine Detection
echo "✓ Detected as: Physical Machine"
echo ""

# Zephyrus
if echo "$MODEL" | grep -qi "zephyrus"; then
    echo "✓ Would build: zephyrus (with specialisation support)"
    echo "  Machine: ASUS Zephyrus"
    exit 0
fi

# Zenbook
if echo "$MODEL" | grep -qi "zenbook"; then
    echo "✓ Would build: zenbook (with specialisation support)"
    echo "  Machine: ASUS Zenbook"
    exit 0
fi

# Razer
if echo "$VENDOR" | grep -q "Razer"; then
    echo "✓ Would build: razer"
    echo "  Machine: Razer laptop"
    exit 0
fi

# Schenker/XMG
if echo "$VENDOR" | grep -q "Schenker"; then
    echo "✓ Would build: xmg"
    echo "  Machine: Schenker/XMG laptop"
    exit 0
fi

# Generic ASUS
if echo "$VENDOR" | grep -q "ASUS"; then
    echo "✓ Would build: asus"
    echo "  Machine: Generic ASUS laptop"
    exit 0
fi

# Fallback
echo "✓ Would build: host (fallback configuration)"
echo "  Unknown hardware - using generic host config"
echo ""
echo "To add support for this machine:"
echo "  1. Create profile in profiles/machines/{name}.nix"
echo "  2. Add entry to flake.nix"
echo "  3. Add detection block in nixbuild.sh"
