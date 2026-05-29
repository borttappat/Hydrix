# Hydrix Host Options
#
# Hardware, router, virtualisation, disko, power, builder, gitsync, microvmHost.
# Host machines import this.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;
in {
  options.hydrix = {
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
        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "Additional packages installed in the router VM.";
        };

        dnsmasq = {
          servers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["1.1.1.1" "8.8.8.8"];
            description = "Upstream DNS servers passed to dnsmasq.";
          };
          enableDhcpLogging = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable dnsmasq log-dhcp (verbose DHCP event logging).";
          };
        };

        firewall = {
          sharedSubnets = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = ''
              Subnets (CIDR) whose traffic is allowed to cross bridge boundaries.
              All other subnets are fully isolated from each other.
              Set in hydrix-config to allow inter-VM communication on specific subnets.
            '';
          };
          extraRules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Extra nftables rules appended to the forward chain.";
          };
        };
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
      };

      vpn = {
        mullvad = {
          enable = lib.mkEnableOption "Mullvad VPN integration";

          bridges = lib.mkOption {
            type = lib.types.attrsOf (lib.types.either lib.types.path (lib.types.attrsOf lib.types.path));
            default = {};
            description = ''
              Map of bridge name to Mullvad WireGuard conf file(s).

              Single exit node (simple format):
                bridge = ./mullvad-bridge.conf;

              Multiple exit nodes (for rotation):
                bridge = {
                  primary = ./mullvad-bridge-primary.conf;
                  backup1 = ./mullvad-bridge-backup1.conf;
                  backup2 = ./mullvad-bridge-backup2.conf;
                };

              At router boot, all tunnels connect; the primary exit is active,
              backups are available for manual rotation via vpn-assign.
              Table = off is injected automatically.
              Valid keys: pentest, comms, browse, dev, lurking
            '';
            example = {
              browse = ./mullvad-browsing.conf;
              pentest = {
                primary = ./mullvad-pentest.conf;
                backup1 = ./mullvad-pentest-de.conf;
              };
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
          by stopping charge at this threshold. Applied at boot and on charger hotplug
          via sysfs (charge_control_end_threshold).

          Common values:
          - 60: Recommended for always-plugged-in laptops
          - 80: Good balance for mixed use
          - 100 or null: No limit (full charge)
        '';
        example = 60;
      };

      chargeStartLimit = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 1 99);
        default = null;
        description = ''
          Battery charge resume threshold percentage. Charging resumes when battery
          drops below this value. Must be less than chargeLimit.

          Applied via sysfs (charge_control_start_threshold) — only effective on
          hardware that exposes this node (check: ls /sys/class/power_supply/BAT0/).
          Silently ignored if the node is absent.

          Example: chargeLimit = 60; chargeStartLimit = 40; — charges 40-60% range.
        '';
        example = 40;
      };

      autoCpuFreq = lib.mkOption {
        type = lib.types.bool;
        default = false; # HWP (balance_power EPP) handles scaling — no polling daemon needed
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
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable MicroVM host support.";
      };

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

      knownVms = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "All VM names managed by this flake. Populated automatically by the flake — do not set manually.";
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
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Enable this VM on this host. Set false to explicitly exclude a VM.";
            };
            autostart = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Start this microVM at boot";
            };
            secrets = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Named secrets to provision into this VM (e.g. [ \"github\" ])";
            };
          };
        });
        default = {};
        description = "MicroVMs to manage";
      };
    };
  };

  config = lib.mkMerge [
    # Apply GRUB settings
    (lib.mkIf (cfg.hardware.grub.gfxmodeEfi != "") {
      boot.loader.grub.gfxmodeEfi = lib.mkDefault cfg.hardware.grub.gfxmodeEfi;
    })

    # Boot loader defaults for non-disko installs (GRUB, matching stable behavior)
    # Disko installs set their own boot.loader in host/disko.nix
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
