{ config, lib, pkgs, ... }:

{
  # Static color theming for VMs
  #
  # This module generates a static pywal color cache based on VM type
  # The colors are generated once and remain consistent across reboots
  #
  # VM Types:
  # - pentest:  Red theme (#ea6c73)   - Security/offensive focus
  # - comms:    Blue theme (#6c89ea)  - Communication/messaging
  # - browsing: Green theme (#73ea6c) - Web browsing/general use
  # - dev:      Purple theme (#ba6cea) - Development/coding

  imports = [ ./base.nix ];

  # Define VM type option
  options.hydrix.vmType = lib.mkOption {
    type = lib.types.enum [ "pentest" "comms" "browsing" "dev" ];
    description = "VM type for static color scheme generation";
    default = "pentest";
  };

  config = let
    staticColorsScript = pkgs.writeShellScriptBin "vm-static-colors"
      (builtins.readFile ../../scripts/vm-static-colors.sh);
  in {
    # Add static color generator script to system
    environment.systemPackages = [ staticColorsScript ];

    # Generate static pywal cache on first boot
    # This runs once and creates a persistent color scheme
    systemd.services.vm-static-colors = {
      description = "Generate static color scheme for ${config.hydrix.vmType} VM";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Only run if not already generated
      unitConfig = {
        ConditionPathExists = "!/home/traum/.cache/wal/.static-colors-generated";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "traum";
      };

      script = ''
        echo "Generating static color scheme for ${config.hydrix.vmType}"
        ${staticColorsScript}/bin/vm-static-colors ${config.hydrix.vmType}
      '';
    };
  };
}
