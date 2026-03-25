# Hydrix User Configuration
#
# This flake manages ALL your Hydrix machines from a single location.
# Each machine has its own config file in machines/<serial>.nix
#
# Machine configs are named by HARDWARE SERIAL (not hostname) for:
#   - Automatic reinstall detection (same hardware = same config)
#   - No naming conflicts across machines
#   - Decoupled visual hostname (always "hydrix")
#
# Usage:
#   rebuild                    # Auto-detects machine by serial
#   rebuild administrative     # Switch to admin mode
#   rebuild fallback           # Switch to fallback mode
#
# Manual (if needed):
#   sudo nixos-rebuild switch --flake .#<serial>
#
# For MicroVMs:
#   nix build .#nixosConfigurations.microvm-browsing.config.microvm.declaredRunner

{
  description = "My Hydrix Machines";

  inputs = {
    # Hydrix framework
    # Fork support: change to git+https://github.com/<youruser>/Hydrix.git
    hydrix.url = "git+https://github.com/borttappat/Hydrix.git";

    # Inherit nixpkgs from Hydrix for consistency
    nixpkgs.follows = "hydrix/nixpkgs";
  };

  outputs = { self, hydrix, nixpkgs, ... }@inputs:
  let
    # =========================================================================
    # HOST USERNAME (for builder VM)
    # =========================================================================
    # Set this to your username - used by builder VM to mount ~/hydrix-config
    hostUsername = "user";  # TODO: Change this to your username

    # =========================================================================
    # USER PROFILES
    # =========================================================================
    # Full VM profiles - edit these to customize your VMs
    # Each profile at ./profiles/<name>/ contains:
    #   - default.nix: Main config (colorscheme, settings)
    #   - packages.nix: Packages for this VM type
    #   - packages/: Custom packages added via vm-sync
    userProfiles = ./profiles;

    # =========================================================================
    # USER COLORSCHEMES
    # =========================================================================
    # Custom colorschemes in ./colorschemes/ (pywal JSON format)
    # These extend the framework's built-in colorschemes (nord, nvid, punk, etc.)
    # Your custom schemes take priority over framework ones with the same name.
    # Use them by name in profiles: hydrix.colorscheme = "my-custom-scheme";
    userColorschemesDir = ./colorschemes;

    # =========================================================================
    # VM THEME SYNC MODULE
    # =========================================================================
    # Shares host's wal cache to VMs via virtiofs for instant color sync.
    # Imported by both host (mkHost) and each VM (mkMicroVM).
    # See modules/vm-theme-sync.nix for full documentation.
    vmThemeSyncModule = ./modules/vm-theme-sync.nix;

    # =========================================================================
    # WIFI PCI ADDRESS (auto-detected from machine configs)
    # =========================================================================
    # Extracted from the first machine config that sets hydrix.hardware.vfio.wifiPciAddress.
    # Override manually if auto-detection doesn't work for your setup:
    #   wifiPciAddress = "00:14.3";  # from: lspci -D | grep -i wireless
    wifiPciAddress = let
      configs = builtins.attrValues machineConfigs;
      addresses = map (c: c.config.hydrix.hardware.vfio.wifiPciAddress) configs;
      nonEmpty = builtins.filter (a: a != "") addresses;
    in if nonEmpty != [] then builtins.head nonEmpty else "";

    # =========================================================================
    # HOST CONFIG FOR VMS
    # =========================================================================
    # Settings inherited by all VMs at build time.
    # (Runtime scaling — DPI, pixel sizes — comes from scaling.json automatically)
    #
    # IMPORTANT: Username must match hostUsername for 9p share paths to work.
    # Font family, colorscheme, etc. are also shared so VMs match the host.
    # Host colorscheme — VMs inherit this via vmColors for consistent theming
    hostColorscheme = let
      configs = builtins.attrValues machineConfigs;
      schemes = map (c: c.config.hydrix.colorscheme) configs;
    in builtins.head schemes;

    hostConfig = { ... }: {
      imports = [ ./shared/fonts.nix ];
      hydrix.username = hostUsername;  # Required for 9p shares
      hydrix.vmColors.enable = true;
      hydrix.vmColors.hostColorscheme = hostColorscheme;
    };

    # =========================================================================
    # HELPER: Import all machine configs from machines/ directory
    # =========================================================================
    # Each .nix file in machines/ becomes a host configuration.
    # Files are named by hardware serial (e.g., abc123def.nix).
    # The rebuild script auto-detects the serial and finds the right config.
    machineConfigs = let
      machinesDir = ./machines;
      allNixFiles = builtins.filter
        (name: builtins.match ".*\\.nix" name != null)
        (builtins.attrNames (builtins.readDir machinesDir));
      # Filter out hardware configs (imported by machine configs, not standalone)
      machineFiles = builtins.filter
        (name: builtins.match ".*-hardware\\.nix" name == null)
        allNixFiles;
    in builtins.listToAttrs (map (file: {
      name = builtins.replaceStrings [ ".nix" ] [ "" ] file;
      value = hydrix.lib.mkHost {
        specialArgs = { inherit self; };
        inherit userColorschemesDir;
        modules = [
          (machinesDir + "/${file}")
          ./shared/wifi.nix         # WiFi credentials (shared across machines)
          ./shared/fonts.nix        # Font packages and profiles
          ./shared/i3.nix           # i3 keybindings (user-customizable)
          vmThemeSyncModule         # VM theme sync (host-side)
          { hydrix.vmThemeSync.enable = true; }
          # ./shared/common.nix     # Other shared settings
        ];
      };
    }) machineFiles);

  in {
    # =========================================================================
    # HOST CONFIGURATIONS
    # =========================================================================
    # Machines are auto-discovered from machines/*.nix
    # Or you can define them explicitly:
    #
    #   nixosConfigurations.laptop = hydrix.lib.mkHost {
    #     modules = [ ./machines/laptop.nix ];
    #   };
    #
    nixosConfigurations = machineConfigs // {

      # =========================================================================
      # MICROVM CONFIGURATIONS
      # =========================================================================
      # These are shared across all machines - same VM images work everywhere
      #
      # Names: microvm-browsing, microvm-pentest, microvm-dev, microvm-comms, microvm-lurking
      # Profiles: ./profiles/<type>/ - full control over each VM type

      "microvm-browsing" = hydrix.lib.mkMicroVM {
        profile = "browsing";
        hostname = "microvm-browsing";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-pentest" = hydrix.lib.mkMicroVM {
        profile = "pentest";
        hostname = "microvm-pentest";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-dev" = hydrix.lib.mkMicroVM {
        profile = "dev";
        hostname = "microvm-dev";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-comms" = hydrix.lib.mkMicroVM {
        profile = "comms";
        hostname = "microvm-comms";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-lurking" = hydrix.lib.mkMicroVM {
        profile = "lurking";
        hostname = "microvm-lurking";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      # MicroVM Router (WiFi PCI address auto-detected from machine configs)
      "microvm-router" = hydrix.lib.mkMicrovmRouter {
        inherit wifiPciAddress;
        modules = [ ./shared/wifi.nix ];
      };

      # MicroVM Builder (for lockdown mode rebuilds)
      "microvm-builder" = hydrix.lib.mkMicrovmBuilder { inherit hostUsername; };

      # MicroVM Git-Sync (for lockdown mode git push/pull)
      "microvm-gitsync" = hydrix.lib.mkMicrovmGitSync {
        inherit hostUsername;
        repos = [
          { name = "hydrix-config"; source = "/home/" + hostUsername + "/hydrix-config"; }
        ];
      };
    };

    # =========================================================================
    # VM IMAGES (libvirt)
    # =========================================================================
    # Libvirt VMs for multi-instance deployments and pentesting workflows.
    # MicroVMs are recommended for single-instance use cases.
    # Use libvirt when you need multiple named instances (e.g., pentest-target1, pentest-target2)
    #
    packages.x86_64-linux = {
      # VM images for libvirt deployment (build on-demand)
      vm-browsing = (hydrix.lib.mkVM { profile = "browsing"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
      vm-pentest = (hydrix.lib.mkVM { profile = "pentest"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
      vm-dev = (hydrix.lib.mkVM { profile = "dev"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
      vm-comms = (hydrix.lib.mkVM { profile = "comms"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
    };
  };
}
