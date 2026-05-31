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
    vmThemeSyncModule = "${hydrix}/host/vm-theme-sync.nix";

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
        ./shared/common.nix      # Locale, timezone, scaling — shared with all VMs
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
          ./shared/repos.nix        # Declarative git repos (add yours, or leave repos = {})
          ./shared/fonts.nix        # Font packages and profiles
          ./shared/hyprland.nix     # Hyprland keybindings + config (user-customizable)
          ./shared/waybar.nix       # Waybar layout and modules (user-customizable)
          ./shared/i3.nix           # i3 keybindings (user-customizable)
          ./shared/sway.nix         # sway keybindings (user-customizable)
          vmThemeSyncModule         # VM theme sync (host-side)
          { hydrix.vmThemeSync.enable = true;
            hydrix.networking.vmRegistry      = vmRegistry;
            hydrix.networking.profileNetworks = allProfileNetworks;
            hydrix.networking.extraNetworks   = extraNetworks;
            hydrix.networking.infraTapBridges = infraTapBridges;
            hydrix.microvmHost.knownVms =
              map (m: "microvm-${m._profileName}") discoveredMetas
              ++ map (m: "microvm-${m._infraName}") discoveredInfra
              ++ map (m: "microvm-pentest-${m._taskName}") discoveredTasks; }
          ./shared/common.nix       # Locale + shared settings (all machines)
          ./shared/graphical.nix    # UI preferences (opacity, bluelight, etc.)
          ./shared/polybar.nix      # Polybar style, workspace labels, module layout
          ./shared/waybar.nix       # Waybar module
          ./shared/fish.nix         # Shell abbreviations + functions (user additions)
          ./shared/alacritty.nix    # Terminal cursor, keyboard overrides
          ./shared/dunst.nix        # Notification sound + size preferences
          ./shared/ranger.nix       # File manager mappings + rifle rules
          ./shared/rofi.nix         # Launcher keybindings + extraConfig
          ./shared/zathura.nix      # PDF viewer settings
          ./shared/starship.nix     # Prompt env vars (config is in configs/starship/)
          ./shared/vim.nix          # Vim plugins (config is in configs/vim/)
          ./shared/helix.nix
          ./shared/firefox.nix      # Host Firefox toggle + user-agent
          ./shared/obsidian.nix     # Host Obsidian toggle + vault paths
          ./shared/vault.nix        # Vault VM credential launcher (vault-cli + vault-pick)
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

    # All profile networks — passed to router for declarative IP/DHCP config
    allProfileNetworks = map (m: { name = m._profileName; inherit (m) subnet routerTap; })
      discoveredMetas;

    # Extra networks: user-defined profiles + infra VMs with new subnets (routerTap declared)
    profileExtraNetworks = map (m: { name = m._profileName; inherit (m) subnet routerTap; })
      (builtins.filter (m: !(builtins.elem m._profileName frameworkProfiles))
        discoveredMetas);

    # -------------------------------------------------------------------------
    # Task VM auto-discovery
    # Scans tasks/task*/ for directories containing meta.nix and builds:
    #   discoveredTasks  — list of meta attrsets (one per task slot)
    #   taskConfigs      — nixosConfigurations entries using mkMicroVM (pentest profile)
    # -------------------------------------------------------------------------
    discoveredTasks = let
      tasksDir  = ./tasks;
      taskDirs  = if builtins.pathExists tasksDir
        then builtins.filter
          (name: builtins.match "task[0-9]+" name != null
              && builtins.pathExists (tasksDir + "/${name}/meta.nix"))
          (builtins.attrNames (builtins.readDir tasksDir))
        else [];
    in map (n: import (tasksDir + "/${n}/meta.nix") // { _taskName = n; }) taskDirs;

    taskConfigs = builtins.listToAttrs (map (m: let
      vmName = "microvm-pentest-${m._taskName}";
    in {
      name  = vmName;
      value = hydrix.lib.mkMicroVM {
        profile  = "pentest";
        hostname = vmName;
        extraInputs = { inherit (inputs) nix-index-database burpsuite-nix hydrix; };
        modules  = [
          (./tasks + "/${m._taskName}/default.nix")
          vmThemeSyncModule
          { hydrix.vmThemeSync.enable = true; }
        ];
        inherit userProfiles hostConfig userColorschemesDir;
      };
    }) discoveredTasks);

    # -------------------------------------------------------------------------
    # Infra VM auto-discovery
    # Scans infra/ for directories containing meta.nix and builds:
    #   discoveredInfra   — list of meta attrsets (one per infra VM)
    #   infraNetworks     — extraNetworks entries (only VMs with routerTap, i.e. NEW subnets)
    #   infraTapBridges   — merged TAP→bridge map from all infra VM tapBridges fields
    #   infraVMConfigs    — nixosConfigurations entries using mkInfraVm
    #
    # VMs with builtinVm = true (router, builder) are excluded from infraVMConfigs
    # because they use specialized builder functions declared explicitly below.
    # -------------------------------------------------------------------------
    discoveredInfra = let
      infraDir = ./infra;
      infraNames = if builtins.pathExists infraDir
        then builtins.attrNames (builtins.readDir infraDir)
        else [];
      hasMeta = n: builtins.pathExists (infraDir + "/${n}/meta.nix");
    in map (n: import (infraDir + "/${n}/meta.nix") // { _infraName = n; })
         (builtins.filter hasMeta infraNames);

    infraNetworks = map (m: { name = m._infraName; inherit (m) subnet routerTap; })
      (builtins.filter (m: m ? routerTap) discoveredInfra);

    infraTapBridges = builtins.foldl' (acc: m: acc // m.tapBridges)
      {} (builtins.filter (m: m ? tapBridges) discoveredInfra);

    extraNetworks = profileExtraNetworks ++ infraNetworks;

    # Only non-builtin infra VMs — router/builder use specialized mk functions below
    infraVMConfigs = builtins.listToAttrs (map (m: {
      name  = "microvm-${m._infraName}";
      value = hydrix.lib.mkInfraVm {
        name    = m._infraName;
        modules = [ (./infra + "/${m._infraName}/default.nix") ];
      };
    }) (builtins.filter (m: !(m.builtinVm or false)) discoveredInfra));

    # Registry written to /etc/hydrix/vm-registry.json at activation
    vmRegistry =
      builtins.listToAttrs (map (m: {
        name  = m._profileName;
        value = {
          vmName      = "microvm-${m._profileName}";
          cid         = m.vsockCid;
          bridge      = m.bridge;
          subnet      = m.subnet;
          workspace   = m.workspace or null;
          label       = m.label or m._profileName;
          hasDisplay  = m.hasDisplay or true;
          focusBorder = autoVMConfigs."microvm-${m._profileName}".config.hydrix.vmThemeSync.focusBorder or null;
        };
      }) discoveredMetas) //
      builtins.listToAttrs (map (m: {
        name  = m._infraName;
        value = {
          vmName     = "microvm-${m._infraName}";
          cid        = m.vsockCid;
          bridge     = m.bridge or null;
          subnet     = m.subnet or null;
          workspace  = m.workspace or null;
          label      = m.label or m._infraName;
          hasDisplay = m.hasDisplay or false;
        };
      }) (builtins.filter (m: m ? vsockCid) discoveredInfra)) //
      builtins.listToAttrs (map (m: {
        name  = "pentest-${m._taskName}";
        value = {
          vmName     = "microvm-pentest-${m._taskName}";
          cid        = m.vsockCid;
          bridge     = m.bridge;
          subnet     = m.subnet;
          workspace  = m.workspace;
          label      = m.label;
          hasDisplay = true;
        };
      }) discoveredTasks);

    # One nixosConfiguration per discovered profile
    autoVMConfigs = builtins.listToAttrs (map (m: {
      name  = "microvm-${m._profileName}";
      value = hydrix.lib.mkMicroVM {
        profile  = m._profileName;
        hostname = "microvm-${m._profileName}";
        extraInputs = { inherit (inputs) nix-index-database burpsuite-nix hydrix; };
        modules  = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };
    }) discoveredMetas);

    # Per-machine profile overrides — extracted from machine configs AFTER machineConfigs
    # is defined. autoVMConfigs (used for vmRegistry focusBorder) must NOT use this helper
    # to avoid a cycle: autoVMConfigsWithOverrides -> machineConfigs -> vmRegistry ->
    # autoVMConfigs. autoVMConfigs stays pure; only the final nixosConfigurations output
    # uses autoVMConfigsWithOverrides.
    getProfileModules = profileName:
      builtins.concatMap (mc:
        let overrides = mc.config.hydrix.microvmHost.profileOverrides;
        in nixpkgs.lib.optional (overrides ? ${profileName}) overrides.${profileName}
      ) (builtins.attrValues machineConfigs);

    # VM configs with per-machine profileOverrides applied
    autoVMConfigsWithOverrides = builtins.listToAttrs (map (m: {
      name  = "microvm-${m._profileName}";
      value = hydrix.lib.mkMicroVM {
        profile  = m._profileName;
        hostname = "microvm-${m._profileName}";
        extraInputs = { inherit (inputs) nix-index-database burpsuite-nix hydrix; };
        modules  = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ]
          ++ getProfileModules m._profileName;
        inherit userProfiles hostConfig userColorschemesDir;
      };
    }) discoveredMetas);

  in {
    # =========================================================================
    # HOST CONFIGURATIONS
    # =========================================================================
    # Machines are auto-discovered from machines/*.nix
    nixosConfigurations = machineConfigs // taskConfigs // autoVMConfigsWithOverrides // infraVMConfigs // {

      # MicroVM Router (WiFi PCI address auto-detected from machine configs)
      # extraNetworks flows from profile meta.nix files automatically
      # User settings: edit infra/router/default.nix
      "microvm-router" = hydrix.lib.mkMicrovmRouter {
        inherit wifiPciAddress extraNetworks;
        profileNetworks = allProfileNetworks;
        modules = [
          ./shared/common.nix
          ./shared/wifi.nix
          ./infra/router/default.nix
          # Mullvad VPN — auto-included when vpn/mullvad.nix exists.
          # Setup: copy vpn/mullvad.nix.example → vpn/mullvad.nix,
          # place downloaded Mullvad .conf files in ~/hydrix-config/vpn/,
          # fill in the bridges map, then set enable = true.
        ] ++ (if builtins.pathExists ./vpn/mullvad.nix
              then [{ hydrix.router.vpn.mullvad = import ./vpn/mullvad.nix; }]
              else []);
      };

      # MicroVM Router Stable (immutable fallback — starts automatically if main router fails)
      # Intentionally minimal — leave infra/router-stable/default.nix empty for a clean fallback
      "microvm-router-stable" = hydrix.lib.mkMicrovmRouterStable {
        inherit wifiPciAddress extraNetworks;
        profileNetworks = allProfileNetworks;
        modules = [
          ./shared/common.nix
          ./shared/wifi.nix
          ./infra/router-stable/default.nix
        ];
      };

      # MicroVM Builder (for lockdown mode rebuilds)
      # User settings: edit infra/builder/default.nix
      "microvm-builder" = hydrix.lib.mkMicrovmBuilder {
        inherit hostUsername;
        modules = [
          ./shared/common.nix
          ./infra/builder/default.nix
        ];
      };

    };
    # Infra VMs (files, gitsync, hostsync, usb-sandbox, etc.) are auto-discovered
    # from infra/*/meta.nix — see infraVMConfigs above.

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
