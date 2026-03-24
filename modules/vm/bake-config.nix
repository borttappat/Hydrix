# Bake Hydrix Configuration into VM Image
#
# This module copies the Hydrix framework into the VM image
# so the VM is self-contained and can rebuild without needing the host.
#
# The config is placed at /home/<user>/hydrix-config and includes:
# - flake.nix and all modules
# - configs/ directory
# - profiles/, colorschemes/, etc.
#
# This enables the "baked + orphaned" model where VMs don't need to
# sync with the host after deployment.

{ config, pkgs, lib, ... }:

let
  # Get the flake root (relative to this module)
  # This module is at modules/vm/bake-config.nix
  # Flake root is at ../..
  hydrixSource = ../..;

  # Username is set via hydrix.username option (see modules/options.nix)
  vmUser = config.hydrix.username;
  vmHome = "/home/${vmUser}";

  # Create a filtered copy of the source that excludes:
  # - .git directory (large, not needed in VM)
  # - result symlinks
  # - any build artifacts
  hydrixFiltered = pkgs.runCommand "hydrix-config" {} ''
    mkdir -p $out

    # Copy everything except .git and result symlinks
    cd ${hydrixSource}
    for item in *; do
      if [ "$item" != ".git" ] && [ "$item" != "result" ]; then
        cp -r "$item" $out/ 2>/dev/null || true
      fi
    done

    # Make copied files writable (nix paths are often read-only)
    chmod -R u+w $out

    # Ensure directories exist
    mkdir -p $out/configs
  '';

in {
  # Option to enable/disable config baking
  options.hydrix.vm.bakeConfig = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Bake hydrix-local configuration into VM image";
    };
  };

  config = lib.mkIf config.hydrix.vm.bakeConfig.enable {
    # Copy the Hydrix config to the VM's home directory on first boot
    system.activationScripts.hydrix-config = {
      text = ''
        # Create hydrix-config directory if it doesn't exist
        if [ ! -d "${vmHome}/hydrix-config" ]; then
          echo "Baking Hydrix configuration into ${vmHome}/hydrix-config..."
          mkdir -p "${vmHome}/hydrix-config"
          cp -r ${hydrixFiltered}/* "${vmHome}/hydrix-config/"
          chown -R ${vmUser}:users "${vmHome}/hydrix-config"
          chmod -R u+w "${vmHome}/hydrix-config"
          echo "Hydrix configuration baked successfully"
        else
          echo "hydrix-config directory already exists, skipping bake"
        fi
      '';
      deps = [ "users" ];
    };

    # Also create a marker file indicating this VM has baked config
    environment.etc."hydrix-baked".text = ''
      This VM has Hydrix configuration baked in.
      Config location: ${vmHome}/hydrix-config
      Baked from: ${hydrixSource}

      To rebuild this VM:
        cd ~/hydrix-config && rebuild

      This VM is "orphaned" - it does not need to sync with the host.
      Changes made here stay local to this VM.
    '';
  };
}
