# flake.nix - Your NixOS configuration with custom installer
{
  description = "NixOS configuration with custom installer and btrfs VM support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, home-manager, ... }@inputs: {
    
    # Custom installer ISO
    nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./installer/installer.nix
        {
          # Make your config available in the installer
          environment.etc."nixos-config".source = self;
          
          # Pre-install fish shell and tools
          programs.fish.enable = true;
          environment.systemPackages = with nixpkgs.legacyPackages.x86_64-linux; [
            git
            curl
            parted
            gptfdisk
            btrfs-progs
            fish
          ];
          
          # Auto-login to make installer UX better
          services.getty.autologinUser = "nixos";
          
          # Set fish as default shell for nixos user
          users.users.nixos.shell = nixpkgs.legacyPackages.x86_64-linux.fish;
          
          # Copy installer wizard to the ISO
          environment.etc."installer/install-wizard.fish" = {
            source = ./installer/install-wizard.fish;
            mode = "0755";
          };
          
          # Copy disko templates
          environment.etc."installer/templates/dual-boot.nix".source = 
            ./installer/disko-templates/dual-boot.nix;
          environment.etc."installer/templates/single-disk.nix".source = 
            ./installer/disko-templates/single-disk.nix;
          environment.etc."installer/templates/vm-optimized.nix".source = 
            ./installer/disko-templates/vm-optimized.nix;
        }
      ];
    };
    
    # Your actual system configurations
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        disko.nixosModules.disko
        ./hosts/example-host/configuration.nix
        ./hosts/common.nix
      ];
    };
    
    # Build installer ISO command
    packages.x86_64-linux = {
      installer-iso = self.nixosConfigurations.installer.config.system.build.isoImage;
    };
    
    # Convenience apps
    apps.x86_64-linux = {
      build-iso = {
        type = "app";
        program = toString (nixpkgs.legacyPackages.x86_64-linux.writeShellScript "build-iso" ''
          nix build .#installer-iso
          echo "ISO built: result/iso/*.iso"
        '');
      };
    };
  };
}
