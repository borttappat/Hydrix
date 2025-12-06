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
      url = "github:nix-community/home-manager/release-25.05";
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

      # Zephyrus ASUS laptop - full host system
      # Build with: ./nixbuild.sh (hostname: zeph)
      zeph = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index
          home-manager.nixosModules.home-manager  # Add home-manager support

          # Base system configuration
          ./modules/base/configuration.nix
          ./modules/base/hardware-config.nix

          # Machine-specific configuration
          # This imports ../../generated/modules/zephyrus-consolidated.nix internally
          # Also imports theming/dynamic.nix and desktop/xinitrc.nix
          ./profiles/machines/zephyrus.nix

          # Core functionality modules (matching dotfiles exactly)
          ./modules/wm/i3.nix
          ./modules/shell/packages.nix
          ./modules/base/services.nix
          ./modules/base/users.nix
          ./modules/theming/colors.nix
          #./modules/hosts.nix  # Commented out in dotfiles
          ./modules/base/virt.nix
          #./modules/scripts.nix  # Commented out in dotfiles
          ./modules/base/audio.nix
          ./modules/desktop/firefox.nix

          # Additional feature modules (all commented out in dotfiles)
          #./modules/pentesting.nix
          #./modules/proxychains.nix
          #./modules/dev.nix
          #./modules/steam.nix
        ];
      };

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
          home-manager.nixosModules.home-manager  # Add home-manager support

          ./profiles/pentest-full.nix
        ];
      };

      vm-comms = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index
          home-manager.nixosModules.home-manager  # Add home-manager support

          ./profiles/comms-full.nix
        ];
      };

      vm-browsing = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index
          home-manager.nixosModules.home-manager  # Add home-manager support

          ./profiles/browsing-full.nix
        ];
      };

      vm-dev = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          nix-index-database.nixosModules.nix-index
          home-manager.nixosModules.home-manager  # Add home-manager support

          ./profiles/dev-full.nix
        ];
      };
    };

    # ========== VM BASE IMAGES ==========
    # Type-specific base images with shaping service
    # Each image has hostname baked in for automatic shaping
    packages.x86_64-linux = {

      # Router VM - single-stage, exact copy of splix
      # Build with: nix build .#router-vm-qcow
      router-vm-qcow = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./modules/router-vm-config.nix ];
        format = "qcow";
      };

      # Pentest MINIMAL base VM - truly minimal (~2GB)
      # Build with: nix build .#pentest-vm-base-minimal
      pentest-vm-base-minimal = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          ./profiles/pentest-base-minimal.nix
        ];
        format = "qcow";
      };

      # Pentest base VM - builds with "pentest-vm" hostname
      # Build with: nix build .#pentest-vm-base
      pentest-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          ./profiles/base-vm.nix
          { networking.hostName = "pentest-vm"; }
        ];
        format = "qcow";
      };

      # Comms base VM - builds with "comms-vm" hostname
      # Build with: nix build .#comms-vm-base
      comms-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          ./profiles/base-vm.nix
          { networking.hostName = "comms-vm"; }
        ];
        format = "qcow";
      };

      # Browsing base VM - builds with "browsing-vm" hostname
      # Build with: nix build .#browsing-vm-base
      browsing-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          ./profiles/base-vm.nix
          { networking.hostName = "browsing-vm"; }
        ];
        format = "qcow";
      };

      # Dev base VM - builds with "dev-vm" hostname
      # Build with: nix build .#dev-vm-base
      dev-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.config.allowUnfree = true; }
          { nixpkgs.overlays = [ overlay-unstable ]; }
          ./profiles/base-vm.nix
          { networking.hostName = "dev-vm"; }
        ];
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
            echo ""
            echo "Base Images (one per VM type):"
            echo "  nix build .#pentest-vm-base   # Pentest base image"
            echo "  nix build .#comms-vm-base     # Comms base image"
            echo "  nix build .#browsing-vm-base  # Browsing base image"
            echo "  nix build .#dev-vm-base       # Dev base image"
            echo "  nix build .#router-vm-qcow    # Router VM (single-stage)"
            echo ""
            echo "Deploy VMs (auto-builds base image if needed):"
            echo "  ./scripts/build-vm.sh --type pentest --name google"
            echo "  ./scripts/build-vm.sh --type comms --name signal"
            echo "  ./scripts/build-vm.sh --type browsing --name leisure"
            echo "  ./scripts/build-vm.sh --type dev --name rust"
          '';
        };
      }
    );
  };
}
