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
    userColorschemesDir = if builtins.pathExists ./colorschemes then ./colorschemes else null;

    # =========================================================================
    # VM THEME SYNC MODULE
    # =========================================================================
    # Shares host's wal cache to VMs via virtiofs for instant color sync.
    # Imported by both host (mkHost) and each VM (mkMicroVM).
    vmThemeSyncModule = "${hydrix}/host/vm-theme-sync.nix";

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
        ./modules/common.nix      # Locale, timezone, scaling — shared with all VMs
        ./modules/fonts.nix
        ./modules/vim.nix         # Deploy .vimrc from configs/vim/.vimrc
        ./modules/starship.nix    # Deploy starship.toml from configs/starship/
        ./modules/fish.nix        # Shell abbreviations + functions
        ./modules/alacritty.nix   # Cursor, keyboard overrides
        ./modules/dunst.nix       # Notification preferences
        ./modules/ranger.nix      # File manager mappings + rifle rules
        ./modules/rofi.nix        # Launcher keybindings
        ./modules/zathura.nix     # PDF viewer settings
        ./modules/firefox.nix     # Shared Firefox defaults (extensions, UA, UI prefs)
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
          builtins.match ".*-grub-entries\\.nix" name == null
        )
        allNixFiles;
    in builtins.listToAttrs (map (file:
      let machineName = builtins.replaceStrings [ ".nix" ] [ "" ] file;
      in {
        name = machineName;
        value = hydrix.lib.mkHost {
          specialArgs = { inherit self hydrix; };
          extraInputs = { inherit (inputs) disko sops-nix nix-index-database burpsuite-nix; };
          inherit userColorschemesDir;
          modules = [
            (machinesDir + "/${file}")
            ./modules/wifi.nix         # WiFi networks (legacy: move to secrets/wifi.yaml via setup-wifi-secrets)
            ./modules/repos.nix        # Declarative git repos (add yours, or leave repos = {})
            ./modules/fonts.nix        # Font packages and profiles
            ./modules/hyprland.nix     # Hyprland keybindings + config (user-customizable)
            ./modules/waybar.nix       # Waybar layout and modules (user-customizable)
            ./modules/i3.nix           # i3 keybindings (user-customizable)
            ./modules/sway.nix         # sway keybindings (user-customizable)
            ./modules/grub-theme.nix   # Hydrix-themed GRUB bootloader
            ./modules/plymouth.nix     # Hydrix boot animation
            ./modules/greetd.nix       # greetd login manager (tuigreet/regreet)
            vmThemeSyncModule          # VM theme sync (host-side)
            { hydrix.vmThemeSync.enable = true;
              # Registry's router/router-stable vmName defaults to the generic
              # infra dir name ("microvm-router"), but the real nixosConfigurations
              # key is per-machine ("microvm-router-${machineName}") — override here
              # so get_cid's registry lookup hits instead of falling back to nix eval.
              hydrix.networking.vmRegistry      = vmRegistry // {
                router        = vmRegistry.router        // { vmName = "microvm-router-${machineName}"; };
                router-stable = vmRegistry.router-stable // { vmName = "microvm-router-stable-${machineName}"; };
              };
              hydrix.networking.profileNetworks = allProfileNetworks;
              hydrix.networking.extraNetworks   = extraNetworks;
              hydrix.networking.infraTapBridges = infraTapBridges;
              hydrix.microvmHost.knownVms =
                map (m: "microvm-${m._profileName}") discoveredMetas
                ++ map (m: "microvm-${m._infraName}") discoveredInfra
                ++ map (m: "microvm-pentest-${m._taskName}") discoveredTasks;
              # Per-machine router VM names — each machine gets its own router
              # nixosConfiguration with the correct wifiPciAddress baked in.
              hydrix.microvmHost.vmNames.router       = "microvm-router-${machineName}";
              hydrix.microvmHost.vmNames.routerStable = "microvm-router-stable-${machineName}"; }
            ./modules/common.nix       # Locale + shared settings (all machines)
            ./modules/graphical.nix    # UI preferences (opacity, bluelight, etc.)
            ./modules/polybar.nix      # Polybar style, workspace labels, module layout
            ./modules/waybar.nix       # Waybar module
            ./modules/fish.nix         # Shell abbreviations + functions (user additions)
            ./modules/alacritty.nix    # Terminal cursor, keyboard overrides
            ./modules/dunst.nix        # Notification sound + size preferences
            ./modules/ranger.nix       # File manager mappings + rifle rules
            ./modules/rofi.nix         # Launcher keybindings + extraConfig
            ./modules/zathura.nix      # PDF viewer settings
            ./modules/starship.nix     # Prompt env vars (config is in configs/starship/)
            ./modules/vim.nix          # Vim plugins (config is in configs/vim/)
            ./modules/helix.nix
            ./modules/firefox.nix      # Host Firefox toggle + user-agent
            ./modules/obsidian.nix     # Host Obsidian toggle + vault paths
            ./modules/vault.nix        # Vault VM credential launcher (vault-cli + vault-pick)
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
      (builtins.filter (m: m ? routerTap && !(m.builtinVm or false)) discoveredInfra);

    # Builtin infra VMs (builtinVm = true) with routerTap+subnet — TAPs are hardwired in
    # the framework, but subnets come from meta.nix. Passed to router as infraLans so it
    # can assign IPs on those interfaces (e.g. 192.168.100.253 on mv-router-mgmt).
    infraLans = map (m: { tap = m.routerTap; inherit (m) subnet; })
      (builtins.filter (m: m ? routerTap && (m.builtinVm or false)) discoveredInfra);

    infraTapBridges = builtins.foldl' (acc: m: acc // m.tapBridges)
      {} (builtins.filter (m: m ? tapBridges) discoveredInfra);

    extraNetworks = profileExtraNetworks ++ infraNetworks;

    # Only non-builtin infra VMs — router/builder use specialized mk functions below
    infraVMConfigs = builtins.listToAttrs (map (m: {
      name  = "microvm-${m._infraName}";
      value = hydrix.lib.mkInfraVm {
        name    = m._infraName;
        modules = [ (./infra + "/${m._infraName}/default.nix") ]
          ++ nixpkgs.lib.optional (m.filesAgent or false) "${hydrix}/vm/dev/files-agent.nix";
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
          focusBorder = m.focusBorder or null;
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

    # Per-machine router configs — each reads wifiPciAddress from that machine's own config.
    # Avoids cross-machine pollution of a single shared wifiPciAddress, and ensures
    # multiple machines in the same flake each get their own router nixosConfiguration.
    routerModules = [
      { hydrix.router.microvm.infraLans = infraLans; }
      ./modules/common.nix
      ./modules/wifi.nix
      "${hydrix}/vm/microvm/infra/router-lan-control.nix"
      ./infra/router/default.nix
    ] ++ (if builtins.pathExists ./vpn/mullvad.nix
          then [{ hydrix.router.vpn.mullvad = import ./vpn/mullvad.nix; }]
          else []);

    stableRouterModules = [
      { hydrix.router.microvm.infraLans = infraLans; }
      ./modules/common.nix
      ./modules/wifi.nix
      ./infra/router-stable/default.nix
    ];

    perMachineRouterConfigs = builtins.listToAttrs (map (machineName: {
      name  = "microvm-router-${machineName}";
      value = hydrix.lib.mkMicrovmRouter {
        hostname       = "microvm-router-${machineName}";
        wifiPciAddress = (builtins.getAttr machineName machineConfigs).config.hydrix.hardware.vfio.wifiPciAddress;
        inherit extraNetworks;
        profileNetworks = allProfileNetworks;
        modules = routerModules;
      };
    }) (builtins.attrNames machineConfigs));

    perMachineStableRouterConfigs = builtins.listToAttrs (map (machineName: {
      name  = "microvm-router-stable-${machineName}";
      value = hydrix.lib.mkMicrovmRouterStable {
        hostname       = "microvm-router-stable-${machineName}";
        wifiPciAddress = (builtins.getAttr machineName machineConfigs).config.hydrix.hardware.vfio.wifiPciAddress;
        inherit extraNetworks;
        profileNetworks = allProfileNetworks;
        modules = stableRouterModules;
      };
    }) (builtins.attrNames machineConfigs));

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
    # is defined. Must NOT use autoVMConfigs to avoid a cycle:
    # autoVMConfigsWithOverrides -> machineConfigs -> vmRegistry -> autoVMConfigs.
    # autoVMConfigs stays pure; only the final nixosConfigurations output
    # uses autoVMConfigsWithOverrides.
    getProfileModules = profileName:
      builtins.concatMap (mc:
        let
          overrides = mc.config.hydrix.microvmHost.profileOverrides;
          vmCfg = mc.config.hydrix.microvmHost.vms."microvm-${profileName}" or {};
          encModule = nixpkgs.lib.optional (vmCfg.encryption or false)
            { hydrix.microvm.encryption.enable = true; };
        in
          nixpkgs.lib.optional (overrides ? ${profileName}) overrides.${profileName}
          ++ encModule
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
    nixosConfigurations =
      machineConfigs // taskConfigs // autoVMConfigsWithOverrides // infraVMConfigs
      // perMachineRouterConfigs // perMachineStableRouterConfigs // {

      # MicroVM Builder (for lockdown mode rebuilds)
      # User settings: edit infra/builder/default.nix
      "microvm-builder" = hydrix.lib.mkMicrovmBuilder {
        inherit hostUsername;
        modules = [
          ./modules/common.nix
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
