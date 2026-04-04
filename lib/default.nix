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
  inherit (inputs) nixpkgs home-manager stylix microvm sops-nix disko nix-index-database;

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

  # Common modules for ALL Hydrix systems
  commonModules = [
    { nixpkgs.config.allowUnfree = true; }
    { nixpkgs.overlays = [ overlay-unstable overlay-lkl-memory ]; }

    # Hydrix options (single source of truth)
    ../modules/options.nix

    # Core modules (shared by host + VMs)
    ../modules/core

    # External modules
    nix-index-database.nixosModules.nix-index
    home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
    }
    stylix.nixosModules.stylix
  ];

in {
  # =========================================================================
  # mkHost - Create a Hydrix host configuration
  # =========================================================================
  mkHost = {
    system ? "x86_64-linux",
    modules ? [],
    specialArgs ? {},
    userColorschemesDir ? null,
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = specialArgs // { inherit inputs; };
    modules = commonModules ++ [
      { hydrix.userColorschemesDir = userColorschemesDir; }
      # Base system modules (services, virtualization)
      ../modules/base/services.nix
      ../modules/base/virt.nix
      ../modules/base/sops.nix

      # Host scripts (rebuild, microvm CLI, hydrix-tui, etc.)
      ../modules/base/hydrix-scripts.nix

      # Xpra host (VM app forwarding)
      ../modules/base/xpra-host.nix

      # MicroVM host management (virtiofsd, TAP interfaces)
      ../modules/base/microvm-host.nix

      # Builder VM host integration
      ../modules/base/builder-host.nix

      # Git-sync VM host integration
      ../modules/base/gitsync-host.nix

      # Host-specific modules (networking, VFIO, specialisations, hardware)
      ../modules/host

      # MicroVM host support
      microvm.nixosModules.host

      # Disko partitioning
      disko.nixosModules.disko

      # Graphical environment
      ../modules/graphical

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
    userProfiles ? null,  # Path to user's profiles directory (overlays base profile)
    hostConfig ? {},      # Host settings VMs should inherit (font family, etc.)
    userColorschemesDir ? null,
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = commonModules ++ [
      { hydrix.userColorschemesDir = userColorschemesDir; }
      microvm.nixosModules.microvm
      ../modules/microvm/microvm-base.nix  # User setup, vsock, shares, etc.
      ../profiles/${profile}               # Hydrix base profile (always included)
      {
        networking.hostName = hostname;
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
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
      ../modules/options.nix
      microvm.nixosModules.microvm
      ../modules/microvm/microvm-router.nix
      { networking.hostName = "microvm-router"; }
    ] ++ nixpkgs.lib.optional (wifiPciAddress != "") {
      hydrix.hardware.vfio.wifiPciAddress = wifiPciAddress;
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
      ../modules/options.nix
      microvm.nixosModules.microvm
      ../modules/microvm/microvm-builder.nix
      {
        networking.hostName = "microvm-builder";
        # Pass host username and optional local Hydrix path to builder module
        hydrix.builder.hostUsername = hostUsername;
        hydrix.builder.localHydrixPath = localHydrixPath;
      }
    ] ++ modules;
  };

  # =========================================================================
  # mkMicrovmFiles - Create the MicroVM files transfer hub
  # =========================================================================
  # The files VM acts as an encrypted jump host for inter-VM file transfers.
  # It sits on br-files (192.168.108.x) plus direct TAPs on each bridge
  # listed in accessFrom.
  #
  # accessFrom: List of bridge names the files VM gets direct TAP access to.
  #             e.g., [ "pentest" "browse" "dev" "comms" ]
  #             Default [] — no bridge access.
  # modules:    Optional extra NixOS modules.
  mkMicrovmFiles = {
    system ? "x86_64-linux",
    accessFrom ? [],
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
      ../modules/options.nix
      microvm.nixosModules.microvm
      ../modules/microvm/microvm-files.nix
      {
        networking.hostName = "microvm-files";
        # Enable the files VM module and pass bridge access list
        hydrix.microvmFiles = { enable = true; inherit accessFrom; };
      }
    ] ++ modules;
  };

  # =========================================================================
  # mkMicrovmGitSync - Create the MicroVM git-sync for lockdown mode
  # =========================================================================
  # hostUsername: Username on the host machine (for repo paths)
  # repos: List of { name, source } for git repositories to mount R/W
  mkMicrovmGitSync = {
    system ? "x86_64-linux",
    hostUsername,
    repos ? [],
    modules ? [],
    enableGithubSecrets ? false,
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      { nixpkgs.overlays = [ overlay-unstable ]; }
      ../modules/options.nix
      microvm.nixosModules.microvm
      ../modules/microvm/microvm-gitsync.nix
      {
        networking.hostName = "microvm-gitsync";
        hydrix.gitsync.hostUsername = hostUsername;
        hydrix.gitsync.repos = repos;
        hydrix.gitsync.secrets.github = enableGithubSecrets;
      }
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
      ../modules/vm/vm-base.nix  # VM base configuration
      ../profiles/${profile}     # Hydrix base profile (always included)
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
  mkLibvirtRouter = {
    system ? "x86_64-linux",
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      { nixpkgs.config.allowUnfree = true; }
      ../modules/options.nix
      ../modules/vm/libvirt-router.nix
      "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
      { image.efiSupport = false; }
    ] ++ modules;
  };
}
