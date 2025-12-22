# ASUS-specific hardware configuration
# Include this module for ASUS laptops (ROG, Zenbook, etc.)
#
# Provides:
#   - asusd service for ASUS laptop control
#   - Battery charge limit management
#   - ASUS-specific power management
#   - Helper scripts for ASUS features

{ config, pkgs, lib, ... }:

{
  # Enable asusd for ASUS laptop control
  services.asusd = {
    enable = true;
  };

  # ASUS-specific packages
  environment.systemPackages = with pkgs; [
    asusctl
    acpi
    powertop

    # Battery charge limit script
    (writeShellScriptBin "set-battery-limit" ''
      #!/bin/sh
      if [ -z "$1" ]; then
        echo "Usage: set-battery-limit <percentage>"
        echo "Example: set-battery-limit 80"
        echo ""
        echo "Current limit:"
        ${pkgs.asusctl}/bin/asusctl -c
        exit 1
      fi

      limit="$1"

      if ! [ "$limit" -eq "$limit" ] 2>/dev/null || [ "$limit" -lt 20 ] || [ "$limit" -gt 100 ]; then
        echo "Error: Limit must be a number between 20 and 100"
        exit 1
      fi

      echo "Setting battery charge limit to $limit%..."
      ${pkgs.asusctl}/bin/asusctl -c "$limit"
      echo "Battery charge limit set to $limit%"
    '')

    # Show current ASUS hardware status
    (writeShellScriptBin "asus-status" ''
      #!/bin/sh
      echo "ASUS Hardware Status"
      echo "===================="
      echo ""
      echo "Battery:"
      ${pkgs.asusctl}/bin/asusctl -c
      echo ""
      echo "Performance Profile:"
      ${pkgs.asusctl}/bin/asusctl profile -p
      echo ""
      echo "Fan Curves:"
      ${pkgs.asusctl}/bin/asusctl fan-curve -g 2>/dev/null || echo "  (not available on this model)"
      echo ""
      echo "LED Mode:"
      ${pkgs.asusctl}/bin/asusctl led-mode -g 2>/dev/null || echo "  (not available on this model)"
    '')

    # Quick profile switcher
    (writeShellScriptBin "asus-profile" ''
      #!/bin/sh
      case "$1" in
        quiet|Quiet)
          ${pkgs.asusctl}/bin/asusctl profile -P Quiet
          echo "Switched to Quiet profile"
          ;;
        balanced|Balanced)
          ${pkgs.asusctl}/bin/asusctl profile -P Balanced
          echo "Switched to Balanced profile"
          ;;
        performance|Performance)
          ${pkgs.asusctl}/bin/asusctl profile -P Performance
          echo "Switched to Performance profile"
          ;;
        *)
          echo "Usage: asus-profile <quiet|balanced|performance>"
          echo ""
          echo "Current profile:"
          ${pkgs.asusctl}/bin/asusctl profile -p
          ;;
      esac
    '')
  ];
}
