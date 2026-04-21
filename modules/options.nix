# Hydrix Options - Single Source of Truth
#
# ALL machine-specific configuration is defined here as options.
# Implementation modules read from config.hydrix.* - never import files directly.
#
# Users set these options in their machine config (e.g., machines/my-laptop.nix):
#
#   { config, ... }: {
#     hydrix = {
#       username = "traum";
#       hostname = "zen";
#       colorscheme = "nord";
#       locale.timezone = "Europe/Stockholm";
#       router.wifi.ssid = "MyNetwork";
#       hardware.vfio.wifiPciAddress = "00:14.3";
#       # ... etc
#     };
#   }
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;

  # Check if we're in a VM context
  isVM = cfg.vmType != null && cfg.vmType != "host";

  # Resolve a colorscheme name to its JSON path
  # Checks user colorschemes dir first, falls back to framework colorschemes
  frameworkColorschemesDir = ../colorschemes;
  resolveColorscheme = name: let
    userPath =
      if cfg.userColorschemesDir != null
      then cfg.userColorschemesDir + "/${name}.json"
      else null;
    frameworkPath = frameworkColorschemesDir + "/${name}.json";
  in
    if userPath != null && builtins.pathExists userPath
    then userPath
    else frameworkPath;

  colorschemeExists = name:
    builtins.pathExists (resolveColorscheme name);
in {
  options.hydrix = {
    # =========================================================================
    # IDENTITY
    # =========================================================================

    username = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Primary username for this system";
      example = "traum";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "hydrix";
      description = "System hostname";
      example = "zen";
    };

    user = {
      hashedPassword = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Hashed password for the primary user (mkpasswd -m sha-512).
          If null, user will be prompted to set password on first login.
        '';
        example = "$6$rounds=...";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = cfg.username;
        description = "User account description/full name";
      };

      sshPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "SSH public keys for authorized_keys";
        example = ["ssh-rsa AAAA... user@host"];
      };

      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional groups for the user (beyond defaults)";
        example = ["libvirtd" "kvm"];
      };

      autologin = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable automatic console login for the primary user";
      };
    };

    vmType = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "System type: host or VM profile type (e.g. browsing, pentest, dev, or any user-defined profile name)";
    };

    # =========================================================================
    # PATHS
    # =========================================================================

    paths = {
      configDir = lib.mkOption {
        type = lib.types.str;
        default = "/home/${cfg.username}/hydrix-config";
        description = ''
          Path to the user's Hydrix configuration directory.
          This is the source of truth for all machine configs, profiles, and secrets.
          All rebuilds happen from this directory.
        '';
        example = "/home/user/hydrix-config";
      };

      hydrixDir = lib.mkOption {
        type = lib.types.str;
        default = "/home/${cfg.username}/Hydrix";
        description = ''
          Path to local Hydrix framework clone (for development).
          Used as fallback when configDir doesn't exist, or for developers
          who want to modify the framework itself.
        '';
        example = "/home/user/Hydrix";
      };
    };

    colorscheme = lib.mkOption {
      type = lib.types.str;
      default = "nord";
      description = "Colorscheme name (from colorschemes/ directory)";
      example = "nvid";
    };

    userColorschemesDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to user's colorschemes directory (e.g., ./colorschemes in hydrix-config).
        User colorschemes take priority over framework-provided ones.
      '';
    };

    resolveColorscheme = lib.mkOption {
      type = lib.types.functionTo lib.types.path;
      internal = true;
      readOnly = true;
      default = resolveColorscheme;
      description = "Resolve a colorscheme name to its JSON path (user first, then framework)";
    };

    # =========================================================================
    # DEFAULT APPLICATIONS
    # =========================================================================

    terminal = lib.mkOption {
      type = lib.types.str;
      default = "alacritty";
      description = "Terminal emulator command";
      example = "kitty";
    };

    shell = lib.mkOption {
      type = lib.types.enum ["fish" "bash" "zsh"];
      default = "fish";
      description = "Default user shell";
    };

    browser = lib.mkOption {
      type = lib.types.str;
      default = "firefox";
      description = "Primary web browser";
    };

    editor = lib.mkOption {
      type = lib.types.str;
      default = "vim";
      description = "Default text editor";
    };

    fileManager = lib.mkOption {
      type = lib.types.str;
      default = "ranger";
      description = "File manager";
    };

    imageViewer = lib.mkOption {
      type = lib.types.str;
      default = "feh";
      description = "Image viewer";
    };

    mediaPlayer = lib.mkOption {
      type = lib.types.str;
      default = "mpv";
      description = "Media player";
    };

    pdfViewer = lib.mkOption {
      type = lib.types.str;
      default = "zathura";
      description = "PDF viewer";
    };

    # =========================================================================
    # LOCALE
    # =========================================================================

    locale = {
      timezone = lib.mkOption {
        type = lib.types.str;
        default = "UTC";
        description = "System timezone";
        example = "America/New_York";
      };

      language = lib.mkOption {
        type = lib.types.str;
        default = "en_US.UTF-8";
        description = "System locale/language";
      };

      consoleKeymap = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "Console keyboard layout";
        example = "us";
      };

      xkbLayout = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "X11 keyboard layout";
        example = "us";
      };

      xkbVariant = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "X11 keyboard variant";
      };
    };

    # =========================================================================
    # ROUTER
    # =========================================================================

    router = {
      type = lib.mkOption {
        type = lib.types.enum ["microvm" "libvirt" "none"];
        default = "microvm";
        description = ''
          Router VM implementation:
          - microvm: Declarative microVM with VFIO passthrough (default, recommended)
          - libvirt: Traditional libvirt VM (image-based, fallback)
          - none: No router VM (host handles networking directly)
        '';
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start router VM automatically at boot";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = cfg.username;
        description = "Router VM username (defaults to main username)";
      };

      hashedPassword = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Hashed password for router VM user (mkpasswd -m sha-512)";
      };

      wifi = {
        ssid = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "WiFi network SSID for automatic connection (legacy single-network)";
        };

        password = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "WiFi network password (legacy single-network)";
        };

        networks = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              ssid = lib.mkOption {
                type = lib.types.str;
                description = "WiFi network SSID";
              };
              password = lib.mkOption {
                type = lib.types.str;
                description = "WiFi network password";
              };
              priority = lib.mkOption {
                type = lib.types.int;
                default = 50;
                description = "Connection priority (higher = preferred)";
              };
            };
          });
          default = [];
          description = ''
            List of WiFi networks for automatic connection.
            Takes precedence over ssid/password if non-empty.
          '';
          example = [
            {
              ssid = "HomeNetwork";
              password = "secret";
              priority = 100;
            }
            {
              ssid = "WorkNetwork";
              password = "secret2";
              priority = 50;
            }
          ];
        };
      };

      # WAN config for both microvm and libvirt router types
      wan = {
        mode = lib.mkOption {
          type = lib.types.enum ["auto" "pci-passthrough" "macvtap" "none"];
          default = "auto";
          description = ''
            How to provide WAN to router VM:
            - auto: Detect WiFi card for passthrough, fall back to macvtap on ethernet
            - pci-passthrough: Force PCI passthrough (fails if no suitable device)
            - macvtap: Use macvtap on physical ethernet (for desktops/VMs)
            - none: No WAN interface (router will have no internet uplink)
          '';
        };

        device = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Specific device to use. If null, auto-detect.
            For pci-passthrough: PCI address like "00:14.3"
            For macvtap: interface name like "enp3s0"
          '';
        };

        preferWireless = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "In auto mode, prefer wireless over ethernet";
        };
      };

      microvm = {
        # Placeholder for microvm-specific router options (for future expansion)
      };

      libvirt = {
        vmName = lib.mkOption {
          type = lib.types.str;
          default = "router";
          description = "Name of the router VM in libvirt";
        };

        image = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/libvirt/images/router.qcow2";
          description = "Path to the router VM qcow2 image";
        };

        memory = lib.mkOption {
          type = lib.types.int;
          default = 2048;
          description = "Memory in MiB for the router VM";
        };

        vcpus = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Number of vCPUs for the router VM";
        };

        wan = {
          mode = lib.mkOption {
            type = lib.types.enum ["auto" "pci-passthrough" "macvtap" "none"];
            default = "auto";
            description = ''
              How to provide WAN to router VM:
              - auto: Detect WiFi card for passthrough, fall back to macvtap on ethernet
              - pci-passthrough: Force PCI passthrough (fails if no suitable device)
              - macvtap: Use macvtap on physical ethernet (for desktops)
              - none: No WAN interface (router will have no internet uplink)
            '';
          };

          device = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Specific device to use. If null, auto-detect.
              For pci-passthrough: PCI address like "0000:02:00.0"
              For macvtap: interface name like "enp3s0"
            '';
          };

          preferWireless = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "In auto mode, prefer wireless over ethernet";
          };
        };
      };

      vpn = {
        mullvad = {
          enable = lib.mkEnableOption "Mullvad VPN integration";

          bridges = lib.mkOption {
            type = lib.types.attrsOf lib.types.path;
            default = {};
            description = ''
              Map of bridge name to Mullvad WireGuard conf file.
              At router boot, each bridge is auto-connected and routed through
              its tunnel. Bridges omitted from this map go direct (no VPN).
              Table = off is injected automatically.
              Valid keys: pentest, comms, browse, dev, lurking
            '';
            example = {
              browse  = ./mullvad-browsing.conf;
              pentest = ./mullvad-pentest.conf;
            };
          };
        };
      };
    };

    # =========================================================================
    # HARDWARE
    # =========================================================================

    hardware = {
      platform = lib.mkOption {
        type = lib.types.enum ["intel" "amd" "generic"];
        default = "intel";
        description = "CPU platform (affects microcode, iommu settings)";
      };

      isAsus = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "ASUS system (enables asus-linux tools)";
      };

      asus = {
        acProfile = lib.mkOption {
          type = lib.types.enum ["Quiet" "Balanced" "Performance"];
          default = "Balanced";
          description = ''
            ASUS platform profile when on AC power. Controls fan curves and TDP limits.

            - Quiet: Conservative fan curves, lower performance, quietest operation
            - Balanced: Normal operation (default)
            - Performance: Aggressive cooling, highest performance, loudest fans

            Applied at boot and persisted in asusd configuration.
          '';
          example = "Balanced";
        };

        batteryProfile = lib.mkOption {
          type = lib.types.enum ["Quiet" "Balanced" "Performance"];
          default = "Quiet";
          description = ''
            ASUS platform profile when on battery power. Controls fan curves and TDP limits.

            - Quiet: Conservative fan curves, maximum battery life (default)
            - Balanced: Normal operation
            - Performance: Aggressive cooling, highest performance drain

            Applied at boot and persisted in asusd configuration.
          '';
          example = "Quiet";
        };
      };

      vfio = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable VFIO for PCI passthrough";
        };

        pciIds = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "PCI vendor:device IDs to bind to vfio-pci";
          example = ["8086:a840" "10de:1b80"];
        };

        wifiPciAddress = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "PCI address of WiFi card for passthrough (without domain)";
          example = "00:14.3";
        };
      };

      grub = {
        gfxmodeEfi = lib.mkOption {
          type = lib.types.str;
          default = "1920x1200";
          description = "GRUB EFI graphics mode";
        };
      };

      bluetooth = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable Bluetooth and Blueman applet";
        };
      };

      i2c = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable i2c bus for DDC/CI external monitor control";
        };
      };

      touchpad = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable libinput touchpad support";
        };
      };
    };

    # =========================================================================
    # LIBVIRT
    # =========================================================================

    libvirt = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable libvirt/QEMU/virt-manager virtualization stack.
          Automatically set to true when hydrix.router.type == "libvirt".
          Leave false when using microvm-only setups to avoid pulling in
          the full QEMU/virt-manager closure.
        '';
      };
    };

    # =========================================================================
    # SERVICES
    # =========================================================================

    services = {
      tailscale = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable Tailscale VPN";
        };
      };

      ssh = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable OpenSSH daemon";
        };
      };
    };

    # =========================================================================
    # DISKO - Disk Partitioning
    # =========================================================================

    disko = {
      enable = lib.mkEnableOption "disko disk management";

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/nvme0n1";
        description = "Target disk device";
        example = "/dev/sda";
      };

      swapSize = lib.mkOption {
        type = lib.types.str;
        default = "16G";
        description = "Swap size";
      };

      layout = lib.mkOption {
        type = lib.types.enum ["full-disk-plain" "full-disk-luks" "dual-boot-luks" "dual-boot-plain"];
        default = "full-disk-plain";
        description = ''
          Disk layout:
          - full-disk-plain: BTRFS, no encryption
          - full-disk-luks: BTRFS with LUKS encryption
          - dual-boot-luks: Preserve existing EFI, LUKS for NixOS
          - dual-boot-plain: Preserve existing EFI, no encryption
        '';
      };

      nixosPartition = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Pre-created NixOS partition device path (dual-boot only, set by installer)";
        example = "/dev/nvme0n1p3";
      };

      efiPartition = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Existing EFI partition to reuse (dual-boot only)";
        example = "/dev/nvme0n1p1";
      };

      grubExtraEntries = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Extra GRUB menu entries for booting existing OS installs (set by installer for dual-boot)";
      };

      efiBootloaderId = lib.mkOption {
        type = lib.types.str;
        default = "nixos";
        description = ''
          EFI bootloader ID — sets the directory under /boot/EFI/ and the UEFI boot
          entry label. Use a unique value per install (e.g. "hydrix-<serial>") so that
          multiple Hydrix installs on the same EFI partition each get their own UEFI
          entry and EFI binary, and a second install cannot clobber the first.
        '';
        example = "hydrix-mb-ux5406sa";
      };

      # Note: LUKS password is prompted at install time and written to /tmp/luks-password
      # It is NEVER stored in the declarative config for security reasons.
    };

    # =========================================================================
    # NETWORKING
    # =========================================================================

    networking = {
      bridges = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["br-mgmt" "br-pentest" "br-comms" "br-browse" "br-dev" "br-shared" "br-builder" "br-lurking" "br-files"];
        description = "Network bridges to create";
      };

      hostIp = lib.mkOption {
        type = lib.types.str;
        default = "192.168.100.1";
        description = "Host IP on management bridge";
      };

      routerIp = lib.mkOption {
        type = lib.types.str;
        default = "192.168.100.253";
        description = "Router VM IP (default gateway)";
      };

      subnets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Subnet prefixes per bridge (without last octet). Kept for compatibility; prefer vmSubnet.";
      };

      vmSubnet = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          This VM's own subnet prefix (e.g. "192.168.102"). Set in each
          profile's default.nix from its meta.nix. Used by files-agent to
          open port 8888 to the files VM (.2 on this subnet).
        '';
      };

      extraNetworks = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Network name, e.g. \"office\". Bridge becomes br-<name>.";
            };
            subnet = lib.mkOption {
              type = lib.types.str;
              description = "Subnet prefix without last octet, e.g. \"192.168.109\".";
            };
            routerTap = lib.mkOption {
              type = lib.types.str;
              description = "Router-side TAP interface name (max 15 chars), e.g. \"mv-router-offi\".";
            };
          };
        });
        default = [];
        description = ''
          Extra VM networks beyond the built-in set. Each entry creates:
          a host bridge (br-<name>), udev TAP attachment rules, and a
          router subnet with DHCP. Declare once in flake.nix; injected
          into host and router VM configs automatically.
        '';
      };

      profileNetworks = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Profile name (e.g. \"browsing\"). Used to derive the bash variable name IFACE_<NAME>.";
            };
            subnet = lib.mkOption {
              type = lib.types.str;
              description = "Subnet prefix without last octet, e.g. \"192.168.103\".";
            };
            routerTap = lib.mkOption {
              type = lib.types.str;
              description = "Router-side TAP interface name (max 15 chars), e.g. \"mv-router-brow\".";
            };
          };
        });
        default = [];
        description = ''
          All discovered profile networks, injected into the router VM at build time.
          Each entry configures an IP, DHCP range, and firewall subnet on the router.
          Populated automatically by flake.nix from profiles/*/meta.nix; do not set manually.
        '';
      };

      infraTapBridges = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = ''
          TAP interface → bridge name mappings for infra VMs that use built-in subnets
          (e.g. files VM with multiple bridge TAPs). Aggregated from infra meta.nix
          tapBridges fields by flake.nix and used by microvm-host.nix to generate
          udev rules and bridge attachment scripts.
        '';
      };

      vmRegistry = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            vmName = lib.mkOption {type = lib.types.str;};
            cid = lib.mkOption {type = lib.types.int;};
            bridge = lib.mkOption {type = lib.types.nullOr lib.types.str; default = null;};
            subnet = lib.mkOption {type = lib.types.nullOr lib.types.str; default = null;};
            workspace = lib.mkOption {type = lib.types.nullOr lib.types.int; default = null;};
            label = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Short display label (e.g. OFFICE) used in polybar workspace-desc";
            };
          };
        });
        default = {};
        description = ''
          Build-time VM registry, keyed by profile name. Written to
          /etc/hydrix/vm-registry.json at activation. All runtime
          tooling (scripts, polybar) reads from there instead of
          hardcoded CID maps.
        '';
      };
    };

    # =========================================================================
    # SECRETS
    # =========================================================================

    secrets = {
      enable = lib.mkEnableOption "sops-nix secrets management";

      github = {
        enable = lib.mkEnableOption "GitHub SSH key provisioning";
      };
    };

    # =========================================================================
    # COLORSCHEME INHERITANCE (VMs)
    # =========================================================================

    colorschemeInheritance = lib.mkOption {
      type = lib.types.enum ["full" "dynamic" "none"];
      default = "dynamic";
      description = ''
        VM color inheritance mode:
        - full: All colors from host
        - dynamic: Host background, VM text colors (default)
        - none: VM uses own colorscheme
      '';
    };

    vmColors = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable VM color inheritance mode";
      };

      hostColorscheme = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host colorscheme for VM inheritance";
      };
    };

    # =========================================================================
    # VM OPTIONS (for backwards compatibility)
    # =========================================================================

    vm = {
      user = lib.mkOption {
        type = lib.types.str;
        default = cfg.username;
        readOnly = true;
        description = "Alias for hydrix.username";
      };
    };

    # =========================================================================
    # POWER MANAGEMENT
    # =========================================================================

    power = {
      defaultProfile = lib.mkOption {
        type = lib.types.enum ["powersave" "balanced" "performance"];
        default = "balanced";
        description = ''
          Default power profile applied at boot.

          - powersave: Stops auto-cpufreq, sets powersave governor, disables turbo.
            Maximum battery life, reduced performance.
          - balanced (default): Auto-cpufreq manages CPU dynamically based on load
            and power source (battery vs AC).
          - performance: Stops auto-cpufreq, sets performance governor, enables turbo.
            Maximum performance, higher power consumption.

          Can be changed at runtime with: power-mode <powersave|balanced|performance>
        '';
        example = "powersave";
      };

      chargeLimit = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 20 100);
        default = null;
        description = ''
          Battery charge limit percentage (20-100). Set to preserve battery longevity
          by stopping charge at this threshold. Applied at boot via sysfs.

          Common values:
          - 60: Recommended for always-plugged-in laptops
          - 80: Good balance for mixed use
          - 100 or null: No limit (full charge)

          Requires kernel support (charge_control_end_threshold).
        '';
        example = 60;
      };

      autoCpuFreq = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable auto-cpufreq service for dynamic CPU frequency management";
      };
    };

    # =========================================================================
    # BUILDER VM
    # =========================================================================

    builder = {
      enable = lib.mkEnableOption "Builder VM host integration for lockdown mode builds";
    };

    # =========================================================================
    # GIT-SYNC VM
    # =========================================================================

    gitsync = {
      enable = lib.mkEnableOption "Git-sync VM host integration for lockdown mode git operations";
    };

    # =========================================================================
    # MICROVM HOST
    # =========================================================================

    microvmHost = {
      enable = lib.mkEnableOption "MicroVM host support";

      infrastructureOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Only include infrastructure VMs (router, builder) in microvm.vms. Used during install to skip building non-essential VM closures.";
      };

      defaultBridge = lib.mkOption {
        type = lib.types.str;
        default = "br-browse";
        description = "Default bridge for microVM TAP interfaces";
      };

      # Default VM names (can be overridden by user)
      vmNames = {
        browse = lib.mkOption {
          type = lib.types.str;
          default = "microvm-browsing";
          description = "Name for the browsing VM";
        };
        hack = lib.mkOption {
          type = lib.types.str;
          default = "microvm-pentest";
          description = "Name for the pentest/hacking VM";
        };
        dev = lib.mkOption {
          type = lib.types.str;
          default = "microvm-dev";
          description = "Name for the development VM";
        };
        comms = lib.mkOption {
          type = lib.types.str;
          default = "microvm-comms";
          description = "Name for the communications VM";
        };
        lurk = lib.mkOption {
          type = lib.types.str;
          default = "microvm-lurking";
          description = "Name for the lurking/research VM";
        };
        build = lib.mkOption {
          type = lib.types.str;
          default = "microvm-builder";
          description = "Name for the builder VM";
        };
        router = lib.mkOption {
          type = lib.types.str;
          default = "microvm-router";
          description = "Name for the router VM";
        };
        gitsync = lib.mkOption {
          type = lib.types.str;
          default = "microvm-gitsync";
          description = "Name for the git-sync VM";
        };
      };

      vms = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "this microVM";
            autostart = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Start this microVM at boot";
            };
            secrets = {
              github = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Provision GitHub SSH key";
              };
            };
          };
        });
        default = {};
        description = "MicroVMs to manage";
      };
    };

    # =========================================================================
    # GRAPHICAL
    # =========================================================================

    graphical = {
      enable = lib.mkEnableOption "Hydrix graphical environment";

      firefox.hostEnable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Install Firefox on the host system. Default false since browsing
          typically happens inside VMs. Set to true in administrative mode
          or wherever host-level Firefox is needed.
        '';
      };

      firefox.userAgent = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Firefox user-agent string, set as a locked policy preference.
          Accepts a named preset or a raw UA string. null = Firefox real UA.
          Presets: "edge-windows", "chrome-windows", "chrome-mac",
                   "safari-mac", "firefox-windows"
        '';
        example = "edge-windows";
      };

      firefox.extensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Firefox extensions to force-install, referenced by name from the
          built-in extension registry. Set per-profile to customise the
          extension set for each VM type.
          Available: ublock-origin, pywalfox, vimium-ff, detach-tab,
                     bitwarden, foxyproxy, wappalyzer, singlefile, darkreader, styl-us.
        '';
        example = [ "ublock-origin" "pywalfox" "bitwarden" "darkreader" ];
      };

      firefox.search.default = lib.mkOption {
        type = lib.types.str;
        default = "ddg";
        description = "Default search engine for Firefox. Use the engine short name (ddg, google, etc.).";
      };

      firefox.verticalTabs = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable vertical tabs sidebar. The horizontal tab bar is hidden and the
          sidebar collapses to an icon strip, expanding on hover.
        '';
      };

      firefox.uidensity = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Firefox UI density: 0 = normal, 1 = compact, 2 = touch.";
      };

      obsidian.hostEnable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Install Obsidian on the host system. Default false to keep the
          lockdown closure small. Set to true in administrative mode.
        '';
      };

      obsidian.vaultPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Paths to Obsidian vault directories (relative to home, e.g. "hack_the_world").
          CSS snippets and appearance settings are deployed to each vault's .obsidian/ dir.
        '';
        example = ["hack_the_world" "notes"];
      };

      standalone = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable standalone graphical environment for libvirt VMs.
          When true, the VM gets a full i3/polybar environment for use with
          virt-manager or similar. When false (default), apps are forwarded
          to the host via xpra (headless mode).
        '';
      };

      # Theme
      colorscheme = lib.mkOption {
        type = lib.types.str;
        default = cfg.colorscheme;
        description = "Graphical colorscheme (defaults to hydrix.colorscheme)";
      };

      wallpaper = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Wallpaper image path";
      };

      polarity = lib.mkOption {
        type = lib.types.enum ["dark" "light"];
        default = "dark";
        description = "Color scheme polarity";
      };

      # Font
      font = {
        family = lib.mkOption {
          type = lib.types.str;
          default = "Iosevka";
          description = "System font family";
        };

        size = lib.mkOption {
          type = lib.types.number;
          default = 10;
          description = "Base font size at 96 DPI. Supports decimals (e.g., 10.5).";
        };

        relations = lib.mkOption {
          type = lib.types.attrsOf lib.types.float;
          default = {
            alacritty = 1.0;
            polybar = 1.0;
            rofi = 1.0;
            dunst = 1.0;
            firefox = 1.2;
            gtk = 1.0;
          };
          description = ''
            Per-app font size multipliers. Final size = base × scale_factor × relation.
            Used when external monitor is connected.
          '';
        };

        # Standalone-specific relations (override when no external monitor)
        standaloneRelations = lib.mkOption {
          type = lib.types.attrsOf lib.types.float;
          default = {};
          example = {alacritty = 1.05;};
          description = ''
            Per-app font size multipliers for standalone mode (no external monitor).
            Apps not listed here fall back to the regular 'relations' values.
            Set in machines/<serial>.nix for machine-specific tuning.
          '';
        };

        familySizes = lib.mkOption {
          type = lib.types.attrsOf lib.types.int;
          default = {};
          description = "Base size per font family (profiles set defaults via mkDefault)";
        };

        overrides = lib.mkOption {
          type = lib.types.attrsOf lib.types.number;
          default = {};
          example = {alacritty = 10.5;};
          description = ''
            Direct font size overrides per app. Bypasses DPI scaling and relations.
            Supports decimals for apps like alacritty that use 0.5 increments.
          '';
        };

        maxSizes = lib.mkOption {
          type = lib.types.attrsOf lib.types.number;
          default = {};
          example = {
            alacritty = 10.5;
            polybar = 13;
          };
          description = ''
            Per-app maximum font size caps. Calculated sizes are clamped
            to these values after DPI scaling. Useful for bitmap fonts
            that only render well up to specific sizes.
          '';
        };

        familyOverrides = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Font family overrides per app";
        };

        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "Font packages to install on the host graphical environment";
        };

        packageMap = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          default = {};
          description = "Map font family names to nix packages (used by Stylix)";
        };

        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "Additional font packages always installed (emoji, serif fallbacks)";
        };

        vmPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "Font packages to install in microVMs";
        };

        profileMap = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Map font family names to profile names for auto-detection";
        };
      };

      # Keyboard
      keyboard = {
        xmodmap = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Freeform Xmodmap content. When non-empty, deployed as ~/.Xmodmap.
            Used for key remapping (e.g., CapsLock to Ctrl).
          '';
          example = ''
            clear lock
            clear control
            keycode 66 = Control_L
            add control = Control_L Control_R
          '';
        };
      };

      # UI
      ui = {
        gaps = lib.mkOption {
          type = lib.types.int;
          default = 15;
          description = "i3 inner gaps";
        };

        gapsStandaloneRelation = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Gap multiplier in standalone mode";
        };

        border = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Window border width";
        };

        barHeight = lib.mkOption {
          type = lib.types.int;
          default = 23;
          description = "Polybar height";
        };

        barHeightRelation = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Polybar height multiplier";
        };

        barHeightFamilyRelations = lib.mkOption {
          type = lib.types.attrsOf lib.types.float;
          default = {};
          description = "Per-font bar height multipliers (profiles set defaults via mkDefault)";
        };

        polybarFontOffset = lib.mkOption {
          type = lib.types.int;
          default = 3;
          description = "Polybar font vertical offset (adjusts text centering in bar)";
        };

        barPadding = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Polybar internal padding";
        };

        barGaps = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "Polybar floating margins (null = gaps/2)";
        };

        barEdgeGapsFactor = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Factor for bar-to-screen-edge gaps (0.0-1.0)";
        };

        outerGapsMatchBar = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "i3 outer gaps match barGaps";
        };

        floatingBar = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable floating polybar";
        };

        bottomBar = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable bottom polybar with VM metrics";
        };

        polybarStyle = lib.mkOption {
          type = lib.types.enum ["unibar" "modular" "pills"];
          default = "modular";
          description = "Polybar visual style";
        };

        padding = lib.mkOption {
          type = lib.types.int;
          default = 8;
          description = "General padding";
        };

        paddingSmall = lib.mkOption {
          type = lib.types.int;
          default = 5;
          description = "Small padding";
        };

        cornerRadius = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Picom corner radius";
        };

        workspaceLabels = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {
            "1" = "I";
            "2" = "II";
            "3" = "III";
            "4" = "IV";
            "5" = "V";
            "6" = "VI";
            "7" = "VII";
            "8" = "VIII";
            "9" = "IX";
            "10" = "X";
          };
          description = "Workspace display labels";
        };

        workspaceDescriptions = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Per-workspace descriptions";
        };

        shadowRadius = lib.mkOption {
          type = lib.types.int;
          default = 18;
          description = "Picom shadow radius";
        };

        shadowOffset = lib.mkOption {
          type = lib.types.int;
          default = 17;
          description = "Picom shadow offset";
        };

        opacity = {
          active = lib.mkOption {
            type = lib.types.float;
            default = 1.0;
            description = "Active window opacity (1.0 = no transparency)";
          };

          inactive = lib.mkOption {
            type = lib.types.float;
            default = 1.0;
            description = "Inactive window opacity (1.0 = no transparency)";
          };

          exclude = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc"];
            description = "Windows excluded from opacity rules";
          };

          alacritty = lib.mkOption {
            type = lib.types.float;
            default = 0.85;
            description = "Alacritty terminal opacity (deprecated: use overlay)";
          };

          overlay = lib.mkOption {
            type = lib.types.float;
            default = 0.85;
            description = "Unified opacity for transparent UI elements (terminals, overlays)";
          };

          overlayOverrides = lib.mkOption {
            type = lib.types.attrsOf lib.types.float;
            default = {alacritty = 0.95;};
            description = "Per-app overrides for overlay opacity";
          };

          rules = lib.mkOption {
            type = lib.types.attrsOf lib.types.int;
            default = {"Polybar" = 95;};
            description = "Custom opacity rules per window class";
          };
        };

        rofiWidth = lib.mkOption {
          type = lib.types.int;
          default = 800;
          description = "Rofi window width";
        };

        rofiHeight = lib.mkOption {
          type = lib.types.int;
          default = 400;
          description = "Rofi window height";
        };

        dunstWidth = lib.mkOption {
          type = lib.types.int;
          default = 300;
          description = "Dunst notification width";
        };

        dunstOffset = lib.mkOption {
          type = lib.types.int;
          default = 300;
          description = "Dunst offset from screen edge";
        };

        dunstEnablePopup = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable dunst notification popups (set false to use polybar module only)";
        };

        dunstSound = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Notification sound for dunst. Set to a sound file path (e.g., "bell.wav") to enable.
            Empty string or null disables sound.
          '';
          example = "bell.wav";
        };

        # Compositor settings
        compositor = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable compositor (picom) for shadows, rounded corners, and animations.";
          };

          animations = lib.mkOption {
            type = lib.types.enum ["none" "modern"];
            default = "modern";
            description = ''
              Picom animation mode:
              - none: Standard picom with fading only (xrender, no blur)
              - modern: Picom v12 with bouncy animations (xrender, overshoot curves)
            '';
          };
        };

        # Bar module layout overrides
        bar = {
          top = {
            left = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Top bar left modules. null = style default (workspaces + focus).";
              example = "xworkspaces focus-dynamic";
            };
            center = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Top bar center modules. null = style default (empty).";
            };
            right = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Top bar right modules. null = style default (metrics + date).";
              example = "volume-dynamic cpu-dynamic date-dynamic";
            };
          };
          bottom = {
            left = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Bottom bar left modules. null = style default (power + battery + host metrics).";
            };
            center = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Bottom bar center modules. null = style default (empty).";
            };
            right = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Bottom bar right modules. null = style default (VM metrics).";
            };
          };
        };
      };

      # Blue light filter (blugon)
      bluelight = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable blue light filter (blugon) for reducing eye strain";
        };

        defaultTemp = lib.mkOption {
          type = lib.types.int;
          default = 4500;
          description = ''
            Default color temperature in Kelvin.
            Lower = warmer (more red), higher = cooler (more blue).
            Typical range: 2500K (very warm) to 6500K (daylight).
          '';
        };

        minTemp = lib.mkOption {
          type = lib.types.int;
          default = 2500;
          description = "Minimum temperature (warmest/most red).";
        };

        maxTemp = lib.mkOption {
          type = lib.types.int;
          default = 6500;
          description = "Maximum temperature (coolest/most blue).";
        };

        step = lib.mkOption {
          type = lib.types.int;
          default = 200;
          description = "Temperature adjustment step for keybindings/clicks.";
        };

        autoRestart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Automatically restart blugon service on failure. When false, blugon only starts on boot.";
        };

        # Time-based schedule for auto mode
        schedule = {
          dayTemp = lib.mkOption {
            type = lib.types.int;
            default = 6500;
            description = "Color temperature during daytime (cooler/bluer).";
          };

          nightTemp = lib.mkOption {
            type = lib.types.int;
            default = 3500;
            description = "Color temperature at night (warmer/redder).";
          };

          dayStart = lib.mkOption {
            type = lib.types.int;
            default = 7;
            description = "Hour when daytime begins (0-23).";
          };

          nightStart = lib.mkOption {
            type = lib.types.int;
            default = 20;
            description = "Hour when nighttime begins (0-23).";
          };
        };
      };

      # Scaling
      scaling = {
        auto = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable automatic DPI detection";
        };

        applyOnLogin = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Apply xrandr changes on login";
        };

        referenceDpi = lib.mkOption {
          type = lib.types.int;
          default = 96;
          description = "Reference DPI for base values";
        };

        internalResolution = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "1920x1200";
          description = "Preferred internal display resolution";
        };

        standaloneScaleFactor = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Scale multiplier for standalone mode";
        };
      };

      # VM Bar (bottom bar with resource metrics inside VMs)
      vmBar = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable bottom polybar inside VMs showing resource usage";
        };

        position = lib.mkOption {
          type = lib.types.enum ["bottom"];
          default = "bottom";
          description = "Position of the VM resource bar";
        };
      };

      # Lockscreen
      lockscreen = {
        idleTimeout = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = 600;
          description = "Seconds before auto-lock (null to disable)";
        };

        font = lib.mkOption {
          type = lib.types.str;
          default = "CozetteVector";
          description = "Lockscreen font (defaults to CozetteVector for crisp text on blurred backgrounds)";
        };

        fontSize = lib.mkOption {
          type = lib.types.int;
          default = 143;
          description = "Lockscreen main text size";
        };

        clockSize = lib.mkOption {
          type = lib.types.int;
          default = 104;
          description = "Lockscreen clock size";
        };

        text = lib.mkOption {
          type = lib.types.str;
          default = "Papers, please";
          description = "Lockscreen prompt text";
        };

        wrongText = lib.mkOption {
          type = lib.types.str;
          default = "Ah ah ah! You didn't say the magic word!!";
          description = "Wrong password text";
        };

        verifyText = lib.mkOption {
          type = lib.types.str;
          default = "Verifying...";
          description = "Verification text";
        };

        blur = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Apply blur effect";
        };
      };

      # Splash
      splash = {
        enable = lib.mkEnableOption "splash screen during startup";

        title = lib.mkOption {
          type = lib.types.str;
          default = "HYDRIX";
          description = "Splash title";
        };

        text = lib.mkOption {
          type = lib.types.str;
          default = "initializing...";
          description = "Splash subtitle";
        };

        maxTimeout = lib.mkOption {
          type = lib.types.int;
          default = 15;
          description = "Safety timeout in seconds";
        };

        font = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Splash font (null = CozetteVector)";
        };
      };
    };
  };

  # =========================================================================
  # WINDOW MANAGER OPTIONS
  # =========================================================================

  options.hydrix.i3 = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the i3/X11 window manager stack.
        Activates: i3, polybar, rofi, picom, xsession, display-setup, focus-mode.
        Set true in shared/graphical.nix to preserve the current X11 setup.
        Set false (with hydrix.hyprland.enable = true) to switch to Wayland.
      '';
    };
  };

  options.hydrix.hyprland = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the Hyprland/Wayland window manager stack.
        Activates: Hyprland, Waybar, wofi, hypridle, hyprlock, hypr-focus-daemon.
        Can be true alongside hydrix.i3.enable during transition testing.
      '';
    };
  };

  # =========================================================================
  # APPLY OPTIONS TO SYSTEM CONFIG
  # =========================================================================

  config = lib.mkMerge [
    # Assertions - validate configuration options
    {
      assertions = [
        # Username validation
        {
          assertion = cfg.username != "";
          message = "hydrix.username cannot be empty";
        }
        {
          assertion = builtins.match "[a-z_][a-z0-9_-]*" cfg.username != null;
          message = "hydrix.username '${cfg.username}' is invalid: must be lowercase alphanumeric with underscore/hyphen, starting with letter or underscore";
        }

        # Hostname validation (RFC 1123)
        {
          assertion = cfg.hostname != "";
          message = "hydrix.hostname cannot be empty";
        }
        {
          assertion = builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" cfg.hostname != null;
          message = "hydrix.hostname '${cfg.hostname}' is invalid: must be lowercase alphanumeric with hyphens, 1-63 chars, start/end with alphanumeric";
        }

        # Colorscheme validation (checks user dir first, then framework)
        {
          assertion = colorschemeExists cfg.colorscheme;
          message = "hydrix.colorscheme '${cfg.colorscheme}' not found (checked user and framework colorschemes/)";
        }

        # WiFi PCI address format (XX:XX.X)
        {
          assertion =
            cfg.hardware.vfio.wifiPciAddress
            == ""
            || builtins.match "[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-9a-fA-F]" cfg.hardware.vfio.wifiPciAddress != null;
          message = "hydrix.hardware.vfio.wifiPciAddress '${cfg.hardware.vfio.wifiPciAddress}' is invalid: must be in format XX:XX.X (e.g., 00:14.3)";
        }

        # Graphical colorscheme validation (if graphical enabled)
        {
          assertion = !cfg.graphical.enable || colorschemeExists cfg.graphical.colorscheme;
          message = "hydrix.graphical.colorscheme '${cfg.graphical.colorscheme}' not found (checked user and framework colorschemes/)";
        }
      ];
    }

    # Apply hostname
    {
      networking.hostName = lib.mkDefault cfg.hostname;
    }

    # Apply locale settings
    {
      time.timeZone = lib.mkDefault cfg.locale.timezone;
      i18n.defaultLocale = lib.mkDefault cfg.locale.language;
      console.keyMap = lib.mkDefault cfg.locale.consoleKeymap;
      services.xserver.xkb = {
        layout = lib.mkDefault cfg.locale.xkbLayout;
        variant = lib.mkDefault cfg.locale.xkbVariant;
      };
    }

    # Apply GRUB settings
    (lib.mkIf (cfg.hardware.grub.gfxmodeEfi != "") {
      boot.loader.grub.gfxmodeEfi = lib.mkDefault cfg.hardware.grub.gfxmodeEfi;
    })

    # Boot loader defaults for non-disko installs (GRUB, matching stable behavior)
    # Disko installs set their own boot.loader in modules/host/disko.nix
    (lib.mkIf (cfg.vmType == "host" && !cfg.disko.enable) {
      boot.loader = lib.mkDefault {
        grub = {
          enable = true;
          device = "nodev";
          efiSupport = true;
          useOSProber = true;
        };
        efi = {
          canTouchEfiVariables = true;
          efiSysMountPoint = "/boot";
        };
      };
    })
  ];
}
