#!/usr/bin/env bash
# Test script to verify shaping service logic
# Run this manually to test without rebuilding base image

set -euo pipefail

echo "=== Testing Hydrix VM Shaping Logic ==="

# Extract VM type from hostname (e.g., "pentest-google" -> "pentest")
HOSTNAME=$(hostname)
VM_TYPE="${HOSTNAME%%-*}"

echo "Hostname: $HOSTNAME"
echo "VM Type: $VM_TYPE"

# Map VM type to flake entry
case "$VM_TYPE" in
  pentest)
    FLAKE_ENTRY="vm-pentest"
    ;;
  comms)
    FLAKE_ENTRY="vm-comms"
    ;;
  browsing)
    FLAKE_ENTRY="vm-browsing"
    ;;
  dev)
    FLAKE_ENTRY="vm-dev"
    ;;
  *)
    echo "✗ ERROR: Unknown VM type: $VM_TYPE"
    echo "Expected: pentest, comms, browsing, or dev"
    exit 1
    ;;
esac

echo "Flake Entry: $FLAKE_ENTRY"

# Hydrix directory
HYDRIX_DIR="/home/traum/Hydrix"
if [ ! -d "$HYDRIX_DIR" ]; then
  echo "✗ ERROR: Hydrix directory not found at $HYDRIX_DIR"
  exit 1
fi

echo "✓ Hydrix repository found at $HYDRIX_DIR"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "✗ ERROR: This script must be run as root (like the systemd service)"
  echo "Please run: sudo $0"
  exit 1
fi

# Apply full VM profile using nixos-rebuild directly
echo "Applying full profile: $FLAKE_ENTRY"
cd "$HYDRIX_DIR"

echo ""
echo "Would run: nixos-rebuild switch --flake \".#$FLAKE_ENTRY\" --impure"
echo ""
read -p "Continue with actual rebuild? [y/N]: " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Skipping rebuild. Test logic appears correct!"
  exit 0
fi

if nixos-rebuild switch --flake ".#$FLAKE_ENTRY" --impure; then
  echo "✓ System rebuild completed"
  echo "✓ Would mark VM as shaped: touch /var/lib/hydrix-shaped"
  echo "✓ Would reboot in 5 seconds"
else
  echo "✗ ERROR: System rebuild failed"
  exit 1
fi

echo "=== Shaping Test Completed Successfully ==="
