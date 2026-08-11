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
  inherit (inputs) home-manager microvm;

  # Unstable overlay
  overlay-unstable = final: prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (prev.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

  overlay-lkl-memory = final: prev: {
    lkl = prev.lkl.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace tools/lkl/cptofs.c \
          --replace-fail 'lkl_start_kernel("mem=100M")' 'lkl_start_kernel("mem=1024M")'
      '';
    });
  };

  optionsModules = [
    ../shared/options.nix
    ../host/options.nix
    ../vm/options.nix
    ../theming/options.nix
  ];

  commonModules = [
    { nixpkgs.config.allowUnfree = true; }
    { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }
    inputs.stylix.nixosModules.stylix
  ] ++ optionsModules ++ [
    ../shared/core
    home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
    }
  ];

in rec {
  # =========================================================================
  # OVERLAYS - Exported for use in user flakes and packages outputs
  # =========================================================================
  # =========================================================================
  # mkHost - Create a Hydrix host configuration
  # =========================================================================
  mkHost = {
    system ? "x86_64-linux",
    modules ? [],
    specialArgs ? {},
    extraInputs ? {},
    userColorschemesDir ? null,
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    specialArgs = specialArgs // { inputs = allInputs; };
    modules = commonModules
      ++ nixpkgs'.lib.optional (allInputs ? nix-index-database)
           allInputs.nix-index-database.nixosModules.nix-index
      ++ nixpkgs'.lib.optional (allInputs ? disko)
           allInputs.disko.nixosModules.disko
      ++ [
        { hydrix.userColorschemesDir = userColorschemesDir; }
        # Host-only defaults (GTK dark theme, etc.)
        ../host/base/host-base.nix
        # Base system modules (services, virtualization)
        ../host/base/services.nix
        ../host/libvirt/virt.nix
        ../host/base/sops.nix

        # Host scripts (rebuild, microvm CLI, hydrix-tui, etc.)
        ../host/base/hydrix-scripts.nix

        # MicroVM host management (virtiofsd, TAP interfaces)
        ../host/microvm

        # Builder VM host integration
        ../host/vm-integration/builder-host.nix

        # Git-sync VM host integration
        ../host/vm-integration/gitsync-host.nix

        # Host-specific modules (networking, VFIO, specialisations, hardware)
        ../host

        # MicroVM host support
        microvm.nixosModules.host

        # Graphical environment (waypipe VM forwarding lives in theming/wm/hyprland/waypipe.nix)
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
    profile,
    hostname,
    modules ? [],
    extraInputs ? {},
    userProfiles ? null,
    hostConfig ? {},
    userColorschemesDir ? null,
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    specialArgs = { inputs = allInputs; };
    modules = commonModules
      ++ nixpkgs'.lib.optional (allInputs ? nix-index-database)
           allInputs.nix-index-database.nixosModules.nix-index
      ++ [
      { hydrix.userColorschemesDir = userColorschemesDir; }
      microvm.nixosModules.microvm
      ../vm/microvm/infra/microvm-profile-base.nix
    ] ++ nixpkgs'.lib.optionals (builtins.pathExists ../vm/profiles/${profile}) [
      ../vm/profiles/${profile}
    ] ++ [
      {
        hydrix.vm.storeName = nixpkgs'.lib.mkForce hostname;
        hydrix.vm.hostname = nixpkgs'.lib.mkDefault hostname;
      }
    ] ++ modules
    ++ nixpkgs'.lib.optional (hostConfig != {}) hostConfig
    ++ nixpkgs'.lib.optionals (userProfiles != null && builtins.pathExists (userProfiles + "/${profile}")) [
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
    hostname ? "microvm-router",
    wifiPciAddress ? "",
    extraNetworks ? [],
    profileNetworks ? [],
    modules ? [],
    extraInputs ? {},
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }
    ] ++ optionsModules ++
      [ inputs.stylix.nixosModules.stylix ] ++
      [
      home-manager.nixosModules.home-manager
      { home-manager.useGlobalPkgs = true; home-manager.useUserPackages = true; }
      microvm.nixosModules.microvm
      ../vm/microvm/infra/microvm-router.nix
      { networking.hostName = hostname; }
    ] ++ nixpkgs'.lib.optional (wifiPciAddress != "") {
      hydrix.hardware.vfio.wifiPciAddress = wifiPciAddress;
    } ++ nixpkgs'.lib.optional (extraNetworks != []) {
      hydrix.networking.extraNetworks = extraNetworks;
    } ++ nixpkgs'.lib.optional (profileNetworks != []) {
      hydrix.networking.profileNetworks = profileNetworks;
    } ++ modules;
  };

  # =========================================================================
  # mkMicrovmRouterUser - User-configured router variant
  # =========================================================================
  # Identical to mkMicrovmRouter but uses hostname "microvm-router-user".
  # Only one router can run at a time (same WiFi card, same CID, same TAPs).
  mkMicrovmRouterUser = args:
  let
    allInputs = inputs // (args.extraInputs or {});
    nixpkgs' = inputs.nixpkgs;
  in mkMicrovmRouter (args // {
    extraInputs = args.extraInputs or {};
    modules = (args.modules or []) ++ [
      { networking.hostName = nixpkgs'.lib.mkForce "microvm-router-user"; }
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
    hostname ? "microvm-router-stable",
    wifiPciAddress ? "",
    extraNetworks ? [],
    profileNetworks ? [],
    modules ? [],
    extraInputs ? {},
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }
    ] ++ optionsModules ++
      [ inputs.stylix.nixosModules.stylix ] ++
      [
      home-manager.nixosModules.home-manager
      { home-manager.useGlobalPkgs = true; home-manager.useUserPackages = true; }
      microvm.nixosModules.microvm
      ../vm/microvm/infra/microvm-router-stable.nix
      { networking.hostName = hostname; }
    ] ++ nixpkgs'.lib.optional (wifiPciAddress != "") {
      hydrix.hardware.vfio.wifiPciAddress = wifiPciAddress;
    } ++ nixpkgs'.lib.optional (extraNetworks != []) {
      hydrix.networking.extraNetworks = extraNetworks;
    } ++ nixpkgs'.lib.optional (profileNetworks != []) {
      hydrix.networking.profileNetworks = profileNetworks;
    } ++ modules;
  };

  # =========================================================================
  # mkMicrovmBuilder - Create the MicroVM builder for lockdown mode
  # =========================================================================
  # hostUsername: Username on the host machine (for mounting ~/hydrix-config)
  mkMicrovmBuilder = {
    system ? "x86_64-linux",
    hostUsername,  # Required: host user whose hydrix-config to mount
    modules ? [],
    extraInputs ? {},
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }
    ] ++ optionsModules ++
      [ inputs.stylix.nixosModules.stylix ] ++
      [
      home-manager.nixosModules.home-manager
      { home-manager.useGlobalPkgs = true; home-manager.useUserPackages = true; }
      microvm.nixosModules.microvm
      ../vm/microvm/infra/microvm-builder.nix
      {
        networking.hostName = "microvm-builder";
        hydrix.builder.hostUsername = hostUsername;
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
    extraInputs ? {},
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }
    ] ++ optionsModules ++
      [ inputs.stylix.nixosModules.stylix ] ++
      [
      home-manager.nixosModules.home-manager
      { home-manager.useGlobalPkgs = true; home-manager.useUserPackages = true; }
      microvm.nixosModules.microvm
      ../vm/microvm/infra/microvm-infra-base.nix
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
    extraInputs ? {},
  }:
  let
    allInputs = inputs // extraInputs;
    nixpkgs' = inputs.nixpkgs;
  in nixpkgs'.lib.nixosSystem {
    inherit system;
    modules = commonModules
      ++ [
      { hydrix.userColorschemesDir = userColorschemesDir; }
      ../vm/libvirt/vm-base.nix  # VM base configuration
      ../vm/profiles/${profile} # Hydrix base profile (always included)
      "${nixpkgs'}/nixos/modules/virtualisation/disk-image.nix"
      {
        image.efiSupport = false;
      }
      # hydrix.microvm.* option declarations (real schema, shared with
      # microvm-profile-base.nix) so profiles/<name>/default.nix's
      # lib.mkDefault/lib.mkForce-wrapped settings resolve correctly here too
      # — a plain freeform stub would leak the raw override wrapper through
      # instead of unwrapping it, breaking any mkIf that reads these values.
      # None of it is actually acted on by the libvirt/disk-image build.
      ../vm/microvm/infra/microvm-profile-options.nix
      # microvm.*: the real microvm-nix option tree (e.g. profiles/pentest's
      # microvm.qemu.extraArgs USB passthrough flags) — only meaningful when
      # microvm.nixosModules.microvm (a live QEMU launch) is actually wired
      # in. No profile currently wraps this in mkDefault/mkForce, so a plain
      # ignored freeform stub is sufficient.
      {
        options.microvm = nixpkgs'.lib.mkOption {
          type = nixpkgs'.lib.types.attrs;
          default = {};
          description = "Ignored by libvirt image builds — real microvm-nix settings.";
        };
      }
    ] ++ modules
    # Host settings applied after base profile, before user overrides
    ++ nixpkgs'.lib.optional (hostConfig != {}) hostConfig
    # Layer user's profile customizations on top (if provided)
    ++ nixpkgs'.lib.optionals (userProfiles != null && builtins.pathExists (userProfiles + "/${profile}")) [
      (userProfiles + "/${profile}")
    ];
  };
}

