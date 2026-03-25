{
  description = "Hydrix - Options-driven VM isolation framework";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:danth/stylix/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:Mic92/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    burpsuite-nix = {
      url = "github:Red-Flake/burpsuite-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
  let
    system = "x86_64-linux";

    # Import lib helpers
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
      # Core options - defines all hydrix.* options
      options = ./modules/options.nix;

      # Module sets
      core = ./modules/core;
      host = ./modules/host;
      vm = ./modules/vm;
      graphical = ./modules/graphical;

      # Profiles (folder-based)
      pentest = ./profiles/pentest;
      browsing = ./profiles/browsing;
      dev = ./profiles/dev;
      comms = ./profiles/comms;
      lurking = ./profiles/lurking;

      # Default = options + core (minimal)
      default = { ... }: {
        imports = [
          ./modules/options.nix
          ./modules/core
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
    devShells.${system}.default = let
      pkgs = import nixpkgs { inherit system; };
    in pkgs.mkShell {
      buildInputs = with pkgs; [ qemu libvirt virt-manager git ];
      shellHook = ''
        echo "Hydrix Development Shell"
        echo ""
        echo "This is the Hydrix framework - not meant to be built directly."
        echo ""
        echo "To use Hydrix, create a local config:"
        echo "  nix flake init -t github:borttappat/Hydrix"
        echo ""
        echo "Or run the installer:"
        echo "  curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash"
      '';
    };
  };
}
