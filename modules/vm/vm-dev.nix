# VM Dev Module - Package development tools for VMs
#
# This module provides:
# - vm-dev: Manage per-package flakes (build/run/list/remove/edit/update/install)
# - vm-dev-add-github: Create flake from GitHub URL with language detection
# - vm-sync: Stage packages for host
#
# Supported languages:
# - Rust (Cargo.toml)
# - Go (go.mod)
# - Python (pyproject.toml, setup.py, requirements.txt, bare .py)
# - Node.js/npm (package.json + package-lock.json)
# - Node.js/Yarn (package.json + yarn.lock)
# - C/C++ CMake (CMakeLists.txt)
# - C/C++ Meson (meson.build)
# - C/C++ Autotools (configure.ac, Makefile.in)
# - Haskell (*.cabal)
# - Elixir (mix.exs)
# - Ruby (Gemfile)
# - Java/Maven (pom.xml)
# - Java/Gradle (build.gradle, build.gradle.kts)
# - .NET (*.csproj)
# - Nim (*.nimble)
# - Zig (build.zig)
# - OCaml/Dune (dune-project, *.opam)
# - Perl (Makefile.PL, Build.PL)
# - PHP/Composer (composer.json)
# - Crystal (shard.yml)
#
# Imported by both vm-base.nix (libvirt VMs) and microvm-base.nix (microVMs)
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  vmType = config.hydrix.vmType;
  username = config.hydrix.username;

  # Hash placeholder - user runs build, extracts real hash from error message
  hashPlaceholder = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Externalized flake templates - no more triple-escaping in heredocs
  templateDir = pkgs.runCommand "vm-dev-templates" {} ''
        mkdir -p $out

        cat > $out/rust.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
          src = pkgs.fetchFromGitHub {
            owner = "@OWNER@";
            repo = "@REPO@";
            rev = "@BRANCH@";
            hash = "@HASH@";
          };
        in {
          packages.''${system}.default = pkgs.rustPlatform.buildRustPackage {
            pname = "@NAME@";
            version = "unstable";
            inherit src;
            @CARGO_HASH_LINE@
          };
        };
    }
    EOF

        cat > $out/go.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.buildGoModule {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            vendorHash = @VENDOR_HASH@;
          };
        };
    }
    EOF

        cat > $out/python-pyproject.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.python3Packages.buildPythonApplication {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            pyproject = true;
            build-system = with pkgs.python3Packages; [
              setuptools
            ];
            propagatedBuildInputs = with pkgs.python3Packages; [
              # runtime deps — add after inspecting the package
            ];@META_LINE@
          };
        };
    }
    EOF

        cat > $out/python-setuptools.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.python3Packages.buildPythonApplication {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            format = "setuptools";
            propagatedBuildInputs = with pkgs.python3Packages; [
              # runtime deps — add after inspecting the package
            ];
          };
        };
    }
    EOF

        cat > $out/python-script.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
          pythonEnv = pkgs.python3.withPackages (ps: with ps; [ @NIXPKGS_DEPS@ ]);
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            installPhase = '''
              mkdir -p $out/bin $out/lib/@NAME@
              cp -r . $out/lib/@NAME@/
              chmod -R u+rX $out/lib/@NAME@/
              makeWrapper ''${pythonEnv}/bin/python3 $out/bin/@NAME@ \
                --add-flags "$out/lib/@NAME@/@ENTRY_POINT@"
            ''';
            meta.mainProgram = "@NAME@";
          };
        };
    }
    EOF

        cat > $out/npm.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.buildNpmPackage {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            npmDepsHash = "@PLACEHOLDER@";
          };
        };
    }
    EOF

        cat > $out/yarn.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.mkYarnPackage {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
          };
        };
    }
    EOF

        cat > $out/cmake.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = with pkgs; [ cmake ];
            buildInputs = with pkgs; [ ];
          };
        };
    }
    EOF

        cat > $out/meson.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = with pkgs; [ meson ninja pkg-config ];
            buildInputs = with pkgs; [ ];
          };
        };
    }
    EOF

        cat > $out/autotools.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = with pkgs; [ autoreconfHook ];
            buildInputs = with pkgs; [ ];
          };
        };
    }
    EOF

        cat > $out/haskell.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
          src = pkgs.fetchFromGitHub {
            owner = "@OWNER@";
            repo = "@REPO@";
            rev = "@BRANCH@";
            hash = "@HASH@";
          };
        in {
          packages.''${system}.default = pkgs.haskellPackages.callCabal2nix "@NAME@" src { };
        };
    }
    EOF

        cat > $out/elixir.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.beam.packages.erlang.mixRelease {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            mixFodDeps = pkgs.beam.packages.erlang.fetchMixDeps {
              pname = "@NAME@-deps";
              version = "unstable";
              src = pkgs.fetchFromGitHub {
                owner = "@OWNER@";
                repo = "@REPO@";
                rev = "@BRANCH@";
                hash = "@HASH@";
              };
              hash = "@PLACEHOLDER@";
            };
          };
        };
    }
    EOF

        cat > $out/ruby.nix << 'EOF'
    # Ruby/Bundler packages require gemset.nix from bundix.
    # Auto-generation is not supported. Manual steps:
    #
    #   cd ~/dev/packages/@NAME@
    #   nix-shell -p bundix ruby -- bundix
    #   vm-dev rebuild @NAME@
    #
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.bundlerApp {
            pname = "@NAME@";
            gemdir = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            exes = [ "@NAME@" ];
          };
        };
    }
    EOF

        cat > $out/maven.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.maven.buildMavenPackage {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            mvnHash = "@PLACEHOLDER@";
          };
        };
    }
    EOF

        cat > $out/gradle.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = with pkgs; [ gradle jdk ];
            buildPhase = '''
              export GRADLE_USER_HOME=$PWD/.gradle
              gradle build --no-daemon
            ''';
            installPhase = '''
              mkdir -p $out/lib
              cp build/libs/*.jar $out/lib/
              mkdir -p $out/bin
              cat > $out/bin/@NAME@ << WRAPPER
    #!/bin/sh
    exec ''${pkgs.jre}/bin/java -jar $out/lib/@NAME@.jar "\$@"
    WRAPPER
              chmod +x $out/bin/@NAME@
            ''';
          };
        };
    }
    EOF

        cat > $out/dotnet.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.buildDotnetModule {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nugetDeps = ./deps.nix;
            dotnet-sdk = pkgs.dotnetCorePackages.sdk_8_0;
            dotnet-runtime = pkgs.dotnetCorePackages.runtime_8_0;
          };
        };
    }
    EOF

        cat > $out/makefile.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            # Add dependencies here if build fails (e.g., missing headers)
            # buildInputs = [ pkgs.ncurses pkgs.openssl ];
            installPhase = '''
              mkdir -p $out/bin
              cp @NAME@ $out/bin/ || cp *@NAME@* $out/bin/ || find . -maxdepth 1 -type f -executable -exec cp {} $out/bin/ \;
            ''';
          };
        };
    }
    EOF

        cat > $out/nim.nix << 'NIMTEMPLATE'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
          binName = "@NIM_BIN_NAME@";
        in {
          packages.''${system}.default = pkgs.buildNimPackage {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            # Nim dependencies are auto-resolved via nimble lock
            # If build fails, add nimble deps: nimbleDeps = with pkgs.nimPackages; [ ... ];
          };
        };
    }
    NIMTEMPLATE;

        cat > $out/zig.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = [ pkgs.zig.hook ];
            zigBuildFlags = [ "-Doptimize=ReleaseSafe" ];
          };
        };
    }
    EOF

        cat > $out/ocaml.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.ocamlPackages.buildDunePackage {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            buildInputs = with pkgs.ocamlPackages; [
              # add OCaml deps here (e.g. lwt cmdliner yojson)
            ];
          };
        };
    }
    EOF

        cat > $out/perl.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.perlPackages.buildPerlPackage {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            buildInputs = with pkgs.perlPackages; [
              # add CPAN deps here
            ];
          };
        };
    }
    EOF

        cat > $out/php.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.php.buildComposerProject {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            vendorHash = "@PLACEHOLDER@";
          };
        };
    }
    EOF

        cat > $out/crystal.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            nativeBuildInputs = with pkgs; [ crystal shards ];
            buildPhase = '''
              shards build --release --no-debug
            ''';
            installPhase = '''
              mkdir -p $out/bin
              cp bin/* $out/bin/
            ''';
          };
        };
    }
    EOF

        cat > $out/generic.nix << 'EOF'
    {
      description = "@NAME@ - tested in VM";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      outputs = { self, nixpkgs }:
        let
          system = "@SYSTEM@";
          pkgs = nixpkgs.legacyPackages.''${system};
        in {
          packages.''${system}.default = pkgs.stdenv.mkDerivation {
            pname = "@NAME@";
            version = "unstable";
            src = pkgs.fetchFromGitHub {
              owner = "@OWNER@";
              repo = "@REPO@";
              rev = "@BRANCH@";
              hash = "@HASH@";
            };
            # Add dependencies here if build fails (e.g., missing headers)
            # buildInputs = [ pkgs.ncurses pkgs.openssl ];
            installPhase = '''
              mkdir -p $out/bin
              # Adjust based on what the build produces
              cp @NAME@ $out/bin/ 2>/dev/null || find . -maxdepth 1 -type f -executable -exec cp {} $out/bin/ \;
            ''';
          };
        };
    }
    EOF
  '';
in {
  config = {
    environment.systemPackages = [
      # ===== vm-sync: Stage packages for host =====
      # Uses local directories (no 9p writes needed):
      # - ~/dev/packages/<name>/flake.nix  (development)
      # - ~/staging/<name>/package.nix     (ready for host)
      # Host pulls via vsock (port 14502)
      (pkgs.writeShellScriptBin "vm-sync" ''
        #!/usr/bin/env bash
        set -e

        VM_TYPE="${vmType}"
        DEV_PACKAGES_DIR="$HOME/dev/packages"
        STAGING_DIR="$HOME/staging"

        usage() {
          echo "vm-sync - Stage packages for host"
          echo ""
          echo "Commands:"
          echo "  push --name <pkg>   Stage package for host"
          echo "  push --all          Stage all packages"
          echo "  list                List staged packages"
          echo "  status              Show dev + staged packages"
          echo ""
          echo "Workflow:"
          echo "  1. vm-dev build <github-url>"
          echo "  2. vm-dev run <pkg>"
          echo "  3. vm-sync push --name <pkg>"
          echo "  4. On host: vm-sync pull <pkg> --from <vm>"
          echo ""
          echo "Directories:"
          echo "  ~/dev/packages/<pkg>/   Development flakes"
          echo "  ~/staging/<pkg>/        Staged for host"
        }

        cmd_list() {
          echo "Staged packages (ready for host):"
          if [ -d "$STAGING_DIR" ]; then
            local found=false
            for dir in "$STAGING_DIR"/*/; do
              if [ -f "''${dir}package.nix" ]; then
                echo "  $(basename "$dir")"
                found=true
              fi
            done
            if [ "$found" = false ]; then
              echo "  (none)"
            fi
          else
            echo "  (none)"
          fi
        }

        cmd_status() {
          echo "Development packages:"
          if [ -d "$DEV_PACKAGES_DIR" ]; then
            local found=false
            for dir in "$DEV_PACKAGES_DIR"/*/; do
              if [ -f "''${dir}flake.nix" ]; then
                local name=$(basename "$dir")
                # Check if also staged
                if [ -f "$STAGING_DIR/$name/package.nix" ]; then
                  echo "  $name [staged]"
                else
                  echo "  $name"
                fi
                found=true
              fi
            done
            if [ "$found" = false ]; then
              echo "  (none)"
            fi
          else
            echo "  (none)"
          fi
          echo ""
          cmd_list
        }

        # Extract derivation from flake.nix to package.nix
        extract_package() {
          local pkg="$1"
          local pkg_dir="$DEV_PACKAGES_DIR/$pkg"
          local staging_pkg_dir="$STAGING_DIR/$pkg"

          if [ ! -f "$pkg_dir/flake.nix" ]; then
            echo "Error: Package '$pkg' not found at $pkg_dir"
            exit 1
          fi

          mkdir -p "$staging_pkg_dir"

          # Extract derivation and any let-bindings from flake.nix
          local content
          content=$(cat "$pkg_dir/flake.nix")

          # Extract the derivation block (everything from pkgs.* to the };)
          local derivation
          derivation=$(echo "$content" | sed -n '/packages.*default = /,/^      };/p' | \
            sed '1s/.*default = //' | sed '$s/^      };$/      }/')

          if [ -z "$derivation" ]; then
            echo "Error: Could not extract derivation from $pkg_dir/flake.nix"
            exit 1
          fi

          # Extract extra let-bindings (e.g. pythonEnv) from the outputs let block
          # Skip the standard system/pkgs bindings, capture everything else
          local let_bindings
          let_bindings=$(echo "$content" | awk '
            /^    let$/ { in_let=1; next }
            /^    in \{/ { in_let=0; next }
            in_let && /^\s+system\s*=/ { next }
            in_let && /^\s+pkgs\s*=/ { next }
            in_let { print }
          ')

          # Write package.nix
          {
            echo "# $pkg - from VM"
            echo "{ pkgs }:"
            if [ -n "$(echo "$let_bindings" | tr -d '[:space:]')" ]; then
              echo "let"
              echo "$let_bindings"
              echo "in"
            fi
            echo "$derivation"
          } > "$staging_pkg_dir/package.nix"

          echo "Staged: $pkg"
        }

        cmd_push() {
          local push_name=""
          local push_all=false

          while [[ $# -gt 0 ]]; do
            case "$1" in
              --name|-n) push_name="$2"; shift 2 ;;
              --all|-a) push_all=true; shift ;;
              *) shift ;;
            esac
          done

          if [ -n "$push_name" ]; then
            extract_package "$push_name"
            echo ""
            echo "Staged. Host can pull via: vm-sync pull $push_name"
            return
          fi

          if [ "$push_all" = true ]; then
            local count=0
            for dir in "$DEV_PACKAGES_DIR"/*/; do
              if [ -f "''${dir}flake.nix" ]; then
                extract_package "$(basename "$dir")"
                ((count++)) || true
              fi
            done
            echo ""
            echo "Staged $count packages"
            echo "On host: vm-sync list"
            return
          fi

          usage
        }

        case "''${1:-}" in
          push) shift; cmd_push "$@" ;;
          list|ls) cmd_list ;;
          status) cmd_status ;;
          *) usage ;;
        esac
      '')

      # ===== vm-dev: Manage dev environment with per-package flakes =====
      # Uses local directories (persisted via home volume, not 9p):
      # - ~/dev/packages/<name>/flake.nix  (development)
      (pkgs.writeShellScriptBin "vm-dev" ''
        #!/usr/bin/env bash
        PACKAGES_DIR="$HOME/dev/packages"
        LEGACY_DIR="$HOME/dev"

        usage() {
          echo "vm-dev - Manage dev environment"
          echo ""
          echo "Commands:"
          echo "  build <url> [name] Build package from GitHub URL"
          echo "  run <pkg> [args]   Run a package"
          echo "  fix <pkg>          Analyze errors, suggest fixes (interactive)"
          echo "  rebuild <pkg>      Rebuild package"
          echo "  list               List all packages"
          echo "  remove <pkg>       Remove a package"
          echo "  install <pkg>      Install to user profile (persistent)"
          echo "  edit <pkg>         Edit package flake"
          echo "  update [pkg]       Update flake.lock (all if no pkg)"
          echo "  add <pkg>          Add nixpkgs package (legacy)"
          echo ""
          echo "Workflow:"
          echo "  vm-dev build https://github.com/owner/repo"
          echo "  vm-dev run repo        # fails with missing ncurses.h"
          echo "  vm-dev fix repo        # suggests: buildInputs = [ pkgs.ncurses ]"
          echo "  vm-dev run repo        # works!"
          echo "  vm-sync push --name repo"
          echo ""
          echo "Directories:"
          echo "  ~/dev/packages/<pkg>/  Per-package flakes"
          echo "  ~/staging/<pkg>/       Staged for host (after push)"
        }

        cmd_run() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev run <pkg> [args]"; exit 1; }
          local pkg="$1"
          shift

          # Check per-package flake first
          if [ -f "$PACKAGES_DIR/$pkg/flake.nix" ]; then
            cd "$PACKAGES_DIR/$pkg"
            exec nix run ".#default" -- "$@"
          fi

          # Fall back to legacy flake
          if [ -f "$LEGACY_DIR/flake.nix" ]; then
            cd "$LEGACY_DIR"
            exec nix run ".#$pkg" -- "$@"
          fi

          echo "Error: Package '$pkg' not found"
          echo "Available packages:"
          cmd_list
          exit 1
        }

        cmd_list() {
          echo "Per-package flakes ($PACKAGES_DIR):"
          if [ -d "$PACKAGES_DIR" ]; then
            for dir in "$PACKAGES_DIR"/*/; do
              if [ -f "''${dir}flake.nix" ]; then
                local name=$(basename "$dir")
                echo "  $name"
              fi
            done
          else
            echo "  (none)"
          fi

          # Also show legacy flake packages if any
          if [ -f "$LEGACY_DIR/flake.nix" ]; then
            echo ""
            echo "Legacy flake packages ($LEGACY_DIR):"
            grep -E "^        [a-z][a-z0-9_-]* = pkgs\." "$LEGACY_DIR/flake.nix" 2>/dev/null | \
              sed 's/.*\([a-z][a-z0-9_-]*\) = pkgs\..*/  \1/' || echo "  (none)"
          fi
        }

        cmd_remove() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev remove <pkg>"; exit 1; }
          local pkg="$1"

          if [ -d "$PACKAGES_DIR/$pkg" ]; then
            rm -rf "$PACKAGES_DIR/$pkg"
            echo "Removed: $pkg"
          else
            echo "Package not found: $pkg"
            exit 1
          fi
        }

        cmd_install() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev install <pkg>"; exit 1; }
          local pkg="$1"

          if [ -f "$PACKAGES_DIR/$pkg/flake.nix" ]; then
            cd "$PACKAGES_DIR/$pkg"
            nix profile install ".#default"
            echo ""
            echo "Installed $pkg to user profile"
            echo "Persists across reboots"
          elif [ -f "$LEGACY_DIR/flake.nix" ]; then
            cd "$LEGACY_DIR"
            nix profile install ".#$pkg"
            echo ""
            echo "Installed $pkg to user profile"
          else
            echo "Error: Package '$pkg' not found"
            exit 1
          fi
        }

        cmd_edit() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev edit <pkg>"; exit 1; }
          local pkg="$1"

          if [ -f "$PACKAGES_DIR/$pkg/flake.nix" ]; then
            ''${EDITOR:-vim} "$PACKAGES_DIR/$pkg/flake.nix"
          elif [ -f "$LEGACY_DIR/flake.nix" ]; then
            ''${EDITOR:-vim} "$LEGACY_DIR/flake.nix"
          else
            echo "Error: Package '$pkg' not found"
            exit 1
          fi
        }

        cmd_update() {
          local pkg="''${1:-}"

          if [ -n "$pkg" ]; then
            if [ -f "$PACKAGES_DIR/$pkg/flake.nix" ]; then
              cd "$PACKAGES_DIR/$pkg"
              nix flake update
              echo "Updated: $pkg"
            else
              echo "Error: Package '$pkg' not found"
              exit 1
            fi
          else
            # Update all
            echo "Updating all packages..."
            if [ -d "$PACKAGES_DIR" ]; then
              for dir in "$PACKAGES_DIR"/*/; do
                if [ -f "''${dir}flake.nix" ]; then
                  local name=$(basename "$dir")
                  echo "Updating $name..."
                  (cd "$dir" && nix flake update) || true
                fi
              done
            fi
            if [ -f "$LEGACY_DIR/flake.nix" ]; then
              echo "Updating legacy flake..."
              (cd "$LEGACY_DIR" && nix flake update) || true
            fi
            echo "Done"
          fi
        }

        # Add nixpkgs package to legacy flake
        cmd_add() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev add <pkg> [pkg2] ..."; exit 1; }

          if [ ! -f "$LEGACY_DIR/flake.nix" ]; then
            echo "Error: Legacy flake not found at $LEGACY_DIR/flake.nix"
            exit 1
          fi

          for pkg in "$@"; do
            if grep -q "# $pkg = " "$LEGACY_DIR/flake.nix"; then
              sed -i "s/# $pkg = /$pkg = /" "$LEGACY_DIR/flake.nix"
              echo "Enabled: $pkg"
            elif grep -q "$pkg = " "$LEGACY_DIR/flake.nix"; then
              echo "$pkg already enabled"
              continue
            else
              sed -i "/# === ADD PACKAGES/a\\        $pkg = pkgs.$pkg;" "$LEGACY_DIR/flake.nix"
              echo "Added: $pkg"
            fi
          done
          echo ""
          echo "Test with: vm-dev run $1"
        }

        # Build package from GitHub URL (calls vm-dev-add-github)
        cmd_build() {
          exec vm-dev-add-github "$@"
        }

        # Smart fix: analyze build errors and suggest fixes
        cmd_fix() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev fix <pkg>"; exit 1; }
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"
          local flake="$pkg_dir/flake.nix"
          local log="$pkg_dir/build.log"

          if [ ! -f "$flake" ]; then
            echo "Error: Package '$pkg' not found"
            exit 1
          fi

          # Header to package mapping
          declare -A HEADER_MAP=(
            ["ncurses.h"]="ncurses"
            ["curses.h"]="ncurses"
            ["panel.h"]="ncurses"
            ["openssl/ssl.h"]="openssl"
            ["openssl/crypto.h"]="openssl"
            ["zlib.h"]="zlib"
            ["curl/curl.h"]="curl"
            ["sqlite3.h"]="sqlite"
            ["readline/readline.h"]="readline"
            ["png.h"]="libpng"
            ["jpeglib.h"]="libjpeg"
            ["X11/Xlib.h"]="xorg.libX11"
            ["SDL.h"]="SDL2"
            ["SDL2/SDL.h"]="SDL2"
            ["pcre.h"]="pcre"
            ["pcre2.h"]="pcre2"
            ["uuid/uuid.h"]="libuuid"
            ["libusb.h"]="libusb1"
            ["json-c/json.h"]="json_c"
            ["yaml.h"]="libyaml"
            ["expat.h"]="expat"
            ["lzma.h"]="xz"
            ["archive.h"]="libarchive"
            ["bz2.h"]="bzip2"
            ["gmp.h"]="gmp"
            ["ffi.h"]="libffi"
            ["iconv.h"]="libiconv"
          )

          # Library to package mapping (for -l errors)
          declare -A LIB_MAP=(
            ["ncurses"]="ncurses"
            ["curses"]="ncurses"
            ["ssl"]="openssl"
            ["crypto"]="openssl"
            ["z"]="zlib"
            ["curl"]="curl"
            ["sqlite3"]="sqlite"
            ["readline"]="readline"
            ["png"]="libpng"
            ["jpeg"]="libjpeg"
            ["X11"]="xorg.libX11"
            ["SDL2"]="SDL2"
            ["pcre"]="pcre"
            ["pcre2"]="pcre2"
            ["uuid"]="libuuid"
            ["usb"]="libusb1"
            ["json-c"]="json_c"
            ["yaml"]="libyaml"
            ["expat"]="expat"
            ["lzma"]="xz"
            ["archive"]="libarchive"
            ["bz2"]="bzip2"
            ["gmp"]="gmp"
            ["ffi"]="libffi"
            ["m"]=""  # math library, in glibc
            ["pthread"]=""  # in glibc
            ["dl"]=""  # in glibc
            ["rt"]=""  # in glibc
          )

          echo "Analyzing build errors for $pkg..."
          echo ""

          if [ ! -f "$log" ]; then
            echo "No build.log found. Run: vm-dev run $pkg"
            exit 1
          fi

          local suggestions=()
          local install_phase_fix=""

          # Check for missing headers
          while IFS= read -r line; do
            if [[ "$line" =~ fatal\ error:\ ([^:]+):\ No\ such\ file ]]; then
              local header="''${BASH_REMATCH[1]}"
              local dep="''${HEADER_MAP[$header]:-}"
              if [ -n "$dep" ]; then
                suggestions+=("$dep")
                echo "Found: missing header '$header' -> need '$dep'"
              else
                echo "Found: missing header '$header' (unknown package)"
              fi
            fi
          done < <(grep "fatal error:" "$log" 2>/dev/null)

          # Check for missing libraries (-l)
          while IFS= read -r line; do
            if [[ "$line" =~ cannot\ find\ -l([a-zA-Z0-9_]+) ]]; then
              local lib="''${BASH_REMATCH[1]}"
              local dep="''${LIB_MAP[$lib]:-}"
              if [ -n "$dep" ]; then
                suggestions+=("$dep")
                echo "Found: missing library '-l$lib' -> need '$dep'"
              elif [ -z "''${LIB_MAP[$lib]+x}" ]; then
                echo "Found: missing library '-l$lib' (unknown package)"
              fi
            fi
          done < <(grep "cannot find -l" "$log" 2>/dev/null)

          # Check for install phase issues
          if grep -q "cp: cannot stat" "$log" 2>/dev/null; then
            echo "Found: installPhase trying to copy non-existent file"
            install_phase_fix="check"
          fi

          # Remove duplicates
          local unique_deps=($(printf "%s\n" "''${suggestions[@]}" | sort -u))

          echo ""

          if [ ''${#unique_deps[@]} -eq 0 ] && [ -z "$install_phase_fix" ]; then
            echo "No automatic fixes detected."
            echo "Check the full log: less $log"
            exit 0
          fi

          # Show current buildInputs
          echo "Current flake.nix buildInputs:"
          grep -E "buildInputs\s*=" "$flake" 2>/dev/null || echo "  (none found)"
          echo ""

          # Suggest buildInputs fix
          if [ ''${#unique_deps[@]} -gt 0 ]; then
            local deps_str=$(printf "pkgs.%s " "''${unique_deps[@]}")
            echo "Suggested fix:"
            echo "  buildInputs = [ $deps_str];"
            echo ""
            read -p "Add these to buildInputs? [y/N] " confirm
            if [[ "$confirm" =~ ^[Yy] ]]; then
              # Check if buildInputs exists
              if grep -q "buildInputs\s*=" "$flake"; then
                # Add to existing buildInputs
                for dep in "''${unique_deps[@]}"; do
                  if ! grep -q "pkgs\.$dep" "$flake"; then
                    sed -i "s/buildInputs\s*=\s*\[/buildInputs = [ pkgs.$dep /" "$flake"
                    echo "Added: pkgs.$dep"
                  fi
                done
              else
                # Insert buildInputs after the src block (after hash line + closing brace)
                # Find the line number of the hash inside fetchFromGitHub, then add after the };
                local hash_line=$(grep -n "hash = " "$flake" | head -1 | cut -d: -f1)
                if [ -n "$hash_line" ]; then
                  # Insert after the }; that closes fetchFromGitHub (hash_line + 2)
                  local insert_line=$((hash_line + 2))
                  sed -i "''${insert_line}i\\        buildInputs = [ $deps_str];" "$flake"
                  echo "Added buildInputs line"
                else
                  echo "Could not find insertion point. Edit manually: vm-dev edit $pkg"
                fi
              fi
            fi
          fi

          # Check for installPhase issues
          local needs_install_fix=false

          # Case 1: installPhase doesn't copy anything
          if grep -q 'installPhase.*mkdir.*\$out' "$flake" && ! grep -q "cp .* \\\$out" "$flake"; then
            needs_install_fix=true
            echo ""
            echo "installPhase only creates directory, doesn't copy binary."
          fi

          # Case 2: cp to wrong path (e.g., /bin instead of $out/bin)
          if grep -q "cp: cannot create.*Permission denied" "$log" 2>/dev/null; then
            needs_install_fix=true
            echo ""
            echo "installPhase trying to write outside \$out (permission denied)."
          fi

          # Case 3: failed to produce output
          if grep -q "failed to produce output" "$log" 2>/dev/null; then
            needs_install_fix=true
            echo ""
            echo "Build failed to produce output - installPhase may be empty."
          fi

          if [ "$needs_install_fix" = true ]; then
            echo ""
            echo "Fix installPhase manually:"
            echo "  vm-dev edit $pkg"
            echo ""
            echo "Change installPhase to:"
            printf '  installPhase = %s%s\n' "'" "'"
            printf '    mkdir -p $out/bin\n'
            printf '    cp %s $out/bin/\n' "$pkg"
            printf '  %s%s;\n' "'" "'"
          fi

          echo ""
          echo "Rebuilding..."
          cd "$pkg_dir"
          if nix build ".#default" 2>&1 | tee "$log"; then
            echo ""
            echo "Build succeeded!"
            echo "Test with: vm-dev run $pkg"
          else
            echo ""
            echo "Build still failing. Run 'vm-dev fix $pkg' again or check the log."
          fi
        }

        # Rebuild package (just run nix build)
        cmd_rebuild() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev rebuild <pkg>"; exit 1; }
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"

          if [ ! -f "$pkg_dir/flake.nix" ]; then
            echo "Error: Package '$pkg' not found"
            exit 1
          fi

          cd "$pkg_dir"
          echo "Building $pkg..."
          if nix build ".#default" 2>&1 | tee "$pkg_dir/build.log"; then
            echo ""
            echo "Build succeeded!"
            echo "Test with: vm-dev run $pkg"
          else
            echo ""
            echo "Build failed. Run 'vm-dev fix $pkg' to analyze errors."
          fi
        }

        case "''${1:-}" in
          build) shift; cmd_build "$@" ;;
          run) shift; cmd_run "$@" ;;
          list|ls) cmd_list ;;
          remove|rm) shift; cmd_remove "$@" ;;
          install) shift; cmd_install "$@" ;;
          edit) shift; cmd_edit "$@" ;;
          update) shift; cmd_update "$@" ;;
          add) shift; cmd_add "$@" ;;
          fix) shift; cmd_fix "$@" ;;
          rebuild) shift; cmd_rebuild "$@" ;;
          *) usage ;;
        esac
      '')

      # ===== vm-dev-add-github: Create per-package flake from GitHub URL =====
      # Uses local ~/dev/packages/ (persisted via home volume, not 9p)
      (pkgs.writeShellScriptBin "vm-dev-add-github" ''
        #!/usr/bin/env bash
        set -e

        PACKAGES_DIR="$HOME/dev/packages"

        usage() {
          echo "vm-dev build - Create per-package flake from GitHub URL"
          echo ""
          echo "Usage: vm-dev build <github-url> [name]"
          echo ""
          echo "Examples:"
          echo "  vm-dev build https://github.com/buildoak/tortuise"
          echo "  vm-dev build https://github.com/zellij-org/zellij myzel"
          echo ""
          echo "Supported project types:"
          echo "  - Rust (Cargo.toml)"
          echo "  - Go (go.mod)"
          echo "  - Python (setup.py, pyproject.toml, requirements.txt, bare .py)"
          echo "  - Node.js/npm (package.json + package-lock.json)"
          echo "  - Node.js/Yarn (package.json + yarn.lock)"
          echo "  - C/C++ CMake (CMakeLists.txt)"
          echo "  - C/C++ Meson (meson.build)"
          echo "  - C/C++ Autotools (configure.ac, Makefile.in)"
          echo "  - Haskell (*.cabal)"
          echo "  - Elixir (mix.exs)"
          echo "  - Ruby (Gemfile)"
          echo "  - Java/Maven (pom.xml)"
          echo "  - Java/Gradle (build.gradle)"
          echo "  - .NET (*.csproj)"
          echo "  - Nim (*.nimble)"
          echo "  - Zig (build.zig)"
          echo "  - OCaml/Dune (dune-project, *.opam)"
          echo "  - Perl (Makefile.PL, Build.PL)"
          echo "  - PHP/Composer (composer.json)"
          echo "  - Crystal (shard.yml)"
          echo ""
          echo "Creates: ~/dev/packages/<name>/flake.nix"
          echo ""
          echo "After building:"
          echo "  vm-dev run <name>           # Test the package"
          echo "  vm-sync push --name <name>  # Stage for host"
        }

        if [ -z "$1" ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
          usage
          exit 0
        fi

        URL="$1"

        # Parse GitHub URL
        if [[ "$URL" =~ github\.com/([^/]+)/([^/]+) ]]; then
          OWNER="''${BASH_REMATCH[1]}"
          REPO="''${BASH_REMATCH[2]%.git}"
        else
          echo "Error: Not a valid GitHub URL"
          echo "Expected format: https://github.com/owner/repo"
          exit 1
        fi

        NAME="''${2:-$REPO}"
        PKG_DIR="$PACKAGES_DIR/$NAME"

        # Check if package already exists
        if [ -f "$PKG_DIR/flake.nix" ]; then
          echo "Package '$NAME' already exists at $PKG_DIR"
          echo "To update, remove it first: vm-dev remove $NAME"
          exit 1
        fi

        echo "Adding $OWNER/$REPO as '$NAME'..."

        # Fetch and detect project type
        echo "Fetching repository info..."

        # Try main branch first, then master
        BRANCH="main"
        ARCHIVE_URL="https://github.com/$OWNER/$REPO/archive/main.tar.gz"

        echo "Trying branch: main..."
        HASH_NIX32=$(${pkgs.nix}/bin/nix-prefetch-url --unpack "$ARCHIVE_URL" 2>/dev/null | tail -1)

        if [ -z "$HASH_NIX32" ]; then
          echo "main branch not found, trying master..."
          BRANCH="master"
          ARCHIVE_URL="https://github.com/$OWNER/$REPO/archive/master.tar.gz"
          HASH_NIX32=$(${pkgs.nix}/bin/nix-prefetch-url --unpack "$ARCHIVE_URL" 2>/dev/null | tail -1)
        fi

        if [ -z "$HASH_NIX32" ]; then
          echo "Error: Could not fetch repository. Check if the URL is correct."
          exit 1
        fi

        echo "Using branch: $BRANCH"
        HASH_SRI=$(${pkgs.nix}/bin/nix hash convert --hash-algo sha256 --to sri "$HASH_NIX32" 2>/dev/null || ${pkgs.nix}/bin/nix hash to-sri --type sha256 "$HASH_NIX32" 2>/dev/null)
        echo "Source hash: $HASH_SRI"

        # Detect project type by checking for marker files
        TEMP_DIR=$(mktemp -d)
        echo "Extracting to detect project type..."
        if ! ${pkgs.curl}/bin/curl -sL "$ARCHIVE_URL" | ${pkgs.gnutar}/bin/tar -xz -C "$TEMP_DIR" --strip-components=1; then
          echo "Warning: tar extraction may have failed"
        fi

        PROJECT_TYPE="unknown"
        HAS_PYPROJECT="false"
        MAIN_PROGRAM=""
        NIM_BIN_NAME=""

        # Detection priority order (most specific first)
        if [ -f "$TEMP_DIR/Cargo.toml" ]; then
          PROJECT_TYPE="rust"
        elif [ -f "$TEMP_DIR/go.mod" ]; then
          PROJECT_TYPE="go"
        elif [ -f "$TEMP_DIR/pyproject.toml" ]; then
          PROJECT_TYPE="python"
          HAS_PYPROJECT="true"
          MAIN_PROGRAM=$(${pkgs.gnugrep}/bin/grep -A1 '^\[project.scripts\]' "$TEMP_DIR/pyproject.toml" 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -v '^\[' | head -1 | ${pkgs.gnused}/bin/sed 's/[[:space:]]*=.*//' | tr -d ' "' || true)
          if [ -n "$MAIN_PROGRAM" ]; then
            echo "Detected entry point: $MAIN_PROGRAM"
          fi
        elif [ -f "$TEMP_DIR/setup.py" ]; then
          PROJECT_TYPE="python"
          HAS_PYPROJECT="false"
        elif [ -f "$TEMP_DIR/requirements.txt" ]; then
          PROJECT_TYPE="python-script"
        elif [ -f "$TEMP_DIR/package.json" ] && [ -f "$TEMP_DIR/package-lock.json" ]; then
          PROJECT_TYPE="npm"
        elif [ -f "$TEMP_DIR/package.json" ] && [ -f "$TEMP_DIR/yarn.lock" ]; then
          PROJECT_TYPE="yarn"
        elif [ -f "$TEMP_DIR/CMakeLists.txt" ]; then
          PROJECT_TYPE="cmake"
        elif [ -f "$TEMP_DIR/meson.build" ]; then
          PROJECT_TYPE="meson"
        elif [ -f "$TEMP_DIR/configure.ac" ] || [ -f "$TEMP_DIR/Makefile.in" ]; then
          PROJECT_TYPE="autotools"
        elif ls "$TEMP_DIR"/*.cabal 1>/dev/null 2>&1; then
          PROJECT_TYPE="haskell"
        elif [ -f "$TEMP_DIR/mix.exs" ]; then
          PROJECT_TYPE="elixir"
        elif [ -f "$TEMP_DIR/Gemfile" ]; then
          PROJECT_TYPE="ruby"
        elif [ -f "$TEMP_DIR/pom.xml" ]; then
          PROJECT_TYPE="maven"
        elif [ -f "$TEMP_DIR/build.gradle" ] || [ -f "$TEMP_DIR/build.gradle.kts" ]; then
          PROJECT_TYPE="gradle"
        elif ls "$TEMP_DIR"/*.csproj 1>/dev/null 2>&1; then
          PROJECT_TYPE="dotnet"
        elif ls "$TEMP_DIR"/*.nimble 1>/dev/null 2>&1; then
          PROJECT_TYPE="nim"
          # Extract binary name from nimble file's bin = @["..."]
          NIM_BIN_NAME=$(${pkgs.gnugrep}/bin/grep -oP 'bin\s*=\s*@\"\K[^\"]+' "$TEMP_DIR"/*.nimble 2>/dev/null | head -1 || true)
          [ -n "$NIM_BIN_NAME" ] && echo "Detected binary name: $NIM_BIN_NAME"
        elif [ -f "$TEMP_DIR/build.zig" ]; then
          PROJECT_TYPE="zig"
        elif [ -f "$TEMP_DIR/dune-project" ] || ls "$TEMP_DIR"/*.opam 1>/dev/null 2>&1; then
          PROJECT_TYPE="ocaml"
        elif [ -f "$TEMP_DIR/Makefile.PL" ] || [ -f "$TEMP_DIR/Build.PL" ]; then
          PROJECT_TYPE="perl"
        elif [ -f "$TEMP_DIR/composer.json" ]; then
          PROJECT_TYPE="php"
        elif [ -f "$TEMP_DIR/shard.yml" ]; then
          PROJECT_TYPE="crystal"
        elif [ -f "$TEMP_DIR/Makefile" ]; then
          PROJECT_TYPE="makefile"
        elif ls "$TEMP_DIR"/*.py 1>/dev/null 2>&1; then
          PROJECT_TYPE="python-script"
        fi
        # ── Python script: parse requirements + find entry point ──────────────
        NIXPKGS_DEPS=""
        ENTRY_POINT=""

        if [ "$PROJECT_TYPE" = "python-script" ]; then

          # pip name → nixpkgs python3Packages name
          # Rule: lowercase, replace - with _; known renames override that.
          declare -A PIP_NIX=(
            # stdlib-adjacent / packaging infra (skip or safe to include)
            ["setuptools"]="setuptools"
            ["wheel"]="wheel"
            ["pip"]=""
            ["six"]="six"
            ["attrs"]="attrs"
            ["packaging"]="packaging"
            ["toml"]="toml"
            ["tomli"]="tomli"
            # HTTP / networking
            ["requests"]="requests"
            ["urllib3"]="urllib3"
            ["certifi"]="certifi"
            ["charset-normalizer"]="charset-normalizer"
            ["idna"]="idna"
            ["httpx"]="httpx"
            ["aiohttp"]="aiohttp"
            ["websockets"]="websockets"
            # Web / HTML
            ["flask"]="flask"
            ["Flask"]="flask"
            ["django"]="django"
            ["Django"]="django"
            ["fastapi"]="fastapi"
            ["starlette"]="starlette"
            ["jinja2"]="jinja2"
            ["Jinja2"]="jinja2"
            ["markupsafe"]="markupsafe"
            ["MarkupSafe"]="markupsafe"
            ["beautifulsoup4"]="beautifulsoup4"
            ["bs4"]="beautifulsoup4"
            ["lxml"]="lxml"
            ["html5lib"]="html5lib"
            # CLI / output
            ["click"]="click"
            ["typer"]="typer"
            ["fire"]="fire"
            ["python-fire"]="fire"
            ["argcomplete"]="argcomplete"
            ["rich"]="rich"
            ["tqdm"]="tqdm"
            ["colorama"]="colorama"
            ["tabulate"]="tabulate"
            ["termcolor"]="termcolor"
            ["colorlog"]="colorlog"
            ["loguru"]="loguru"
            # Data
            ["numpy"]="numpy"
            ["pandas"]="pandas"
            ["scipy"]="scipy"
            ["matplotlib"]="matplotlib"
            ["scikit-learn"]="scikit-learn"
            ["sklearn"]="scikit-learn"
            ["Pillow"]="pillow"
            ["PIL"]="pillow"
            ["pyyaml"]="pyyaml"
            ["PyYAML"]="pyyaml"
            ["regex"]="regex"
            ["chardet"]="chardet"
            ["python-dateutil"]="dateutil"
            ["arrow"]="arrow"
            ["ftfy"]="ftfy"
            # DB / ORM
            ["sqlalchemy"]="sqlalchemy"
            ["SQLAlchemy"]="sqlalchemy"
            ["psycopg2"]="psycopg2"
            ["pymysql"]="pymysql"
            ["redis"]="redis"
            # Auth / secrets
            ["cryptography"]="cryptography"
            ["pyOpenSSL"]="pyopenssl"
            ["paramiko"]="paramiko"
            ["pycryptodome"]="pycryptodome"
            ["pycryptodomex"]="pycryptodome"
            ["python-dotenv"]="python-dotenv"
            ["dotenv"]="python-dotenv"
            # Pentest / OSINT
            ["scapy"]="scapy"
            ["impacket"]="impacket"
            ["netaddr"]="netaddr"
            ["dnspython"]="dnspython"
            ["python-nmap"]="python-nmap"
            ["ldap3"]="ldap3"
            ["pysmb"]="pysmb"
            ["shodan"]="shodan"
            ["requests-oauthlib"]="requests-oauthlib"
            ["PyGithub"]="pygithub"
            ["github3.py"]="github3_py"
            ["tweepy"]="tweepy"
            # Misc
            ["boto3"]="boto3"
            ["botocore"]="botocore"
            ["pydantic"]="pydantic"
            ["pytest"]="pytest"
          )

          if [ -f "$TEMP_DIR/requirements.txt" ]; then
            dep_list=()
            while IFS= read -r req_line || [ -n "$req_line" ]; do
              # Strip comments, version specifiers, options flags
              req_line="''${req_line%%#*}"
              req_line="''${req_line%%[>=<!]*}"
              req_line="''${req_line%%[[:space:]]*}"
              # Skip blank lines, -r includes, http paths
              [[ -z "$req_line" || "$req_line" == -* || "$req_line" == http* ]] && continue

              nix_pkg="''${PIP_NIX[$req_line]:-NOTFOUND}"
              if [ "$nix_pkg" = "NOTFOUND" ]; then
                # Best-effort: lowercase + hyphen→underscore
                nix_pkg=$(echo "$req_line" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
              fi
              # Skip empty mappings (e.g. pip, wheel stubs)
              [ -z "$nix_pkg" ] && continue
              dep_list+=("$nix_pkg")
            done < "$TEMP_DIR/requirements.txt"

            # Deduplicate
            if [ ''${#dep_list[@]} -gt 0 ]; then
              NIXPKGS_DEPS=$(printf "%s\n" "''${dep_list[@]}" | sort -u | tr '\n' ' ')
              NIXPKGS_DEPS="''${NIXPKGS_DEPS% }"   # trim trailing space
            fi
          fi

          # ── Entry point detection ──────────────────────────────────────────
          # 1. File matching repo name
          if [ -f "$TEMP_DIR/''${NAME}.py" ]; then
            ENTRY_POINT="''${NAME}.py"
          # 2. __main__.py
          elif [ -f "$TEMP_DIR/__main__.py" ]; then
            ENTRY_POINT="__main__.py"
          # 3. File containing argparse or __name__ == '__main__'
          else
            for pyf in "$TEMP_DIR"/*.py; do
              [ -f "$pyf" ] || continue
              if grep -qE "(if __name__ == ['\"]__main__|argparse\.ArgumentParser|import argparse)" "$pyf" 2>/dev/null; then
                ENTRY_POINT=$(basename "$pyf")
                break
              fi
            done
          fi
          # 4. Fallback: first .py file
          if [ -z "$ENTRY_POINT" ]; then
            first_py=$(ls "$TEMP_DIR"/*.py 2>/dev/null | head -1)
            [ -n "$first_py" ] && ENTRY_POINT=$(basename "$first_py")
          fi
          [ -z "$ENTRY_POINT" ] && ENTRY_POINT="''${NAME}.py"

          echo "Entry point: $ENTRY_POINT"
          echo "Python deps: ''${NIXPKGS_DEPS:-none detected}"
        fi
        # ─────────────────────────────────────────────────────────────────────

        # ── Detect system architecture ──────────────────────────────────────
        CURRENT_SYSTEM=$(${pkgs.nix}/bin/nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null \
          || echo "x86_64-linux")

        # ── Rust: prefer cargoLock.lockFile over cargoHash placeholder ──────
        CARGO_HASH_LINE='cargoHash = "${hashPlaceholder}";'
        if [ "$PROJECT_TYPE" = "rust" ] && [ -f "$TEMP_DIR/Cargo.lock" ]; then
          CARGO_HASH_LINE='cargoLock.lockFile = "''${src}/Cargo.lock";'
          echo "  Found Cargo.lock - using lockFile (no hash needed)"
        fi

        # ── Go: detect vendor/ directory → vendorHash = null ────────────────
        VENDOR_HASH='"${hashPlaceholder}"'
        if [ "$PROJECT_TYPE" = "go" ] && [ -d "$TEMP_DIR/vendor" ]; then
          VENDOR_HASH="null"
          echo "  Found vendor/ directory - building offline"
        fi

        # ── Python: prepare meta line for pyproject ─────────────────────────
        META_LINE=""
        if [ "$PROJECT_TYPE" = "python" ] && [ "$HAS_PYPROJECT" = "true" ] && [ -n "$MAIN_PROGRAM" ]; then
          META_LINE=$'\n        meta.mainProgram = "'"$MAIN_PROGRAM"'";'
        fi

        rm -rf "$TEMP_DIR"

        echo "Detected project type: $PROJECT_TYPE"

        # Generate flake based on project type
        mkdir -p "$PKG_DIR"

        generate_flake() {
          local template="$1"
          ${pkgs.gnused}/bin/sed \
            -e "s|@NAME@|$NAME|g" \
            -e "s|@OWNER@|$OWNER|g" \
            -e "s|@REPO@|$REPO|g" \
            -e "s|@BRANCH@|$BRANCH|g" \
            -e "s|@HASH@|$HASH_SRI|g" \
            -e "s|@SYSTEM@|$CURRENT_SYSTEM|g" \
            -e "s|@VENDOR_HASH@|$VENDOR_HASH|g" \
            -e "s|@CARGO_HASH_LINE@|$CARGO_HASH_LINE|g" \
            -e "s|@NIXPKGS_DEPS@|$NIXPKGS_DEPS|g" \
            -e "s|@ENTRY_POINT@|$ENTRY_POINT|g" \
            -e "s|@PLACEHOLDER@|${hashPlaceholder}|g" \
            -e "s|@META_LINE@|$META_LINE|g" \
            -e "s|@NIM_BIN_NAME@|''${NIM_BIN_NAME:-$NAME}|g" \
            -e "s|NIM_BIN_NAME_PLACEHOLDER|''${NIM_BIN_NAME:-$NAME}|g" \
            -e "s|NAME_PLACEHOLDER|$NAME|g" \
            "$template" > "$PKG_DIR/flake.nix"
        }

        case "$PROJECT_TYPE" in
          rust)
            generate_flake "${templateDir}/rust.nix"
            ;;
          go)
            generate_flake "${templateDir}/go.nix"
            ;;
          python)
            if [ "$HAS_PYPROJECT" = "true" ]; then
              generate_flake "${templateDir}/python-pyproject.nix"
            else
              generate_flake "${templateDir}/python-setuptools.nix"
            fi
            ;;
          python-script)
            generate_flake "${templateDir}/python-script.nix"
            echo ""
            echo "Python deps mapped: ''${NIXPKGS_DEPS:-none}"
            echo "Entry point: $ENTRY_POINT"
            echo "Edit if wrong: vm-dev edit $NAME"
            ;;
          npm)
            generate_flake "${templateDir}/npm.nix"
            ;;
          yarn)
            generate_flake "${templateDir}/yarn.nix"
            ;;
          cmake)
            generate_flake "${templateDir}/cmake.nix"
            ;;
          meson)
            generate_flake "${templateDir}/meson.nix"
            ;;
          autotools)
            generate_flake "${templateDir}/autotools.nix"
            ;;
          haskell)
            generate_flake "${templateDir}/haskell.nix"
            ;;
          elixir)
            generate_flake "${templateDir}/elixir.nix"
            ;;
          ruby)
            generate_flake "${templateDir}/ruby.nix"
            echo ""
            echo "WARNING: Ruby packages require manual bundix setup."
            echo "See instructions in: $PKG_DIR/flake.nix"
            ;;
          maven)
            generate_flake "${templateDir}/maven.nix"
            ;;
          gradle)
            generate_flake "${templateDir}/gradle.nix"
            ;;
          dotnet)
            generate_flake "${templateDir}/dotnet.nix"
            echo ""
            echo "NOTE: .NET packages require deps.nix - run:"
            echo "  cd $PKG_DIR && nix build '.#default.fetch-deps'"
            echo "  ./result $PKG_DIR/deps.nix"
            ;;
          nim)
            generate_flake "${templateDir}/nim.nix"
            ;;
          zig)
            generate_flake "${templateDir}/zig.nix"
            ;;
          ocaml)
            generate_flake "${templateDir}/ocaml.nix"
            ;;
          perl)
            generate_flake "${templateDir}/perl.nix"
            ;;
          php)
            generate_flake "${templateDir}/php.nix"
            echo ""
            echo "NOTE: PHP/Composer vendor hash needs updating - run:"
            echo "  cd $PKG_DIR && nix build 2>&1 | grep 'got:' | awk '{print \$2}'"
            ;;
          crystal)
            generate_flake "${templateDir}/crystal.nix"
            ;;
          makefile)
            echo "Detected Makefile project."
            generate_flake "${templateDir}/makefile.nix"
            ;;
          *)
            echo "Warning: Unknown project type. Creating generic stdenv derivation."
            generate_flake "${templateDir}/generic.nix"
            ;;
        esac

        echo ""
        echo "Created package at $PKG_DIR/flake.nix"

        # Generate lock file
        echo ""
        echo "Generating flake.lock..."
        cd "$PKG_DIR" && ${pkgs.nix}/bin/nix flake update 2>/dev/null || true

        # Try to build and capture the hash from error message
        echo ""
        echo "Attempting initial build..."
        BUILD_OUTPUT=$(cd "$PKG_DIR" && ${pkgs.nix}/bin/nix build ".#default" 2>&1) || true

        # Check if we got a hash mismatch error with the real hash
        REAL_HASH=$(echo "$BUILD_OUTPUT" | ${pkgs.gnugrep}/bin/grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | head -1 || true)

        if [ -n "$REAL_HASH" ]; then
          echo "Got dependency hash: $REAL_HASH"

          # Determine which hash field to update based on project type
          case "$PROJECT_TYPE" in
            rust)
              ${pkgs.gnused}/bin/sed -i "s|cargoHash = \"${hashPlaceholder}\";|cargoHash = \"$REAL_HASH\";|" "$PKG_DIR/flake.nix"
              ;;
            go)
              ${pkgs.gnused}/bin/sed -i "s|vendorHash = \"${hashPlaceholder}\";|vendorHash = \"$REAL_HASH\";|" "$PKG_DIR/flake.nix"
              ;;
            npm)
              ${pkgs.gnused}/bin/sed -i "s|npmDepsHash = \"${hashPlaceholder}\";|npmDepsHash = \"$REAL_HASH\";|" "$PKG_DIR/flake.nix"
              ;;
            maven)
              ${pkgs.gnused}/bin/sed -i "s|mvnHash = \"${hashPlaceholder}\";|mvnHash = \"$REAL_HASH\";|" "$PKG_DIR/flake.nix"
              ;;
            elixir)
              ${pkgs.gnused}/bin/sed -i "s|hash = \"${hashPlaceholder}\";|hash = \"$REAL_HASH\";|" "$PKG_DIR/flake.nix"
              ;;
          esac
          echo "Updated flake with correct hash"

          # Save build log
          echo "$BUILD_OUTPUT" > "$PKG_DIR/build.log"
          echo "Build log saved to $PKG_DIR/build.log"

          # Try building again
          echo ""
          echo "Retrying build..."
          cd "$PKG_DIR" && ${pkgs.nix}/bin/nix build ".#default" 2>&1 | tee -a "$PKG_DIR/build.log" || true
        else
          # Save build log even if no hash mismatch
          echo "$BUILD_OUTPUT" > "$PKG_DIR/build.log"
          if [ -n "$BUILD_OUTPUT" ]; then
            echo "Build log saved to $PKG_DIR/build.log"
          fi

          # For Go packages without vendor/, try to extract vendorHash from build output
          # Nix sometimes provides the hash in different formats
          if [ "$PROJECT_TYPE" = "go" ]; then
            local go_hash
            # Try various patterns that Nix might use
            go_hash=$(echo "$BUILD_OUTPUT" | ${pkgs.gnugrep}/bin/grep -oP 'vendorHash.*got:\s+\Ksha256-[A-Za-z0-9+/=]+' | head -1 || true)
            if [ -z "$go_hash" ]; then
              go_hash=$(echo "$BUILD_OUTPUT" | ${pkgs.gnugrep}/bin/grep -oP 'sha256-[A-Za-z0-9+/=]+' | head -1 || true)
            fi
            if [ -z "$go_hash" ]; then
              go_hash=$(echo "$BUILD_OUTPUT" | ${pkgs.gnugrep}/bin/grep -oP 'sha256-[A-Za-z0-9+/=]{88}' | head -1 || true)
            fi

            if [ -n "$go_hash" ]; then
              echo "Found Go vendorHash in build output: $go_hash"
              ${pkgs.gnused}/bin/sed -i "s|vendorHash = \"${hashPlaceholder}\";|vendorHash = \"$go_hash\";|" "$PKG_DIR/flake.nix"
              echo "Updated flake with vendorHash"
              echo ""
              echo "Retrying build..."
              cd "$PKG_DIR" && ${pkgs.nix}/bin/nix build ".#default" 2>&1 | tee -a "$PKG_DIR/build.log" || true
            else
              echo "Could not extract vendorHash automatically."
              echo "Run: vm-dev-fixhash go $NAME"
            fi
          fi
        fi

        # ── Self-heal: remove bad python3Packages names and retry ─────────────
        if [ "$PROJECT_TYPE" = "python-script" ]; then
          BAD_PKGS=$(echo "$BUILD_OUTPUT" | \
            ${pkgs.gnugrep}/bin/grep -oP "undefined variable '\\K[^']+" | \
            sort -u || true)
          if [ -n "$BAD_PKGS" ]; then
            echo ""
            echo "Removing unresolved packages from flake:"
            for bad_pkg in $BAD_PKGS; do
              echo "  - $bad_pkg"
              # Remove the package name from the withPackages list
              ${pkgs.gnused}/bin/sed -i \
                "s/\bps\.$bad_pkg\b//g; s/\b$bad_pkg\b //g; s/ \b$bad_pkg\b//g" \
                "$PKG_DIR/flake.nix"
            done
            echo "Retrying build..."
            BUILD_OUTPUT=$(cd "$PKG_DIR" && ${pkgs.nix}/bin/nix build ".#default" 2>&1) || true
            echo "$BUILD_OUTPUT" >> "$PKG_DIR/build.log"
            if echo "$BUILD_OUTPUT" | grep -q "error:"; then
              echo "Still failing after cleanup. Run: vm-dev fix $NAME"
            else
              echo "Build succeeded after cleanup."
            fi
          fi
        fi
        # ─────────────────────────────────────────────────────────────────────

        echo ""
        echo "Done! Test with: vm-dev run $NAME"
        echo "Edit flake:     vm-dev edit $NAME"
        echo "Stage for host: vm-sync push --name $NAME"
      '')

      # Alias for backward compatibility
      (pkgs.writeShellScriptBin "mvm-sync" ''
        echo "Note: mvm-sync is renamed to vm-sync"
        exec vm-sync "$@"
      '')

      # ===== vm-dev-fixhash: Compute dependency hashes for Go/NPM packages =====
      # For Go modules without vendor/, computes vendorHash from go.mod/go.sum
      # For NPM packages, computes npmDepsHash from package-lock.json
      (pkgs.writeShellScriptBin "vm-dev-fixhash" ''
        #!/usr/bin/env bash
        set -e

        PACKAGES_DIR="$HOME/dev/packages"

        usage() {
          echo "vm-dev-fixhash - Compute dependency hashes for packages"
          echo ""
          echo "Commands:"
          echo "  go <pkg>     Compute vendorHash for Go package"
          echo "  npm <pkg>    Compute npmDepsHash for NPM package"
          echo "  all <pkg>    Auto-detect and compute hash for package"
          echo ""
          echo "Examples:"
          echo "  vm-dev-fixhash go sheets"
          echo "  vm-dev-fixhash all sheets"
          echo ""
          echo "This computes the correct dependency hash and updates your flake.nix"
          echo "by actually building/fetching the dependencies in the Nix environment."
        }

        # Compute Go module vendorHash
        cmd_go() {
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"

          if [ ! -d "$pkg_dir" ]; then
            echo "Error: Package '$pkg' not found at $pkg_dir"
            exit 1
          fi

          if [ ! -f "$pkg_dir/flake.nix" ]; then
            echo "Error: No flake.nix in $pkg_dir"
            exit 1
          fi

          cd "$pkg_dir"

          # Check for go.mod/go.sum
          if [ ! -f "go.mod" ]; then
            echo "Error: No go.mod found in $pkg_dir"
            exit 1
          fi

          echo "Computing vendorHash for Go module..."

          # Approach: Use go mod download to fetch dependencies, then compute hash
          # The vendorHash needs to match what buildGoModule expects

          # First, try to build and capture the actual error with the correct hash
          echo "Attempting build to extract correct hash..."
          local build_output
          build_output=$(nix build ".#default" 2>&1) || true

          # Check if we got a vendorHash mismatch with the real hash
          local real_hash
          real_hash=$(echo "$build_output" | ${pkgs.gnugrep}/bin/grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | head -1 || true)

          if [ -n "$real_hash" ];
          then
            echo "Found vendorHash in build output: $real_hash"
            ${pkgs.gnused}/bin/sed -i "s|vendorHash = \"[^\"]*\";|vendorHash = \"$real_hash\";|" "$pkg_dir/flake.nix"
            echo "Updated flake.nix"
            echo ""
            echo "Try building again: vm-dev rebuild $pkg"
            return
          fi

          # If that failed, try nix-prefetch-url on go.mod expanded content
          echo "Using alternative hash computation..."

          # Create a temp directory for vendor
          local tmp_vendor
          tmp_vendor=$(mktemp -d)

          # Use go mod vendor to fetch dependencies
          if go mod vendor -mod=mod 2>/dev/null; then
            if [ -d vendor ]; then
              echo "Computing hash from vendored dependencies..."
              local vendor_hash
              vendor_hash=$(nix-prefetch-url --unpack file://$(pwd)/vendor 2>&1 | \
                ${pkgs.gnugrep}/bin/grep -o 'sha256-[A-Za-z0-9+/=]*' | head -1 || true)

              if [ -n "$vendor_hash" ];
              then
                echo "Computed vendorHash: $vendor_hash"
                ${pkgs.gnused}/bin/sed -i "s|vendorHash = \"[^\"]*\";|vendorHash = \"$vendor_hash\";|" "$pkg_dir/flake.nix"
                echo "Updated flake.nix"
                rm -rf "$tmp_vendor"
                echo ""
                echo "Try building again: vm-dev rebuild $pkg"
                return
              fi
            fi
          fi

          rm -rf "$tmp_vendor"

          # Final fallback: manual instructions
          echo "Could not compute vendorHash automatically."
          echo ""
          echo "Manual approach:"
          echo "  1. cd $pkg_dir"
          echo "  2. go mod vendor"
          echo "  3. nix-prefetch-url --unpack file://\$(pwd)/vendor"
          echo "  4. Copy the hash and update vendorHash in flake.nix"
          echo ""
          echo "Or let Nix tell you the hash:"
          echo "  1. Run: nix build '.#default'"
          echo "  2. Copy the 'got: sha256-...' hash from the error"
          echo "  3. Update vendorHash in flake.nix manually"
          exit 1
        }

        # Compute NPM deps hash
        cmd_npm() {
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"

          if [ ! -f "$pkg_dir/package-lock.json" ]; then
            echo "Error: No package-lock.json found in $pkg_dir"
            exit 1
          fi

          cd "$pkg_dir"
          echo "Computing npmDepsHash..."

          # Try build first to get hash from error
          local build_output
          build_output=$(nix build ".#default" 2>&1) || true

          local real_hash
          real_hash=$(echo "$build_output" | ${pkgs.gnugrep}/bin/grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | head -1 || true)

          if [ -n "$real_hash" ];
          then
            echo "Found npmDepsHash in build output: $real_hash"
            ${pkgs.gnused}/bin/sed -i "s|npmDepsHash = \"[^\"]*\";|npmDepsHash = \"$real_hash\";|" "$pkg_dir/flake.nix"
            echo "Updated flake.nix"
            return
          fi

          echo "Failed to compute npmDepsHash automatically"
          echo "Manual approach:"
          echo "  1. Run: nix build '.#default'"
          echo "  2. Copy the 'got: sha256-...' hash from the error"
          echo "  3. Update npmDepsHash in flake.nix manually"
          exit 1
        }

        # Auto-detect project type and compute appropriate hash
        cmd_all() {
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"

          if [ ! -d "$pkg_dir" ]; then
            echo "Error: Package '$pkg' not found at $pkg_dir"
            exit 1
          fi

          if [ -f "$pkg_dir/go.mod" ]; then
            cmd_go "$pkg"
          elif [ -f "$pkg_dir/package-lock.json" ]; then
            cmd_npm "$pkg"
          elif [ -f "$pkg_dir/yarn.lock" ]; then
            echo "Yarn hash computation not yet implemented"
            echo "Manual approach: nix build '.#default' and extract hash from error"
            exit 1
          else
            echo "No supported project type found (go.mod, package-lock.json, yarn.lock)"
            exit 1
          fi
        }

        case ''${2:-} in
          go) shift; shift; cmd_go "$1" ;;
          npm) shift; shift; cmd_npm "$1" ;;
          yarn) shift; shift; echo "Yarn hash computation not yet implemented" ;;
          all) shift; shift; cmd_all "$1" ;;
          -h|--help|"") usage ;;
          *) usage ;;
        esac
      '')
    ];
  };
}
