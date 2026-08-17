{
  description = "Hydrix - Options-driven VM isolation framework";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager/release-26.05";

    microvm.url = "github:astro/microvm.nix";
  };

  outputs = { self, ... }@inputs:
  let
    system = "x86_64-linux";

    lib = import ./lib { inherit inputs; };

  in {
    # =========================================================================
    # LIB - Helper functions for users
    # =========================================================================
    inherit lib;

    # =========================================================================
    # NIXOS MODULES - Import these in your config
    # =========================================================================
    nixosModules = {
      # Core options - defines all hydrix.* options (split by concern)
      options         = ./shared/options.nix;
      options-host    = ./host/options.nix;
      options-vm      = ./vm/options.nix;
      options-theming = ./theming/options.nix;

      # Module sets
      core     = ./shared/core;
      host     = ./host;
      vm       = ./vm;
      graphical = ./theming;

      # Individual host modules
      pentest-lan    = ./host/pentest-lan.nix;
      vm-theme-sync  = ./host/vm-theme-sync.nix;

      # Profiles (folder-based)
      pentest  = ./vm/profiles/pentest;
      browsing = ./vm/profiles/browsing;
      dev      = ./vm/profiles/dev;
      comms    = ./vm/profiles/comms;
      lurking  = ./vm/profiles/lurking;

      # Default = shared options + core (minimal)
      default = { ... }: {
        imports = [
          ./shared/options.nix
          ./host/options.nix
          ./vm/options.nix
          ./theming/options.nix
          ./shared/core
        ];
      };
    };

    # =========================================================================
    # TEMPLATES - For generating user config
    # =========================================================================
    templates = {
      # Default user config template
      default = {
        path = ./templates/user-config;
        description = "Hydrix user configuration (local flake)";
      };
    };

    # =========================================================================
    # DEV SHELL
    # =========================================================================
    # Framework provides lib only; not meant to be built directly.
    # Users build with their own nixpkgs version in their hydrix-config flake.
  };
}
