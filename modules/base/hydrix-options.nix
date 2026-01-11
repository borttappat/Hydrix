# Hydrix Options - Centralized configuration for all Hydrix modules
#
# This module is the SINGLE SOURCE OF TRUTH for:
# - hydrix.vmType (pentest, comms, browsing, dev, host, or null)
# - hydrix.colorscheme (name of colorscheme from colorschemes/*.json)
# - hydrix.username (computed once, used everywhere)
# - hydrix.vm.* options (for VM-specific configuration)
#
# IMPORTANT: This module must be imported BEFORE other modules that use config.hydrix.*
# The username detection logic avoids absolute paths in pure mode (VM builds).

{ config, lib, pkgs, ... }:

let
  # Get hostname (used to find secrets file for VMs)
  hostname = config.networking.hostName;

  # Check if we're building for a VM
  # vmType is set by profiles (e.g., hydrix.vmType = "pentest")
  # "host" is used for host configurations, null means not set
  isVM = (config.hydrix.vmType or null) != null && config.hydrix.vmType != "host";

  # === VM Username Detection ===
  # For VMs: read from secrets file using relative path
  # Path: local/vms/<hostname>.nix from flake root
  vmSecretsPath = ../../local/vms/${hostname}.nix;
  vmSecrets = if isVM && builtins.pathExists vmSecretsPath
    then import vmSecretsPath
    else {};
  vmUsername = vmSecrets.username or "user";

  # === Host Username Detection ===
  # For hosts: detect from environment or config file (requires --impure)
  # This is only evaluated when NOT building a VM
  #
  # We use builtins.tryEval to safely handle pure mode:
  # - In impure mode: evaluates the path-based detection
  # - In pure mode: returns null (but we won't use it for VMs anyway)
  envDetection = let
    # These builtins.getEnv calls return "" in pure mode, which is fine
    hydrixPath = builtins.getEnv "HYDRIX_PATH";
    sudoUser = builtins.getEnv "SUDO_USER";
    currentUser = builtins.getEnv "USER";
    effectiveUser = if sudoUser != "" then sudoUser
                    else if currentUser != "" && currentUser != "root" then currentUser
                    else "user";
  in {
    inherit effectiveUser hydrixPath;
    # Only construct the basePath string if we have a hydrixPath (impure mode)
    # Otherwise use a dummy value that won't be used
    basePath = if hydrixPath != "" then hydrixPath else null;
  };

  # Host config file (only loaded for non-VM builds)
  # First try relative path (works in impure mode), then fallback to HYDRIX_PATH
  localHostPath = ../../local/host.nix;

  hostConfig = if isVM then null
    else if builtins.pathExists localHostPath then import localHostPath
    else if envDetection.basePath != null then
      let
        hostConfigPath = envDetection.basePath + "/local/host.nix";
      in if builtins.pathExists hostConfigPath then import hostConfigPath else null
    else null;

  # Compute the final username
  computedUsername =
    if isVM then vmUsername
    else if hostConfig != null && hostConfig ? username then hostConfig.username
    else envDetection.effectiveUser;

in {
  options.hydrix = {
    vmType = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "pentest" "comms" "browsing" "dev" "host" ]);
      default = null;
      description = "Type of system (pentest, comms, browsing, dev, host, or null)";
    };

    colorscheme = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of colorscheme from colorschemes/*.json";
      example = "nvid";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = computedUsername;
      readOnly = true;
      description = ''
        Computed username for this system.
        - For VMs: read from local/vms/<hostname>.nix secrets file
        - For hosts: read from local/host.nix or detected from environment
        This option is read-only; the value is computed automatically.
      '';
    };

    # VM-specific options (nested under hydrix.vm.*)
    # Note: hydrix.vm.sharedStore is defined in modules/vm/shared-store.nix
    vm = {
      user = lib.mkOption {
        type = lib.types.str;
        default = vmUsername;
        readOnly = true;
        description = "Alias for hydrix.username (for backwards compatibility)";
      };
    };
  };

  # Make username available as config value
  config = {
    # Assertions to help debug
    assertions = [
      {
        assertion = config.hydrix.username != "";
        message = "hydrix.username cannot be empty";
      }
    ];
  };
}
