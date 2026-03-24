# VM Base Module - Central configuration for all VMs (except router)
#
# This module consolidates all common VM configuration:
# - Hardware configuration (kernel modules, boot loader, filesystem)
# - Locale settings from hydrix.locale.* options
# - Common imports (qemu-guest, shared-store, bake-config, etc.)
# - Parameterized rebuild script
#
# By default, libvirt VMs run headless like microVMs - apps forwarded via xpra.
# Enable hydrix.graphical.standalone = true for virt-manager use with full
# i3/polybar environment.
#
# Profiles should import this module and only set profile-specific config:
# - hydrix.vmType
# - hydrix.colorscheme
# - hydrix.vm.defaultHostname
# - Profile-specific packages and services
#
{ config, pkgs, lib, modulesPath, ... }:

let
  cfg = config.hydrix;

  # Get hostname from options
  vmHostname = config.hydrix.vm.defaultHostname;

  # Rebuild target for the script (e.g., "vm-pentest")
  rebuildTarget = config.hydrix.vm.rebuildTarget;

in {
  imports = [
    # QEMU guest profile from nixpkgs
    (modulesPath + "/profiles/qemu-guest.nix")

    # Hydrix options (single source of truth)
    ../options.nix

    # Base system modules
    ../base/nixos-base.nix
    ../base/users-vm.nix
    ../base/networking.nix

    # Minimal CLI environment (always included)
    ./vm-minimal.nix

    # GUI apps for xpra forwarding (alacritty, firefox, obsidian, pywal)
    ./xpra-apps.nix

    # VM theming scripts (wal-sync, set-colorscheme-mode, refresh-colors)
    ./vm-theming.nix

    # VM-specific modules
    ./qemu-guest.nix
    ./shared-store.nix
    ./bake-config.nix
    ./xpra-shared.nix  # Unified xpra module for all VMs
    ./vm-scaling.nix
    ./vm-dev.nix       # vm-dev, vm-sync scripts for package development

    # Core desktop environment (i3, X11)
    # Only activates when hydrix.graphical.enable = true
    ../core.nix

    # Unified graphical environment (Stylix + Home Manager)
    # Only activates when hydrix.graphical.enable = true
    ../graphical
  ];

  options.hydrix.vm = {
    defaultHostname = lib.mkOption {
      type = lib.types.str;
      default = "${config.hydrix.vmType or "unknown"}-vm";
      description = "Default VM hostname";
    };

    rebuildTarget = lib.mkOption {
      type = lib.types.str;
      default = "vm-${config.hydrix.vmType or "unknown"}";
      description = "Flake target for rebuild script (e.g., vm-pentest)";
    };
  };

  config = {
    # ===== Disable heavy/host-only services =====
    # These services are either wasteful in VMs or host-specific
    services.ollama.enable = lib.mkForce false;      # LLM service - 500MB-8GB RAM, useless in VMs
    services.auto-cpufreq.enable = lib.mkForce false; # CPU freq scaling - useless in QEMU
    services.rsyncd.enable = lib.mkForce false;       # rsync daemon - not needed in VMs
    services.tailscale.enable = lib.mkForce false;    # VPN - host-only

    # ===== Graphical environment =====
    # When standalone = true, the VM has its own i3/polybar environment (for virt-manager)
    # When standalone = false (default), apps are forwarded via xpra to host
    # The graphical modules are always imported but only activate when enable = true
    hydrix.graphical.enable = lib.mkDefault cfg.graphical.standalone;

    # ===== Entropy generation =====
    # Ensures reliable entropy for VMs (fixes potential stalls)
    services.haveged.enable = true;

    # ===== Hardware configuration for QEMU VMs =====
    # QEMU hardware is always the same - no hardware-configuration.nix needed
    boot.initrd.availableKernelModules = [
      "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
      "virtio_net" "virtio_scsi" "virtio_console"
      "ahci" "xhci_pci" "sd_mod" "sr_mod"
    ];
    # 9p modules must be loaded early for config mount
    boot.initrd.kernelModules = [ "9p" "9pnet" "9pnet_virtio" ];
    boot.kernelModules = [ "kvm-intel" "kvm-amd" "virtio_rng" ];

    # Entropy settings to prevent VM hangs during image build
    boot.kernelParams = [
      "random.trust_cpu=on"
      "rng_core.default_quality=1000"
    ];
    boot.extraModulePackages = [ ];

    # Boot loader
    boot.loader.grub = {
      enable = true;
      device = lib.mkDefault "/dev/vda";
      efiSupport = false;
      useOSProber = false;
    };

    # Filesystem - nixos-generators creates disk with label "nixos"
    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    swapDevices = [ ];

    # ===== Host profiles writeback mount =====
    # Allows VM to edit its profile on the host for live development
    # Mounted via 9p from deploy-vm.sh (target: hydrix-profiles)
    fileSystems."/mnt/hydrix-profiles" = {
      device = "hydrix-profiles";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "rw"
        "nofail"  # Don't fail boot if not present (e.g., manually created VMs)
      ];
    };

    # ===== Host scaling config mount =====
    # Shares ~/.config/hydrix/ from host for dynamic DPI scaling
    # VM reads scaling.json to use same font sizes as host
    fileSystems."/mnt/hydrix-config" = {
      device = "hydrix-config";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "ro"
        "nofail"
      ];
    };

    # ===== Host persist directory mount =====
    # Shares ~/persist/<vmType>/ from host for vm-dev/vm-sync workflow
    # Enables bidirectional file sharing for package development
    fileSystems."/mnt/vm-persist" = {
      device = "vm-persist";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "rw"
        "nofail"
      ];
    };

    networking.useDHCP = lib.mkDefault true;
    # Disable NetworkManager - VMs just need simple DHCP, not full network management
    # This overrides the setting from networking.nix which enables NetworkManager
    networking.networkmanager.enable = lib.mkForce false;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== Hostname from instance config =====
    networking.hostName = lib.mkForce vmHostname;

    # ===== Locale settings from hydrix.locale options =====
    time.timeZone = lib.mkDefault cfg.locale.timezone;
    i18n.defaultLocale = lib.mkDefault cfg.locale.language;
    console.keyMap = lib.mkDefault cfg.locale.consoleKeymap;
    services.xserver.xkb.layout = lib.mkDefault cfg.locale.xkbLayout;
    services.xserver.xkb.variant = lib.mkDefault cfg.locale.xkbVariant;

    # ===== Enable virtiofs shared /nix/store =====
    hydrix.vm.sharedStore.enable = lib.mkDefault true;

    # ===== Dynamic scaling for VMs =====
    # Handled by vm-scaling.nix which provides wrapper scripts
    # that read from /mnt/hydrix-config/scaling.json (shared from host)

    # ===== Rebuild script =====
    # Parameterized based on hydrix.vm.rebuildTarget
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "rebuild" ''
        #!/usr/bin/env bash
        set -e
        cd ~/hydrix-config
        echo "Rebuilding ${vmHostname}..."
        echo "Using flake target: ${rebuildTarget}"
        # using nh for better output visualization
        # --hostname forces the specific config (e.g. vm-pentest) instead of hostname (pentest-vm)
        nh os switch . --hostname ${rebuildTarget} -- --impure
      '')

      # ===== vm-sync: Stage packages for host =====
      (pkgs.writeShellScriptBin "vm-sync" ''
        #!/usr/bin/env bash
        set -e

        VM_TYPE="${config.hydrix.vmType}"
        STAGING_DIR="$HOME/persist/staging"
        PACKAGES_DIR="$HOME/persist/dev/packages"

        usage() {
          echo "vm-sync - Stage packages for host"
          echo ""
          echo "Commands:"
          echo "  push --name <pkg>   Stage package for host"
          echo "  push --all          Stage all packages"
          echo "  list                List local packages"
          echo ""
          echo "Workflow:"
          echo "  1. vm-dev build <github-url>"
          echo "  2. vm-dev run <pkg>"
          echo "  3. vm-sync push --name <pkg>"
          echo "  4. On host: vm-sync pull <pkg> --target $VM_TYPE"
        }

        cmd_list() {
          echo "Local packages:"
          if [ -d "$PACKAGES_DIR" ]; then
            for dir in "$PACKAGES_DIR"/*/; do
              if [ -f "''${dir}flake.nix" ]; then
                echo "  $(basename "$dir")"
              fi
            done
          else
            echo "  (none)"
          fi
        }

        # Extract derivation from flake.nix to package.nix
        extract_package() {
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"
          local staging_pkg_dir="$STAGING_DIR/packages/$pkg"

          if [ ! -f "$pkg_dir/flake.nix" ]; then
            echo "Error: Package '$pkg' not found at $pkg_dir"
            exit 1
          fi

          mkdir -p "$staging_pkg_dir"

          # Extract derivation using Python
          ${pkgs.python3}/bin/python3 << PYTHON_EOF
import re
import sys

pkg_name = "$pkg"
flake_path = "$pkg_dir/flake.nix"

with open(flake_path, 'r') as f:
    content = f.read()

# Match: packages.SYSTEM.default = <derivation>;
match = re.search(r'packages\.\\\$\{system\}\.default\s*=\s*(.+?);[\s\n]*\};[\s\n]*\}', content, re.DOTALL)

if match:
    derivation = match.group(1).strip()
    output = f'''# {pkg_name} - from VM
{{ pkgs }}:
{derivation}
'''
    with open("$staging_pkg_dir/package.nix", 'w') as f:
        f.write(output)
    print(f"Staged: {pkg_name}")
else:
    print(f"Error: Could not extract derivation from {flake_path}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
        }

        cmd_push() {
          if [ ! -d "$HOME/persist" ]; then
            echo "Error: ~/persist not mounted"
            exit 1
          fi

          local push_name=""
          local push_all=false

          while [[ \$# -gt 0 ]]; do
            case "\$1" in
              --name|-n) push_name="\$2"; shift 2 ;;
              --all|-a) push_all=true; shift ;;
              *) shift ;;
            esac
          done

          if [ -n "\$push_name" ]; then
            extract_package "\$push_name"
            echo ""
            echo "On host: vm-sync pull \$push_name --target $VM_TYPE"
            return
          fi

          if [ "\$push_all" = true ]; then
            local count=0
            for dir in "\$PACKAGES_DIR"/*/; do
              if [ -f "\''${dir}flake.nix" ]; then
                extract_package "\$(basename "\$dir")"
                ((count++)) || true
              fi
            done
            echo ""
            echo "Staged \$count packages"
            echo "On host: vm-sync list"
            return
          fi

          usage
        }

        case "''${1:-}" in
          push) shift; cmd_push "$@" ;;
          list|ls) cmd_list ;;
          *) usage ;;
        esac
      '')

      # ===== vm-dev: Manage dev environment with per-package flakes =====
      (pkgs.writeShellScriptBin "vm-dev" ''
        #!/usr/bin/env bash
        PACKAGES_DIR="$HOME/persist/dev/packages"
        LEGACY_DIR="$HOME/persist/dev"

        usage() {
          echo "vm-dev - Manage persistent dev environment"
          echo ""
          echo "Commands:"
          echo "  build <url> [name] Build package from GitHub URL"
          echo "  run <pkg> [args]   Run a package"
          echo "  list               List all packages"
          echo "  remove <pkg>       Remove a package"
          echo "  install <pkg>      Install to user profile (persistent)"
          echo "  edit <pkg>         Edit package flake"
          echo "  update [pkg]       Update flake.lock (all if no pkg)"
          echo ""
          echo "Workflow:"
          echo "  vm-dev build https://github.com/owner/repo"
          echo "  vm-dev run repo"
          echo "  vm-sync push --name repo"
          echo ""
          echo "Directories:"
          echo "  $PACKAGES_DIR/<pkg>/  - Per-package flakes"
        }

        cmd_run() {
          [ $# -eq 0 ] && { echo "Usage: vm-dev run <pkg> [args]"; exit 1; }
          local pkg="$1"
          shift

          if [ -f "$PACKAGES_DIR/$pkg/flake.nix" ]; then
            cd "$PACKAGES_DIR/$pkg"
            exec nix run ".#default" -- "$@"
          fi

          if [ -f "$LEGACY_DIR/flake.nix" ]; then
            cd "$LEGACY_DIR"
            exec nix run ".#$pkg" -- "$@"
          fi

          echo "Error: Package '$pkg' not found"
          cmd_list
          exit 1
        }

        cmd_list() {
          echo "Per-package flakes ($PACKAGES_DIR):"
          if [ -d "$PACKAGES_DIR" ]; then
            for dir in "$PACKAGES_DIR"/*/; do
              if [ -f "''${dir}flake.nix" ]; then
                echo "  $(basename "$dir")"
              fi
            done
          else
            echo "  (none)"
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
            echo "Updating all packages..."
            if [ -d "$PACKAGES_DIR" ]; then
              for dir in "$PACKAGES_DIR"/*/; do
                if [ -f "''${dir}flake.nix" ]; then
                  echo "Updating $(basename "$dir")..."
                  (cd "$dir" && nix flake update) || true
                fi
              done
            fi
            echo "Done"
          fi
        }

        cmd_build() {
          exec vm-dev-add-github "$@"
        }

        case "''${1:-}" in
          build) shift; cmd_build "$@" ;;
          run) shift; cmd_run "$@" ;;
          list|ls) cmd_list ;;
          remove|rm) shift; cmd_remove "$@" ;;
          install) shift; cmd_install "$@" ;;
          edit) shift; cmd_edit "$@" ;;
          update) shift; cmd_update "$@" ;;
          *) usage ;;
        esac
      '')

      # ===== vm-dev-add-github: Create per-package flake from GitHub URL =====
      (pkgs.writeShellScriptBin "vm-dev-add-github" ''
        #!/usr/bin/env bash
        set -e

        PACKAGES_DIR="$HOME/persist/dev/packages"

        usage() {
          echo "vm-dev build - Create per-package flake from GitHub URL"
          echo ""
          echo "Usage: vm-dev build <github-url> [name]"
          echo ""
          echo "Examples:"
          echo "  vm-dev build https://github.com/buildoak/tortuise"
          echo "  vm-dev build https://github.com/zellij-org/zellij myzel"
        }

        if [ -z "$1" ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
          usage
          exit 0
        fi

        URL="$1"

        if [[ "$URL" =~ github\.com/([^/]+)/([^/]+) ]]; then
          OWNER="''${BASH_REMATCH[1]}"
          REPO="''${BASH_REMATCH[2]%.git}"
        else
          echo "Error: Not a valid GitHub URL"
          exit 1
        fi

        NAME="''${2:-$REPO}"
        PKG_DIR="$PACKAGES_DIR/$NAME"

        if [ -f "$PKG_DIR/flake.nix" ]; then
          echo "Package '$NAME' already exists"
          exit 1
        fi

        echo "Adding $OWNER/$REPO as '$NAME'..."

        BRANCH="main"
        ARCHIVE_URL="https://github.com/$OWNER/$REPO/archive/main.tar.gz"
        HASH_NIX32=$(${pkgs.nix}/bin/nix-prefetch-url --unpack "$ARCHIVE_URL" 2>/dev/null | tail -1)

        if [ -z "$HASH_NIX32" ]; then
          BRANCH="master"
          ARCHIVE_URL="https://github.com/$OWNER/$REPO/archive/master.tar.gz"
          HASH_NIX32=$(${pkgs.nix}/bin/nix-prefetch-url --unpack "$ARCHIVE_URL" 2>/dev/null | tail -1)
        fi

        if [ -z "$HASH_NIX32" ]; then
          echo "Error: Could not fetch repository"
          exit 1
        fi

        HASH_SRI=$(${pkgs.nix}/bin/nix hash convert --hash-algo sha256 --to sri "$HASH_NIX32" 2>/dev/null || \
                   ${pkgs.nix}/bin/nix hash to-sri --type sha256 "$HASH_NIX32" 2>/dev/null)

        # Detect project type
        TEMP_DIR=$(mktemp -d)
        curl -sL "$ARCHIVE_URL" | tar -xz -C "$TEMP_DIR" --strip-components=1 2>/dev/null || true

        PROJECT_TYPE="unknown"
        if [ -f "$TEMP_DIR/Cargo.toml" ]; then
          PROJECT_TYPE="rust"
        elif [ -f "$TEMP_DIR/go.mod" ]; then
          PROJECT_TYPE="go"
        elif [ -f "$TEMP_DIR/pyproject.toml" ]; then
          PROJECT_TYPE="python"
        elif [ -f "$TEMP_DIR/setup.py" ]; then
          PROJECT_TYPE="python"
        fi
        rm -rf "$TEMP_DIR"

        echo "Detected: $PROJECT_TYPE"

        mkdir -p "$PKG_DIR"

        case "$PROJECT_TYPE" in
          rust)
            cat > "$PKG_DIR/flake.nix" << FLAKE_EOF
{
  description = "$NAME - tested in VM";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.\''${system};
    in {
      packages.\''${system}.default = pkgs.rustPlatform.buildRustPackage {
        pname = "$NAME";
        version = "unstable";
        src = pkgs.fetchFromGitHub {
          owner = "$OWNER";
          repo = "$REPO";
          rev = "$BRANCH";
          hash = "$HASH_SRI";
        };
        cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
    };
}
FLAKE_EOF
            ;;
          go)
            cat > "$PKG_DIR/flake.nix" << FLAKE_EOF
{
  description = "$NAME - tested in VM";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.\''${system};
    in {
      packages.\''${system}.default = pkgs.buildGoModule {
        pname = "$NAME";
        version = "unstable";
        src = pkgs.fetchFromGitHub {
          owner = "$OWNER";
          repo = "$REPO";
          rev = "$BRANCH";
          hash = "$HASH_SRI";
        };
        vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
    };
}
FLAKE_EOF
            ;;
          python)
            cat > "$PKG_DIR/flake.nix" << FLAKE_EOF
{
  description = "$NAME - tested in VM";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.\''${system};
    in {
      packages.\''${system}.default = pkgs.python3Packages.buildPythonApplication {
        pname = "$NAME";
        version = "unstable";
        src = pkgs.fetchFromGitHub {
          owner = "$OWNER";
          repo = "$REPO";
          rev = "$BRANCH";
          hash = "$HASH_SRI";
        };
        pyproject = true;
        build-system = with pkgs.python3Packages; [ setuptools ];
      };
    };
}
FLAKE_EOF
            ;;
          *)
            cat > "$PKG_DIR/flake.nix" << FLAKE_EOF
{
  description = "$NAME - tested in VM";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.\''${system};
    in {
      packages.\''${system}.default = pkgs.stdenv.mkDerivation {
        pname = "$NAME";
        version = "unstable";
        src = pkgs.fetchFromGitHub {
          owner = "$OWNER";
          repo = "$REPO";
          rev = "$BRANCH";
          hash = "$HASH_SRI";
        };
        installPhase = "mkdir -p \\\$out";
      };
    };
}
FLAKE_EOF
            ;;
        esac

        cd "$PKG_DIR" && ${pkgs.nix}/bin/nix flake update 2>/dev/null || true

        echo ""
        echo "Created: $PKG_DIR/flake.nix"
        echo "Test with: vm-dev run $NAME"
        echo "Stage for host: vm-sync push --name $NAME"
      '')
    ];

    # ===== Profile writeback symlink =====
    # Create ~/hydrix-config/profiles symlink to the 9p mount
    # This allows direct editing of profiles that syncs to host
    systemd.services.hydrix-profiles-link = {
      description = "Create hydrix-config profiles symlink";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-hydrix\\x2dprofiles.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        # Get username from config
        USER_HOME="/home/${config.hydrix.username}"

        # Skip if mount doesn't exist (manually created VMs without writeback)
        if ! mountpoint -q /mnt/hydrix-profiles 2>/dev/null; then
          echo "Profiles mount not present, skipping symlink"
          exit 0
        fi

        echo "Mount found at /mnt/hydrix-profiles"

        # Create hydrix-config directory structure
        mkdir -p "$USER_HOME/hydrix-config"

        # Create or update symlink
        if [ -L "$USER_HOME/hydrix-config/profiles" ]; then
          # Already a symlink, verify it points to the right place
          if [ "$(readlink "$USER_HOME/hydrix-config/profiles")" != "/mnt/hydrix-profiles" ]; then
            rm "$USER_HOME/hydrix-config/profiles"
            ln -s /mnt/hydrix-profiles "$USER_HOME/hydrix-config/profiles"
          fi
          echo "Symlink already correct"
        elif [ -d "$USER_HOME/hydrix-config/profiles" ]; then
          # Directory exists (maybe from baked config), replace with symlink
          echo "Replacing directory with symlink"
          rm -rf "$USER_HOME/hydrix-config/profiles"
          ln -s /mnt/hydrix-profiles "$USER_HOME/hydrix-config/profiles"
        else
          # Nothing there, create symlink
          echo "Creating new symlink"
          ln -s /mnt/hydrix-profiles "$USER_HOME/hydrix-config/profiles"
        fi

        # Fix ownership
        chown -h ${config.hydrix.username}:users "$USER_HOME/hydrix-config"
        chown -h ${config.hydrix.username}:users "$USER_HOME/hydrix-config/profiles"

        echo "Profiles symlink created: $USER_HOME/hydrix-config/profiles -> /mnt/hydrix-profiles"
      '';
    };

    # ===== Scaling config symlink =====
    # Create ~/.config/hydrix symlink to /mnt/hydrix-config
    # This allows apps to find scaling.json at the expected path
    systemd.services.hydrix-config-link = {
      description = "Create Hydrix config symlink for dynamic scaling";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-hydrix\\x2dconfig.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        USER_HOME="/home/${config.hydrix.username}"
        CONFIG_DIR="$USER_HOME/.config/hydrix"

        # Skip if mount doesn't exist
        if ! mountpoint -q /mnt/hydrix-config 2>/dev/null; then
          echo "Hydrix config mount not present, skipping"
          exit 0
        fi

        # Create .config directory if needed
        mkdir -p "$USER_HOME/.config"
        chown ${config.hydrix.username}:users "$USER_HOME/.config"

        # Create or update symlink
        if [ -L "$CONFIG_DIR" ]; then
          current=$(readlink "$CONFIG_DIR")
          if [ "$current" != "/mnt/hydrix-config" ]; then
            rm "$CONFIG_DIR"
            ln -s /mnt/hydrix-config "$CONFIG_DIR"
          fi
        elif [ -d "$CONFIG_DIR" ]; then
          # Directory exists, move aside and symlink
          mv "$CONFIG_DIR" "$CONFIG_DIR.bak"
          ln -s /mnt/hydrix-config "$CONFIG_DIR"
        else
          ln -s /mnt/hydrix-config "$CONFIG_DIR"
        fi

        chown -h ${config.hydrix.username}:users "$CONFIG_DIR"
        echo "Config symlink created: $CONFIG_DIR -> /mnt/hydrix-config"
      '';
    };

    # ===== Persist directory symlink =====
    # Create ~/persist symlink to /mnt/vm-persist
    # This enables vm-dev/vm-sync workflow (same as microVMs)
    systemd.services.hydrix-persist-link = {
      description = "Create Hydrix persist symlink for vm-dev workflow";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-vm\\x2dpersist.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        USER_HOME="/home/${config.hydrix.username}"
        PERSIST_LINK="$USER_HOME/persist"

        # Skip if mount doesn't exist
        if ! mountpoint -q /mnt/vm-persist 2>/dev/null; then
          echo "Persist mount not present, skipping symlink"
          exit 0
        fi

        # Create or update symlink
        if [ -L "$PERSIST_LINK" ]; then
          current=$(readlink "$PERSIST_LINK")
          if [ "$current" != "/mnt/vm-persist" ]; then
            rm "$PERSIST_LINK"
            ln -s /mnt/vm-persist "$PERSIST_LINK"
          fi
        elif [ -d "$PERSIST_LINK" ]; then
          mv "$PERSIST_LINK" "$PERSIST_LINK.bak"
          ln -s /mnt/vm-persist "$PERSIST_LINK"
        else
          ln -s /mnt/vm-persist "$PERSIST_LINK"
        fi

        chown -h ${config.hydrix.username}:users "$PERSIST_LINK"
        echo "Persist symlink created: $PERSIST_LINK -> /mnt/vm-persist"
      '';
    };
  };
}
