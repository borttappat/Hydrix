# Hydrix Library - Helper functions for building Hydrix systems
#
# Usage in user's flake:
#
#   outputs = { hydrix, ... }: {
#     nixosConfigurations.myhost = hydrix.lib.mkHost {
#       system = "x86_64-linux";
#       modules = [ ./machine.nix ];
#     };
#   };

{ inputs }:

let
  inherit (inputs) nixpkgs home-manager stylix microvm;

  # Unstable overlay
  overlay-unstable = final: prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (prev.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

  # Fix for large disk image builds - cptofs (LKL) OOMs with default 100MB
  # Increase to 1024MB for pentest and other large closures
  overlay-lkl-memory = final: prev: {
    lkl = prev.lkl.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace tools/lkl/cptofs.c \
          --replace-fail 'lkl_start_kernel("mem=100M")' 'lkl_start_kernel("mem=1024M")'
      '';
    });
  };

  # Options files (split from the monolithic modules/options.nix)
  optionsModules = [
    ../shared/options.nix
    ../host/options.nix
    ../vm/options.nix
    ../theming/options.nix
  ];

  # Common modules for ALL Hydrix systems
  commonModules = [
    { nixpkgs.config.allowUnfree = true; }
    { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }

    # Hydrix options (split by concern)
  ] ++ optionsModules ++ [

    # Core modules (shared by host + VMs)
    ../shared/core

    # External modules
    home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
    }
    stylix.nixosModules.stylix
  ];

in rec {
  # =========================================================================
  # mkHost - Create a Hydrix host configuration
  # =========================================================================
  mkHost = {
    system ? "x86_64-linux",
    modules ? [],
    specialArgs ? {},
    extraInputs ? {},      # User-provided inputs: disko, sops-nix, nix-index-database, etc.
    userColorschemesDir ? null,
  }:
  let
    allInputs = inputs // extraInputs;
  in nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = specialArgs // { inputs = allInputs; };
    modules = commonModules
      ++ nixpkgs.lib.optional (allInputs ? nix-index-database)
           allInputs.nix-index-database.nixosModules.nix-index
      ++ nixpkgs.lib.optional (allInputs ? disko)
           allInputs.disko.nixosModules.disko
      ++ [
        { hydrix.userColorschemesDir = userColorschemesDir; }
        # Host-only defaults (GTK dark theme, etc.)
        ../host/base/host-base.nix
        # Base system modules (services, virtualization)
        ../host/base/services.nix
        ../host/virt.nix
        ../host/base/sops.nix

        # Host scripts (rebuild, microvm CLI, hydrix-tui, etc.)
        ../host/base/hydrix-scripts.nix

        # Xpra host (VM app forwarding)
        ../host/vm-integration/xpra-host.nix

        # MicroVM host management (virtiofsd, TAP interfaces)
        ../host/vm-integration/microvm-host.nix

        # Builder VM host integration
        ../host/vm-integration/builder-host.nix

        # Git-sync VM host integration
        ../host/vm-integration/gitsync-host.nix

        # Host-specific modules (networking, VFIO, specialisations, hardware)
        ../host

        # MicroVM host support
        microvm.nixosModules.host

        # waypipe VM forwarding (active when sway or hyprland enabled)
        ../theming/wm/sway/waypipe.nix

        # Graphical environment
        ../theming

        # Set vmType to host
        { hydrix.vmType = "host"; }
      ] ++ modules;
  };

  # =========================================================================
  # mkMicroVM - Create a MicroVM configuration
  # =========================================================================
  # userProfiles: Optional path to user's profiles directory (e.g., ./profiles)
  #               User profiles are layered ON TOP of Hydrix base profiles
  #               allowing customization without losing base functionality
  # hostConfig:   Optional module with host settings VMs should inherit at build time
  #               (font family, etc.) Applied after base profile, before user overrides.
  #               Runtime scaling (DPI, pixel sizes) comes from scaling.json automatically.
  mkMicroVM = {
    system ? "x86_64-linux",
    profile,  # e.g., "browsing", "pentest", "dev", "comms"
    hostname,
    modules ? [],
    extraInputs ? {},     # User-provided inputs: nix-index-database, burpsuite-nix, etc.
    userProfiles ? null,  # Path to user's profiles directory (overlays base profile)
    hostConfig ? {},      # Host settings VMs should inherit (font family, etc.)
    userColorschemesDir ? null,
  }:
  let
    allInputs = inputs // extraInputs;
  in nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inputs = allInputs; };
    modules = commonModules
      ++ nixpkgs.lib.optional (allInputs ? nix-index-database)
           allInputs.nix-index-database.nixosModules.nix-index
      ++ [
      { hydrix.userColorschemesDir = userColorschemesDir; }
      microvm.nixosModules.microvm
      ../vm/infra/microvm-base.nix  # User setup, vsock, shares, etc.
    ] ++ nixpkgs.lib.optionals (builtins.pathExists ../vm/profiles/${profile}) [
      ../vm/profiles/${profile}               # Hydrix base profile (only if it exists)
    ] ++ [
      {
        # storeName: structural identifier used for host paths/services — never override
        hydrix.vm.storeName = nixpkgs.lib.mkForce hostname;
        # hostname: what the VM reports — user can override in profiles/<name>/default.nix
        hydrix.vm.hostname = nixpkgs.lib.mkDefault hostname;
      }
    ] ++ modules
    # Host settings applied after base profile, before user overrides
    ++ nixpkgs.lib.optional (hostConfig != {}) hostConfig
    # Layer user's profile customizations on top (if provided)
    ++ nixpkgs.lib.optionals (userProfiles != null && builtins.pathExists (userProfiles + "/${profile}")) [
      (userProfiles + "/${profile}")
    ];
  };

  # =========================================================================
  # mkMicrovmRouter - Create the MicroVM router
  # =========================================================================
  # wifiPciAddress: PCI address of WiFi card for VFIO passthrough (e.g., "00:14.3")
  #                 Detected by setup-hydrix.sh and stored in machine config.
  #                 Pass it here so the router VM can use it for PCI passthrough.
  mkMicrovmRouter = {
    system ? "x86_64-linux",
    wifiPciAddress ? "",
    extraNetworks ? [],       # { name, subnet, routerTap } — user-defined extra networks needing new bridges
    profileNetworks ? [],     # { name, subnet, routerTap } — all profile networks from meta.nix
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
    ] ++ optionsModules ++ [
      microvm.nixosModules.microvm
      ../vm/infra/microvm-router.nix
      { networking.hostName = "microvm-router"; }
    ] ++ nixpkgs.lib.optional (wifiPciAddress != "") {
      hydrix.hardware.vfio.wifiPciAddress = wifiPciAddress;
    } ++ nixpkgs.lib.optional (extraNetworks != []) {
      hydrix.networking.extraNetworks = extraNetworks;
    } ++ nixpkgs.lib.optional (profileNetworks != []) {
      hydrix.networking.profileNetworks = profileNetworks;
    } ++ modules;
  };

  # =========================================================================
  # mkMicrovmRouterUser - User-configured router variant
  # =========================================================================
  # Identical to mkMicrovmRouter but uses hostname "microvm-router-user".
  # Only one router can run at a time (same WiFi card, same CID, same TAPs).
  mkMicrovmRouterUser = args: mkMicrovmRouter (args // {
    modules = (args.modules or []) ++ [
      { networking.hostName = nixpkgs.lib.mkForce "microvm-router-user"; }
    ];
  });

  # =========================================================================
  # mkMicrovmRouterStable - Create the immutable fallback router VM
  # =========================================================================
  # Same parameters as mkMicrovmRouter — the stable router receives the same
  # profile/extra network data so it serves all the same subnets.
  # Uses separate TAP names (mv-rts-*) so both routers can coexist in config.
  # autostart = false; starts only via OnFailure on the main router.
  mkMicrovmRouterStable = {
    system ? "x86_64-linux",
    wifiPciAddress ? "",
    extraNetworks ? [],
    profileNetworks ? [],
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
    ] ++ optionsModules ++ [
      microvm.nixosModules.microvm
      ../vm/infra/microvm-router-stable.nix
      { networking.hostName = "microvm-router-stable"; }
    ] ++ nixpkgs.lib.optional (wifiPciAddress != "") {
      hydrix.hardware.vfio.wifiPciAddress = wifiPciAddress;
    } ++ nixpkgs.lib.optional (extraNetworks != []) {
      hydrix.networking.extraNetworks = extraNetworks;
    } ++ nixpkgs.lib.optional (profileNetworks != []) {
      hydrix.networking.profileNetworks = profileNetworks;
    } ++ modules;
  };

  # =========================================================================
  # mkMicrovmBuilder - Create the MicroVM builder for lockdown mode
  # =========================================================================
  # hostUsername: Username on the host machine (for mounting ~/hydrix-config)
  # localHydrixPath: Optional path to local Hydrix clone (for developers)
  #                  When set, builder mounts this path so flake can use path: inputs
  mkMicrovmBuilder = {
    system ? "x86_64-linux",
    hostUsername,  # Required: host user whose hydrix-config to mount
    localHydrixPath ? null,  # Optional: path to local Hydrix clone for developers
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
    ] ++ optionsModules ++ [
      microvm.nixosModules.microvm
      ../vm/infra/microvm-builder.nix
      {
        networking.hostName = "microvm-builder";
        # Pass host username and optional local Hydrix path to builder module
        hydrix.builder.hostUsername = hostUsername;
        hydrix.builder.localHydrixPath = localHydrixPath;
      }
    ] ++ modules;
  };

  # =========================================================================
  # mkInfraVm - Create a user-declared headless infrastructure VM
  # =========================================================================
  # Provides a minimal headless base (console socket, virtiofs store, DHCP).
  # The caller supplies CID, TAP interface, and VM-specific services via modules.
  #
  # Typical use in flake.nix (auto-generated from infra/<name>/meta.nix):
  #   "microvm-vault" = hydrix.lib.mkInfraVm {
  #     name    = "vault";
  #     modules = [ ./infra/vault/default.nix ];
  #   };
  #
  # The caller's module is expected to set:
  #   microvm.vsock.cid     — unique vsock CID
  #   microvm.interfaces    — TAP interface (id + mac)
  #   (plus any VM-specific services, users, volumes)
  #
  mkInfraVm = {
    name,
    system  ? "x86_64-linux",
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
    ] ++ optionsModules ++ [
      microvm.nixosModules.microvm
      ../vm/infra/microvm-infra-base.nix
      { networking.hostName = "microvm-${name}"; }
    ] ++ modules;
  };

  # =========================================================================
  # mkVM - Create a libvirt VM configuration (for images)
  # =========================================================================
  # userProfiles: Optional path to user's profiles directory (e.g., ./profiles)
  #               User profiles are layered ON TOP of Hydrix base profiles
  # hostConfig:   Optional module with host settings VMs should inherit at build time
  mkVM = {
    system ? "x86_64-linux",
    profile,
    modules ? [],
    userProfiles ? null,  # Path to user's profiles directory (overlays base profile)
    hostConfig ? {},      # Host settings VMs should inherit (font family, etc.)
    userColorschemesDir ? null,
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = commonModules ++ [
      { hydrix.userColorschemesDir = userColorschemesDir; }
      ../vm/base/vm-base.nix    # VM base configuration
      ../vm/profiles/${profile} # Hydrix base profile (always included)
      "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
      {
        image.efiSupport = false;
      }
    ] ++ modules
    # Host settings applied after base profile, before user overrides
    ++ nixpkgs.lib.optional (hostConfig != {}) hostConfig
    # Layer user's profile customizations on top (if provided)
    ++ nixpkgs.lib.optionals (userProfiles != null && builtins.pathExists (userProfiles + "/${profile}")) [
      (userProfiles + "/${profile}")
    ];
  };

  # =========================================================================
  # mkLibvirtRouter - Create the libvirt router VM (fallback)
  # =========================================================================
  # extraNetworks: same param as mkMicrovmRouter — accepts user-defined profile
  # networks, but libvirt-router.nix does not yet process them dynamically.
  # Pass them via modules = [ { hydrix.networking.extraNetworks = ...; } ] for now.
  mkLibvirtRouter = {
    system ? "x86_64-linux",
    extraNetworks ? [],
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
    ] ++ optionsModules ++ [
      ../vm/infra/libvirt-router.nix
      "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
      { image.efiSupport = false; }
    ] ++ nixpkgs.lib.optional (extraNetworks != []) {
      hydrix.networking.extraNetworks = extraNetworks;
    } ++ modules;
  };
}
