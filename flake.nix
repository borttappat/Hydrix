{
  description = "Hydrix - Template-driven VM automation system";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nix-index-database = {
      url = "github:Mic92/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, nixos-generators, nix-index-database, ... }@inputs:
  let
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    pkgsForSystem = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    overlay-unstable = final: prev: {
      unstable = import nixpkgs-unstable {
        inherit (prev) system;
        config.allowUnfree = true;
      };
    };

  in {

    # ========== HOST CONFIGURATIONS ==========
    # For installing Hydrix on physical machines
    nixosConfigurations = {

      # Lightweight host - runs VMs, minimal desktop
      host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index

          ./modules/base/nixos-base.nix
          ./modules/base/users.nix
          ./modules/base/networking.nix
          ./modules/base/virt.nix

          ./modules/wm/i3.nix
          ./modules/shell/fish.nix
          ./modules/shell/packages.nix
        ];
      };

      # Full VM configurations (applied AFTER shaping inside VMs)

      vm-pentest = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index

          ./modules/base/nixos-base.nix
          ./modules/base/users.nix
          ./modules/base/networking.nix
          ./modules/vm/qemu-guest.nix

          ./modules/wm/i3.nix
          ./modules/shell/fish.nix
          ./modules/shell/packages.nix

          ./profiles/pentest-full.nix
        ];
      };

      vm-router = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }

          ./modules/base/nixos-base.nix
          ./modules/base/users.nix
          ./modules/vm/qemu-guest.nix

          ./profiles/router-full.nix
        ];
      };

      vm-comms = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index

          ./modules/base/nixos-base.nix
          ./modules/base/users.nix
          ./modules/base/networking.nix
          ./modules/vm/qemu-guest.nix

          ./modules/wm/i3.nix
          ./modules/shell/fish.nix
          ./modules/shell/packages.nix

          ./profiles/comms-full.nix
        ];
      };

      vm-browsing = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index

          ./modules/base/nixos-base.nix
          ./modules/base/users.nix
          ./modules/base/networking.nix
          ./modules/vm/qemu-guest.nix

          ./modules/wm/i3.nix
          ./modules/shell/fish.nix
          ./modules/shell/packages.nix

          ./profiles/browsing-full.nix
        ];
      };

      vm-dev = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index

          ./modules/base/nixos-base.nix
          ./modules/base/users.nix
          ./modules/base/networking.nix
          ./modules/vm/qemu-guest.nix

          ./modules/wm/i3.nix
          ./modules/shell/fish.nix
          ./modules/shell/packages.nix

          ./profiles/dev-full.nix
        ];
      };
    };

    # ========== VM BASE IMAGES ==========
    # Minimal images with shaping service
    packages.x86_64-linux = {

      router-vm = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./profiles/router-base.nix ];
        format = "qcow";
      };

      pentest-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./profiles/pentest-base.nix ];
        format = "qcow";
      };

      comms-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./profiles/comms-base.nix ];
        format = "qcow";
      };

      browsing-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./profiles/browsing-base.nix ];
        format = "qcow";
      };

      dev-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./profiles/dev-base.nix ];
        format = "qcow";
      };
    };

    # ========== DEVELOPMENT SHELL ==========
    devShells = forAllSystems (system:
      let pkgs = pkgsForSystem system;
      in {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nixos-generators
            qemu
            libvirt
            virt-manager
            git
          ];

          shellHook = ''
            echo "Hydrix VM Automation System"
            echo "Available builds:"
            echo "  nix build .#pentest-vm-base"
            echo "  nix build .#router-vm"
            echo "  nix build .#comms-vm-base"
            echo "  nix build .#browsing-vm-base"
            echo "  nix build .#dev-vm-base"
          '';
        };
      }
    );
  };
}
