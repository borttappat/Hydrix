# MicroVM Base Module - Shared configuration for all Hydrix microVMs
#
# This module provides the common foundation for microVM-based VMs:
# - QEMU hypervisor with vsock support
# - virtiofs for shared /nix/store
# - 9p shares for config and persistence (vm-config, hydrix-config, vm-persist)
# - TAP networking for bridge attachment
# - Xpra for seamless app forwarding to host
# - Full graphical stack (Stylix theming, HM programs, fonts, colors)
#
# The graphical modules handle VM vs host differences internally via isVM checks
# (picom disabled, mod key adjusted, xsession adapted for VMs).
# Graphical is enabled by default (opt-out with hydrix.graphical.enable = false).
#
{ config, lib, pkgs, modulesPath, ... }:

let
  # Access locale settings from central options
  locale = config.hydrix.locale;
  vmName = config.networking.hostName;

in {
  imports = [
    # Central options for locale settings
    ../options.nix
    # Base system modules (shared with regular VMs)
    ../base/nixos-base.nix
    ../base/users-vm.nix
    ../base/networking.nix

    # Core system (X11, fish shell, essential packages)
    ../core.nix

    # Graphical stack (Stylix theming, HM programs, fonts, colors)
    # Sub-modules handle VM differences internally (isVM checks)
    # Also provides VM color sync scripts (wal-sync, refresh-colors, set-colorscheme-mode)
    ../graphical

    # VM scaling wrappers (alacritty, firefox, rofi, obsidian)
    # Reads scaling.json from host for consistent font sizes
    ../vm/vm-scaling.nix

    # Xpra guest for seamless app forwarding (unified module for all VMs)
    ../vm/xpra-shared.nix

    # vm-dev, vm-sync scripts (shared with libvirt VMs)
    ../vm/vm-dev.nix

    # Auto-import packages from profiles/<vmType>/packages/
    ../packages/auto-include.nix
  ];

  options.hydrix.microvm = {
    vcpu = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Number of virtual CPUs";
    };

    mem = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "Memory in MB (balloon reclaims idle memory from guest)";
    };

    vsockCid = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Unique vsock CID for this VM (must be unique per VM, >2)";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "br-browse";
      description = "Network bridge to attach TAP interface to";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/${config.networking.hostName}/config";
      description = "Host path for VM config (read-only 9p mount)";
    };

    tapId = lib.mkOption {
      type = lib.types.str;
      default = "mv-${lib.substring 0 10 config.networking.hostName}";
      description = "TAP interface ID (max 15 chars on Linux)";
    };

    shareStore = lib.mkOption {
      type = lib.types.bool;
      default = true;  # Share host /nix/store for instant startup (no squashfs build)
      description = "Share host /nix/store via virtiofs (faster rebuilds, instant startup)";
    };

    persistence = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable persistent home directory via qcow2 volume";
      };

      homeSize = lib.mkOption {
        type = lib.types.int;
        default = 10240;
        description = "Home volume size in MB";
      };

      volumePath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microvms/${config.networking.hostName}/home.qcow2";
        description = "Path to the qcow2 volume for home persistence";
      };

      extraVolumes = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Volume name (used in path)";
            };
            size = lib.mkOption {
              type = lib.types.int;
              description = "Volume size in MB";
            };
            mountPoint = lib.mkOption {
              type = lib.types.str;
              description = "Mount point inside VM";
            };
          };
        });
        default = [];
        description = "Additional persistent volumes (e.g., docker)";
      };

      storeOverlaySize = lib.mkOption {
        type = lib.types.int;
        default = 20480;
        description = "Size in MB for persistent store overlay (for in-VM rebuilds). Thin-provisioned.";
      };

      hostPersist = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable host-mapped persist directory via 9p.
          Maps ~/persist/<vmType>/ on host to ~/persist/ in VM.
          Allows bidirectional file sharing between host and VM.
        '';
      };
    };

    # Secrets provisioning options
    secrets = {
      github = lib.mkEnableOption "Provision GitHub SSH key from host";
    };

    # Encryption options for persistent volumes
    encryption = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable LUKS encryption for persistent volumes.
          When enabled, volumes are encrypted with a password prompted at start.
          Use 'microvm create-encrypted <name>' to set up the encrypted volume.
        '';
      };

      mandatory = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Require encryption for this VM type.
          If true, the VM will refuse to start without encrypted volumes.
          Recommended for pentest VMs to protect sensitive data.
        '';
      };
    };
  };

  config = {
    # MicroVMs get full graphical theming by default (opt-out with graphical.enable = false)
    hydrix.graphical.enable = lib.mkDefault true;

    # ===== MicroVMs run headless - xpra provides its own Xvfb =====
    # Disable X server and display manager to avoid pulling in GDM/lightdm
    services.xserver.enable = lib.mkForce false;
    services.displayManager.autoLogin.enable = lib.mkForce false;

    # Software rendering (mesa/llvmpipe) for GPU-accelerated apps like alacritty
    # xpra's Xvfb doesn't provide EGL/GL, so mesa must be available
    hardware.graphics.enable = true;

    # ===== Disable host-centric graphical services for microVMs =====
    # The graphical stack is imported for theming/fonts/alacritty config, but
    # xsession, polybar, picom, splash, dunst, auto-resize are host/libvirt-VM
    # specific and waste CPU in headless xpra-forwarded microVMs.
    home-manager.users.${config.hydrix.username} = {
      xsession.enable = lib.mkForce false;
      services.dunst.enable = lib.mkForce false;
    };

    # ===== MicroVM Configuration =====
    microvm = {
      # QEMU hypervisor - most feature-complete (vsock, graphics, virtiofs)
      hypervisor = "qemu";

      # Use standard PC machine type for full PCI support
      # The default "microvm" machine type has a simplified PCI controller
      # that the kernel doesn't recognize ("No config space access function found")
      qemu.machine = "pc";

      # Use squashfs for store disk when not sharing host store
      # When shareStore is enabled, this is ignored (no store disk built)
      storeDiskType = "squashfs";

      # Enable writable store overlay for Home Manager activation
      # microvm.nix detects /nix/.ro-store share and creates the overlay automatically
      writableStoreOverlay = "/nix/.rw-store";

      # Resources (configurable via options)
      vcpu = config.hydrix.microvm.vcpu;
      mem = config.hydrix.microvm.mem;

      # ===== Memory ballooning =====
      # Allows host to reclaim unused guest memory dynamically
      balloon = true;
      deflateOnOOM = true;  # Give memory back to guest if it's running low

      # ===== Virtiofs tuning =====
      # Default spawns `nproc` threads per share — wasteful when idle
      virtiofsd.threadPoolSize = 4;

      # Disable graphics for headless operation (serial console only)
      graphics.enable = false;

      # Force headless mode - override any VGA/display settings
      qemu.extraArgs = [
        "-vga" "none"
        "-display" "none"
      ];

      # ===== Shared Filesystems =====
      shares = [
        # VM config directory (required by microvm, can be empty)
        {
          tag = "vm-config";
          source = config.hydrix.microvm.configPath;
          mountPoint = "/mnt/vm-config";
          proto = "9p";
        }
        # Host config directory (for scaling.json - dynamic DPI)
        {
          tag = "hydrix-config";
          source = "/home/${config.hydrix.username}/.config/hydrix";
          mountPoint = "/mnt/hydrix-config";
          proto = "9p";
        }
      ] ++ lib.optionals (config.hydrix.microvm.persistence.hostPersist && config.hydrix.vmType != "") [
        # Host persist directory (read-only access)
        # Maps ~/persist/<vmType>/ on host to /mnt/vm-persist in VM
        # Note: VMs now use local ~/dev/ and ~/staging/ for development
        # This share is kept for backward compatibility and read-only access
        {
          tag = "vm-persist";
          source = "/home/${config.hydrix.username}/persist/${config.hydrix.vmType}";
          mountPoint = "/mnt/vm-persist";
          proto = "9p";
        }
      ] ++ lib.optionals config.hydrix.microvm.shareStore [
        # Share host /nix/store via virtiofs (read-only base)
        # Mounted at .ro-store, then overlaid at /nix/store for writes
        {
          tag = "nix-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "virtiofs";
        }
      ] ++ lib.optionals config.hydrix.microvm.secrets.github [
        # Host secrets directory (provisioned by host-side hydrix-secrets service)
        # Contains SSH keys for GitHub authentication
        {
          tag = "vm-secrets";
          source = "/run/hydrix-secrets/${vmName}";
          mountPoint = "/mnt/vm-secrets";
          proto = "virtiofs";
          # microvm.nix manages virtiofsd; socket is placed in working dir by default
        }
      ];

      # ===== Persistent Volumes =====
      # Home directory persistence (optional)
      # Store overlay for nix builds (always when shareStore enabled)
      volumes = lib.optionals config.hydrix.microvm.persistence.enable ([
        {
          image = config.hydrix.microvm.persistence.volumePath;
          mountPoint = "/home";
          size = config.hydrix.microvm.persistence.homeSize;
          autoCreate = true;
        }
      ] ++ map (vol: {
        image = "/var/lib/microvms/${config.networking.hostName}/${vol.name}.qcow2";
        mountPoint = vol.mountPoint;
        size = vol.size;
        autoCreate = true;
      }) config.hydrix.microvm.persistence.extraVolumes)
      # Persistent store overlay for nix builds (thin-provisioned, starts near 0)
      ++ lib.optionals config.hydrix.microvm.shareStore [{
        image = "/var/lib/microvms/${config.networking.hostName}/nix-overlay.qcow2";
        mountPoint = "/nix/.rw-store";
        size = config.hydrix.microvm.persistence.storeOverlaySize;
        autoCreate = true;
      }];

      # ===== Network Interface =====
      # TAP interface for bridge attachment (max 15 chars on Linux)
      interfaces = [{
        type = "tap";
        id = config.hydrix.microvm.tapId;
        # MAC generated from hostname for consistency
        mac = "02:00:00:00:00:${lib.substring 0 2 (builtins.hashString "md5" vmName)}";
      }];

      # ===== Vsock for xpra =====
      vsock = {
        cid = config.hydrix.microvm.vsockCid;
      };

      # ===== Kernel =====
      # Use the default kernel (from boot.kernelPackages)
      # Don't override - let it match the initrd modules
    };

    # ===== Disable auto-optimise-store for microVMs =====
    # Incompatible with writableStoreOverlay (required for Home Manager activation)
    nix.settings.auto-optimise-store = lib.mkForce false;

    # ===== System switching =====
    # Keep system.switch.enable for potential future use
    microvm.optimize.enable = false;
    system.switch.enable = true;

    # ===== Disable heavy/host-only services =====
    # These services are either wasteful in VMs or host-specific
    services.ollama.enable = lib.mkForce false;      # LLM service - 500MB-8GB RAM, useless in VMs
    services.auto-cpufreq.enable = lib.mkForce false; # CPU freq scaling - useless in QEMU
    services.rsyncd.enable = lib.mkForce false;       # rsync daemon - not needed in VMs
    services.tailscale.enable = lib.mkForce false;    # VPN - host-only

    # ===== MicroVMs run headless =====
    # GUI apps are forwarded to host via xpra (port 14500)
    # No local graphical environment needed

    # ===== VM Metrics Server for Host Polybar =====
    # Simple vsock server that responds to metric queries from host
    # Host queries via: echo "cpu" | socat - VSOCK-CONNECT:CID:14501
    systemd.services.vm-metrics = {
      description = "VM metrics server for host polybar";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          metricsScript = pkgs.writeShellScript "vm-metrics-server" ''
            # Simple metrics server - responds to queries via vsock
            while true; do
              ${pkgs.socat}/bin/socat VSOCK-LISTEN:14501,reuseaddr,fork EXEC:"${metricsHandler}"
            done
          '';
          metricsHandler = pkgs.writeShellScript "vm-metrics-handler" ''
            read -r cmd
            case "$cmd" in
              cpu)
                ${pkgs.gawk}/bin/awk '/^cpu / {usage=100-($5*100/($2+$3+$4+$5+$6+$7+$8))} END {printf "%.0f", usage}' /proc/stat
                ;;
              ram)
                ${pkgs.procps}/bin/free | ${pkgs.gawk}/bin/awk '/Mem:/ { printf "%.0f", $3/$2 * 100 }'
                ;;
              fs)
                ${pkgs.coreutils}/bin/df /home 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2 { gsub(/%/,""); print $5 }' || \
                ${pkgs.coreutils}/bin/df / | ${pkgs.gawk}/bin/awk 'NR==2 { gsub(/%/,""); print $5 }'
                ;;
              uptime)
                uptime_sec=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.gawk}/bin/awk '{print int($1)}')
                hours=$((uptime_sec / 3600))
                mins=$(((uptime_sec % 3600) / 60))
                if [ "$hours" -ge 24 ]; then
                  days=$((hours / 24))
                  hours=$((hours % 24))
                  printf "%dD %dH" "$days" "$hours"
                else
                  printf "%dH %dM" "$hours" "$mins"
                fi
                ;;
              top)
                ${pkgs.procps}/bin/ps aux --sort=-%cpu 2>/dev/null | \
                  ${pkgs.gawk}/bin/awk 'NR==2 {name=$11; gsub(".*/","",name); printf "%s %.0f", substr(name,1,10), $3}'
                ;;
              topmem)
                ${pkgs.procps}/bin/ps aux --sort=-%mem 2>/dev/null | \
                  ${pkgs.gawk}/bin/awk 'NR==2 {name=$11; gsub(".*/","",name); printf "%s %.0f", substr(name,1,10), $6/1024}'
                ;;
              sync)
                # Updated to use new local directories
                dev=0
                stg=0
                USER_HOME="/home/${config.hydrix.username}"
                if [ -d "$USER_HOME/dev/packages" ]; then
                  dev=$(${pkgs.findutils}/bin/find "$USER_HOME/dev/packages" -maxdepth 2 -name "flake.nix" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
                fi
                if [ -d "$USER_HOME/staging" ]; then
                  stg=$(${pkgs.findutils}/bin/find "$USER_HOME/staging" -maxdepth 2 -name "package.nix" 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
                fi
                echo "$dev $stg"
                ;;
              tun)
                iface=$(${pkgs.iproute2}/bin/ip link show 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oE '(tun|wg|tap)[0-9]+' | head -1)
                if [ -n "$iface" ]; then
                  echo "$iface"
                else
                  echo "none"
                fi
                ;;
              *)
                echo "unknown"
                ;;
            esac
          '';
        in metricsScript;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== VM Staging Server for Host Package Sync =====
    # Vsock server that allows host to query and pull staged packages
    # Host queries via: echo "list" | socat - VSOCK-CONNECT:CID:14502
    # Host pulls via:   echo "get <pkg>" | socat - VSOCK-CONNECT:CID:14502 | tar xf -
    systemd.services.vm-staging = {
      description = "VM staging server for host package sync";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          stagingScript = pkgs.writeShellScript "vm-staging-server" ''
            # Staging server - allows host to query and pull staged packages
            while true; do
              ${pkgs.socat}/bin/socat VSOCK-LISTEN:14502,reuseaddr,fork EXEC:"${stagingHandler}"
            done
          '';
          stagingHandler = pkgs.writeShellScript "vm-staging-handler" ''
            USER_HOME="/home/${config.hydrix.username}"
            STAGING_DIR="$USER_HOME/staging"
            DEV_DIR="$USER_HOME/dev/packages"
            VM_NAME="${vmName}"
            VM_TYPE="${config.hydrix.vmType}"

            read -r cmd arg

            case "$cmd" in
              list)
                # Return JSON with staged packages
                packages=""
                if [ -d "$STAGING_DIR" ]; then
                  for dir in "$STAGING_DIR"/*/; do
                    [ -d "$dir" ] || continue
                    if [ -f "''${dir}package.nix" ]; then
                      name=$(basename "$dir")
                      [ -n "$packages" ] && packages="$packages,"
                      packages="$packages\"$name\""
                    fi
                  done
                fi
                echo "{\"packages\":[$packages],\"vm\":\"$VM_NAME\",\"type\":\"$VM_TYPE\"}"
                ;;
              get)
                # Return tar stream of staged package
                pkg="$arg"
                pkg_dir="$STAGING_DIR/$pkg"
                if [ -d "$pkg_dir" ] && [ -f "$pkg_dir/package.nix" ]; then
                  # Use tar to stream the package directory
                  cd "$STAGING_DIR" && ${pkgs.gnutar}/bin/tar cf - "$pkg"
                else
                  echo "ERROR: Package '$pkg' not found" >&2
                  exit 1
                fi
                ;;
              info)
                # Return info about a specific package
                pkg="$arg"
                pkg_dir="$STAGING_DIR/$pkg"
                if [ -d "$pkg_dir" ] && [ -f "$pkg_dir/package.nix" ]; then
                  size=$(${pkgs.coreutils}/bin/du -sb "$pkg_dir" | ${pkgs.gawk}/bin/awk '{print $1}')
                  echo "{\"name\":\"$pkg\",\"size\":$size,\"vm\":\"$VM_NAME\",\"type\":\"$VM_TYPE\"}"
                else
                  echo "{\"error\":\"not found\"}"
                fi
                ;;
              dev)
                # Return JSON with dev packages (not yet staged)
                packages=""
                if [ -d "$DEV_DIR" ]; then
                  for dir in "$DEV_DIR"/*/; do
                    [ -d "$dir" ] || continue
                    if [ -f "''${dir}flake.nix" ]; then
                      name=$(basename "$dir")
                      # Check if staged
                      staged="false"
                      [ -f "$STAGING_DIR/$name/package.nix" ] && staged="true"
                      [ -n "$packages" ] && packages="$packages,"
                      packages="$packages{\"name\":\"$name\",\"staged\":$staged}"
                    fi
                  done
                fi
                echo "{\"packages\":[$packages],\"vm\":\"$VM_NAME\",\"type\":\"$VM_TYPE\"}"
                ;;
              *)
                echo "{\"error\":\"unknown command\",\"commands\":[\"list\",\"get <pkg>\",\"info <pkg>\",\"dev\"]}"
                ;;
            esac
          '';
        in stagingScript;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== VM Live Switch Server =====
    # Vsock server that handles live configuration switches without reboot
    # Host signals via: echo "SWITCH /nix/store/..." | socat - VSOCK-CONNECT:CID:14504
    # This allows updating the running VM to a new NixOS configuration
    systemd.services.vm-switch = {
      description = "Live NixOS switch via vsock";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # CRITICAL: Don't restart this service during switch-to-configuration
      # Otherwise it kills itself while handling the switch command
      restartIfChanged = false;

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          switchScript = pkgs.writeShellScript "vm-switch-server" ''
            # Live switch server - receives switch commands from host via vsock
            while true; do
              ${pkgs.socat}/bin/socat VSOCK-LISTEN:14504,reuseaddr,fork EXEC:"${switchHandler}",nofork
            done
          '';
          switchHandler = pkgs.writeShellScript "vm-switch-handler" ''
            read -r cmd path

            case "$cmd" in
              SWITCH)
                if [[ ! -d "$path" ]]; then
                  echo "ERROR: path does not exist: $path"
                  exit 1
                fi

                # Verify it's a valid NixOS system
                if [[ ! -x "$path/bin/switch-to-configuration" ]]; then
                  echo "ERROR: not a valid NixOS system: $path"
                  exit 1
                fi

                # Get current for comparison
                current=$(readlink /run/current-system)

                if [[ "$current" == "$path" ]]; then
                  echo "OK: already running this configuration"
                  exit 0
                fi

                # Update profile symlink DIRECTLY (bypass nix-env to avoid Nix DB issues)
                # This is what nix-env --set does, but without DB registration
                ln -sfn "$path" /nix/var/nix/profiles/system

                # Register host-built store paths in VM's nix DB.
                # Paths exist in /nix/store via virtiofs but the VM's local DB
                # doesn't know about them, causing home-manager activation to fail.
                # The host dumps registration info to the config share before switching.
                if [[ -f /mnt/vm-config/.switch-reg ]]; then
                  ${pkgs.nix}/bin/nix-store --load-db < /mnt/vm-config/.switch-reg 2>/dev/null || true
                  rm -f /mnt/vm-config/.switch-reg
                fi

                # Run the switch (home-manager activation works with registered paths)
                output=$("$path/bin/switch-to-configuration" switch 2>&1)
                exit_code=$?

                # Exit codes: 0=success, 1=hard failure, other=partial (some units failed)
                if [[ $exit_code -eq 0 ]]; then
                  echo "OK: switched to $path"
                elif [[ $exit_code -eq 1 ]]; then
                  echo "ERROR: switch failed"
                  echo "$output"
                else
                  # Partial success - switch completed but some units failed
                  echo "OK: switched to $path (some units failed, exit $exit_code)"
                  echo "$output"
                fi
                ;;

              TEST)
                # Test mode - shows what would change without applying
                if [[ ! -d "$path" ]]; then
                  echo "ERROR: path does not exist: $path"
                  exit 1
                fi
                if [[ ! -x "$path/bin/switch-to-configuration" ]]; then
                  echo "ERROR: not a valid NixOS system: $path"
                  exit 1
                fi
                "$path/bin/switch-to-configuration" test 2>&1
                ;;

              STATUS)
                current=$(readlink /run/current-system)
                booted=$(readlink /run/booted-system 2>/dev/null || echo "unknown")
                profile=$(readlink /nix/var/nix/profiles/system 2>/dev/null || echo "none")
                echo "CURRENT $current"
                echo "BOOTED $booted"
                echo "PROFILE $profile"
                ;;

              PING)
                echo "PONG"
                ;;

              *)
                echo "ERROR: unknown command: $cmd"
                echo "Commands: SWITCH <path>, TEST <path>, STATUS, PING"
                ;;
            esac
          '';
        in switchScript;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== VM Background Color Server =====
    # Receives host background hex via vsock. Generates a full alacritty TOML
    # (host bg + VM text colors from /etc/hydrix-colorscheme.json) to the single
    # import file colors-runtime.toml. Same format as write-alacritty-colors.
    systemd.services.vm-colorscheme = {
      description = "VM background color server (vsock)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          server = pkgs.writeShellScript "vm-bg-server" ''
            while true; do
              ${pkgs.socat}/bin/socat VSOCK-LISTEN:14503,reuseaddr,fork EXEC:"${handler}",nofork
            done
          '';
          handler = pkgs.writeShellScript "vm-bg-handler" ''
            USERNAME="${config.hydrix.username}"
            RUNTIME_TOML="/home/$USERNAME/.config/alacritty/colors-runtime.toml"
            VM_COLORS="/etc/hydrix-colorscheme.json"

            BG_HEX=$(${pkgs.coreutils}/bin/cat | ${pkgs.coreutils}/bin/tr -d '\n\r ')

            if ! echo "$BG_HEX" | ${pkgs.gnugrep}/bin/grep -qE '^#[0-9a-fA-F]{6}$'; then
              echo "ERROR: expected #RRGGBB, got: $BG_HEX"
              exit 1
            fi

            if [ ! -f "$VM_COLORS" ]; then
              echo "ERROR: no $VM_COLORS"
              exit 1
            fi

            # Generate full TOML: host background + VM text colors
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$RUNTIME_TOML")"
            ${pkgs.jq}/bin/jq -r --arg bg "$BG_HEX" '
              "[colors.primary]\n" +
              "background = \"" + $bg + "\"\n" +
              "foreground = \"" + (.special.foreground // .colors.color7) + "\"\n\n" +
              "[colors.normal]\n" +
              "black = \"" + .colors.color0 + "\"\n" +
              "red = \"" + .colors.color1 + "\"\n" +
              "green = \"" + .colors.color2 + "\"\n" +
              "yellow = \"" + .colors.color3 + "\"\n" +
              "blue = \"" + .colors.color4 + "\"\n" +
              "magenta = \"" + .colors.color5 + "\"\n" +
              "cyan = \"" + .colors.color6 + "\"\n" +
              "white = \"" + .colors.color7 + "\"\n\n" +
              "[colors.bright]\n" +
              "black = \"" + .colors.color8 + "\"\n" +
              "red = \"" + (.colors.color9 // .colors.color1) + "\"\n" +
              "green = \"" + (.colors.color10 // .colors.color2) + "\"\n" +
              "yellow = \"" + (.colors.color11 // .colors.color3) + "\"\n" +
              "blue = \"" + (.colors.color12 // .colors.color4) + "\"\n" +
              "magenta = \"" + (.colors.color13 // .colors.color5) + "\"\n" +
              "cyan = \"" + (.colors.color14 // .colors.color6) + "\"\n" +
              "white = \"" + (.colors.color15 // .colors.color7) + "\""
            ' "$VM_COLORS" > "$RUNTIME_TOML.tmp"
            ${pkgs.coreutils}/bin/mv "$RUNTIME_TOML.tmp" "$RUNTIME_TOML"
            ${pkgs.coreutils}/bin/chown $USERNAME:users "$RUNTIME_TOML"

            # Signal running alacritty instances to reload
            ${pkgs.procps}/bin/pkill -USR1 alacritty 2>/dev/null || true

            # Refresh colors for other apps (i3, polybar, dunst, etc.)
            # The virtiofs wal cache at /mnt/wal-cache has the host's live colors.
            # refresh-colors reads from ~/.cache/wal (symlinked to /mnt/wal-cache
            # by vmThemeSync) and reloads all color-aware apps.
            REFRESH="/run/current-system/sw/bin/refresh-colors"
            if [ -x "$REFRESH" ]; then
              UID_NUM=$(${pkgs.coreutils}/bin/id -u "$USERNAME" 2>/dev/null || echo 1000)
              ${pkgs.sudo}/bin/sudo -u "$USERNAME" \
                HOME="/home/$USERNAME" \
                DISPLAY=:100 \
                XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
                "$REFRESH" 2>/dev/null &
            fi

            echo "OK: bg=$BG_HEX"
          '';
        in server;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== Entropy generation =====
    services.haveged.enable = true;

    # ===== Kernel modules =====
    # Force virtio modules into initrd (required for store disk)
    boot.initrd.kernelModules = [
      "virtio_blk"
      "virtio_pci"
      "virtio_scsi" # Added for SCSI controller support on q35
      "virtio_mmio"
      "squashfs"
    ];
    # Also load in real system for udev detection after switch-root
    boot.kernelModules = [
      "virtio_blk"
      "virtio_pci"
      "virtio_rng"
      "vmw_vsock_virtio_transport"  # vsock for xpra
    ];

    # Entropy settings
    boot.kernelParams = [
      "random.trust_cpu=on"
      "rng_core.default_quality=1000"
    ];

    # ===== Networking =====
    networking.useDHCP = lib.mkDefault true;
    networking.networkmanager.enable = lib.mkForce false;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== Nix Store Overlay (for shareStore) =====
    # When shareStore is enabled, virtiofs mounts at /nix/.ro-store
    # microvm.nix detects this and automatically creates an overlay at /nix/store
    # using writableStoreOverlay for the upper layer. No manual config needed.

    # ===== Locale settings from shared config =====
    time.timeZone = locale.timezone;
    i18n.defaultLocale = locale.language;
    console.keyMap = locale.consoleKeymap;
    services.xserver.xkb.layout = locale.xkbLayout;
    services.xserver.xkb.variant = locale.xkbVariant;

    # ===== Host store as binary cache =====
    # Disabled for initial testing - VM uses its own /nix/store from closure
    # TODO: Re-enable once 9p/virtiofs sharing is working
    # systemd.services.host-store-cache = { ... };

    # vm-dev, vm-sync, vm-dev-add-github, mvm-sync provided by ../vm/vm-dev.nix

    # ===== Home Manager mount dependency =====
    # When using persistent home, Home Manager must wait for /home to be mounted
    # Otherwise configs are written to tmpfs and lost when the qcow2 volume mounts
    systemd.services."home-manager-${config.hydrix.username}" = lib.mkIf config.hydrix.microvm.persistence.enable {
      after = [ "home.mount" ];
      requires = [ "home.mount" ];

      # CRITICAL: Don't restart/stop during switch-to-configuration
      # HM activation isn't idempotent - re-running on an already-activated home fails
      # The initial boot activation is sufficient; config changes don't need re-activation
      restartIfChanged = false;
      stopIfChanged = false;
    };

    # ===== Scaling config symlink =====
    systemd.services.hydrix-config-link = {
      description = "Create Hydrix config symlink for dynamic scaling";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ] ++ lib.optionals config.hydrix.microvm.persistence.enable [ "home.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        USER_HOME="/home/${config.hydrix.username}"
        CONFIG_DIR="$USER_HOME/.config/hydrix"

        if ! mountpoint -q /mnt/hydrix-config 2>/dev/null; then
          echo "Hydrix config mount not present, skipping"
          exit 0
        fi

        mkdir -p "$USER_HOME/.config"
        chown ${config.hydrix.username}:users "$USER_HOME/.config"

        if [ -L "$CONFIG_DIR" ]; then
          current=$(readlink "$CONFIG_DIR")
          if [ "$current" != "/mnt/hydrix-config" ]; then
            rm "$CONFIG_DIR"
            ln -s /mnt/hydrix-config "$CONFIG_DIR"
          fi
        elif [ -d "$CONFIG_DIR" ]; then
          mv "$CONFIG_DIR" "$CONFIG_DIR.bak"
          ln -s /mnt/hydrix-config "$CONFIG_DIR"
        else
          ln -s /mnt/hydrix-config "$CONFIG_DIR"
        fi

        chown -h ${config.hydrix.username}:users "$CONFIG_DIR"
      '';
    };

    # ===== Host persist directory symlink (read-only) =====
    # Note: persist is now read-only from VM perspective
    # VMs use local ~/dev/ and ~/staging/ for development
    # persist is kept for backward compatibility and read-only access to host files
    systemd.services.hydrix-persist-link = lib.mkIf (config.hydrix.microvm.persistence.hostPersist && config.hydrix.vmType != "") {
      description = "Create Hydrix persist symlink for host-mapped storage (read-only)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ] ++ lib.optionals config.hydrix.microvm.persistence.enable [ "home.mount" ];
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
          # Backup existing directory
          mv "$PERSIST_LINK" "$PERSIST_LINK.bak"
          ln -s /mnt/vm-persist "$PERSIST_LINK"
        else
          ln -s /mnt/vm-persist "$PERSIST_LINK"
        fi

        chown -h ${config.hydrix.username}:users "$PERSIST_LINK"
      '';
    };

    # ===== Dev environment initialization =====
    # Creates ~/dev/packages/ and ~/staging/ directories with proper structure
    # Also creates legacy ~/dev/flake.nix for backward compatibility
    systemd.services.hydrix-dev-init = lib.mkIf config.hydrix.microvm.persistence.enable {
      description = "Initialize dev environment directories";
      wantedBy = [ "multi-user.target" ];
      after = [ "home.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = config.hydrix.username;
      };
      script = ''
        # Create dev and staging directories
        mkdir -p "$HOME/dev/packages"
        mkdir -p "$HOME/staging"

        # Legacy flake for backward compatibility
        DEV_DIR="$HOME/dev"

        # Only create legacy flake if not exists
        if [ ! -f "$DEV_DIR/flake.nix" ]; then
          cat > "$DEV_DIR/flake.nix" << 'EOF'
{
  description = "VM dev environment - test packages here";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.''${system};
    in {
      # Individual packages - run with: nix run .#<name>
      packages.''${system} = {
        # === ADD PACKAGES TO TEST BELOW ===
        # zellij = pkgs.zellij;
        # btop = pkgs.btop;
      };

      # Dev shell - enter with: nix develop
      devShells.''${system}.default = pkgs.mkShell {
        packages = builtins.attrValues self.packages.''${system};
        shellHook = '''
          echo "Dev environment loaded"
          echo "Packages available in this shell"
        ''';
      };
    };
}
EOF

          # Initialize lock file
          cd "$DEV_DIR" && ${pkgs.nix}/bin/nix flake update 2>/dev/null || true

          echo "Created $DEV_DIR/flake.nix"
        fi

        echo "Dev directories initialized: ~/dev/packages/ ~/staging/"
      '';
    };

    # ===== GitHub SSH key provisioning =====
    systemd.services.hydrix-secrets-provision = lib.mkIf config.hydrix.microvm.secrets.github {
      description = "Provision GitHub SSH key from host secrets";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ] ++ lib.optionals config.hydrix.microvm.persistence.enable [ "home.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils pkgs.openssh ];
      script = ''
        USER_HOME="/home/${config.hydrix.username}"
        SSH_DIR="$USER_HOME/.ssh"
        SECRETS_DIR="/mnt/vm-secrets/ssh"

        # Skip if secrets mount doesn't exist
        if [ ! -d "$SECRETS_DIR" ]; then
          echo "Secrets mount not present at $SECRETS_DIR, skipping"
          exit 0
        fi

        # Create .ssh directory with correct permissions
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chown ${config.hydrix.username}:users "$SSH_DIR"

        # Copy private key
        if [ -f "$SECRETS_DIR/id_ed25519" ]; then
          cp "$SECRETS_DIR/id_ed25519" "$SSH_DIR/id_ed25519"
          chmod 600 "$SSH_DIR/id_ed25519"
          chown ${config.hydrix.username}:users "$SSH_DIR/id_ed25519"
          echo "GitHub private key provisioned"
        else
          echo "Warning: GitHub private key not found"
        fi

        # Copy public key
        if [ -f "$SECRETS_DIR/id_ed25519.pub" ]; then
          cp "$SECRETS_DIR/id_ed25519.pub" "$SSH_DIR/id_ed25519.pub"
          chmod 644 "$SSH_DIR/id_ed25519.pub"
          chown ${config.hydrix.username}:users "$SSH_DIR/id_ed25519.pub"
          echo "GitHub public key provisioned"
        fi

        # Add github.com to known_hosts if not already present
        KNOWN_HOSTS="$SSH_DIR/known_hosts"
        if [ ! -f "$KNOWN_HOSTS" ] || ! grep -q "github.com" "$KNOWN_HOSTS" 2>/dev/null; then
          # Fetch GitHub's SSH key fingerprints
          ssh-keyscan -t ed25519,rsa github.com >> "$KNOWN_HOSTS" 2>/dev/null || true
          chmod 644 "$KNOWN_HOSTS"
          chown ${config.hydrix.username}:users "$KNOWN_HOSTS"
          echo "Added github.com to known_hosts"
        fi
      '';
    };
  };
}
