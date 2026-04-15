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
    hydrix.url = "@HYDRIX_URL@";

    # Inherit nixpkgs from Hydrix for consistency
    nixpkgs.follows = "hydrix/nixpkgs";

    # Optional framework inputs — user-controlled versions
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    nix-index-database.url = "github:Mic92/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    burpsuite-nix.url = "github:Red-Flake/burpsuite-nix";
    burpsuite-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, hydrix, nixpkgs, ... }@inputs:
  let
    # =========================================================================
    # HOST USERNAME (for builder VM)
    # =========================================================================
    # Set this to your username - used by builder VM to mount ~/hydrix-config
    hostUsername = "@USERNAME@";

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
      imports = [
        ./shared/fonts.nix
        ./shared/vim.nix         # Deploy .vimrc from configs/vim/.vimrc
        ./shared/starship.nix    # Deploy starship.toml from configs/starship/
        ./shared/fish.nix        # Shell abbreviations + functions
        ./shared/alacritty.nix   # Cursor, keyboard overrides
        ./shared/dunst.nix       # Notification preferences
        ./shared/ranger.nix      # File manager mappings + rifle rules
        ./shared/rofi.nix        # Launcher keybindings
        ./shared/zathura.nix     # PDF viewer settings
      ];
      hydrix.username = hostUsername;  # Required: VMs use this for virtiofs share paths
      hydrix.vmColors.enable = true;   # VMs inherit host colorscheme (reads wal cache at runtime)
      hydrix.vmColors.hostColorscheme = hostColorscheme;  # Build-time colorscheme fallback
      # hydrix.colorschemeInheritance = "dynamic";  # DEFAULT: "dynamic"
      #   "full"    — VMs use all host wal colors
      #   "dynamic" — VMs use host background + their own text colors
      #   "none"    — VMs use their own colorscheme independently
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
      # Filter out hardware configs and generated helper files (not standalone machines)
      machineFiles = builtins.filter
        (name:
          builtins.match ".*-hardware\\.nix" name == null &&
          name != "grub-entries.nix"
        )
        allNixFiles;
    in builtins.listToAttrs (map (file: {
      name = builtins.replaceStrings [ ".nix" ] [ "" ] file;
      value = hydrix.lib.mkHost {
        specialArgs = { inherit self hydrix; };
        extraInputs = { inherit (inputs) disko sops-nix nix-index-database burpsuite-nix; };
        inherit userColorschemesDir;
        modules = [
          (machinesDir + "/${file}")
          ./shared/wifi.nix         # WiFi credentials (shared across machines)
          ./shared/fonts.nix        # Font packages and profiles
          ./shared/i3.nix           # i3 keybindings (user-customizable)
          vmThemeSyncModule         # VM theme sync (host-side)
          { hydrix.vmThemeSync.enable = true;
            hydrix.networking.vmRegistry   = vmRegistry;
            hydrix.networking.extraNetworks = extraNetworks; }
          ./shared/common.nix       # Locale + shared settings (all machines)
          ./shared/graphical.nix    # UI preferences (opacity, bluelight, etc.)
          ./shared/polybar.nix      # Polybar style, workspace labels, module layout
          ./shared/fish.nix         # Shell abbreviations + functions (user additions)
          ./shared/alacritty.nix    # Terminal cursor, keyboard overrides
          ./shared/dunst.nix        # Notification sound + size preferences
          ./shared/ranger.nix       # File manager mappings + rifle rules
          ./shared/rofi.nix         # Launcher keybindings + extraConfig
          ./shared/zathura.nix      # PDF viewer settings
          ./shared/starship.nix     # Prompt env vars (config is in configs/starship/)
          ./shared/vim.nix          # Vim plugins (config is in configs/vim/)
          ./shared/firefox.nix      # Host Firefox toggle + user-agent
          ./shared/obsidian.nix     # Host Obsidian toggle + vault paths
        ];
      };
    }) machineFiles);

    # =========================================================================
    # PROFILE AUTO-DISCOVERY
    # =========================================================================
    # Reads meta.nix from every profiles/<name>/ directory.
    # Each meta.nix drives: vmRegistry, bridge setup, router subnets, polybar, i3.
    # To add a new VM type: create profiles/<name>/meta.nix + profiles/<name>/default.nix
    # and rebuild — everything else auto-wires.
    discoveredMetas = let
      profileNames = builtins.attrNames (builtins.readDir userProfiles);
      hasMeta = p: builtins.pathExists (userProfiles + "/${p}/meta.nix");
    in map (p: import (userProfiles + "/${p}/meta.nix") // { _profileName = p; })
         (builtins.filter hasMeta profileNames);

    # Built-in framework profiles (already have bridges/subnets in Hydrix)
    frameworkProfiles = [ "browsing" "pentest" "dev" "comms" "lurking" ];

    # Extra networks: user-defined profiles that need new bridges + router subnets
    extraNetworks = map (m: { name = m._profileName; inherit (m) subnet routerTap; })
      (builtins.filter (m: !(builtins.elem m._profileName frameworkProfiles))
        discoveredMetas);

    # Registry written to /etc/hydrix/vm-registry.json at activation
    vmRegistry = builtins.listToAttrs (map (m: {
      name  = m._profileName;
      value = {
        vmName    = "microvm-${m._profileName}";
        cid       = m.vsockCid;
        bridge    = m.bridge;
        subnet    = m.subnet;
        workspace = m.workspace;
        label     = m.label or m._profileName;
      };
    }) discoveredMetas);

    # One nixosConfiguration per discovered profile
    autoVMConfigs = builtins.listToAttrs (map (m: {
      name  = "microvm-${m._profileName}";
      value = hydrix.lib.mkMicroVM {
        profile  = m._profileName;
        hostname = "microvm-${m._profileName}";
        extraInputs = { inherit (inputs) nix-index-database burpsuite-nix; };
        modules  = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };
    }) discoveredMetas);

  in {
    # =========================================================================
    # HOST CONFIGURATIONS
    # =========================================================================
    # Machines are auto-discovered from machines/*.nix
    nixosConfigurations = machineConfigs // autoVMConfigs // {

      # MicroVM Router (WiFi PCI address auto-detected from machine configs)
      # extraNetworks flows from profile meta.nix files automatically
      "microvm-router" = hydrix.lib.mkMicrovmRouter {
        inherit wifiPciAddress extraNetworks;
        modules = [ ./shared/wifi.nix ];
      };

      # MicroVM Router Stable (immutable fallback — starts automatically if main router fails)
      "microvm-router-stable" = hydrix.lib.mkMicrovmRouterStable {
        inherit wifiPciAddress extraNetworks;
        modules = [ ./shared/wifi.nix ];
      };

      # MicroVM Builder (for lockdown mode rebuilds)
      "microvm-builder" = hydrix.lib.mkMicrovmBuilder { inherit hostUsername; };

      # MicroVM Git-Sync (for lockdown mode git push/pull)
      "microvm-gitsync" = hydrix.lib.mkMicrovmGitSync {
        inherit hostUsername;
        # Repos mounted R/W into the VM at /mnt/repos/<name>
        # Usage: microvm console microvm-gitsync
        #        → cd /mnt/repos/hydrix-config && git push
        repos = [
          { name = "hydrix-config"; source = "/home/" + hostUsername + "/hydrix-config"; }
          # { name = "Hydrix"; source = "/home/" + hostUsername + "/Hydrix"; }
          # { name = "my-notes"; source = "/home/" + hostUsername + "/my-notes"; }
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
