# Hydrix Shared Options
#
# Identity, paths, colorscheme, services, networking, secrets.
# All machines (host and VMs) import this.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;

  # Resolve a colorscheme name to its JSON path
  # Checks user colorschemes dir first, falls back to framework colorschemes
  frameworkColorschemesDir = ../theming/colorschemes;
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
      default = "nvid";
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

    editor = lib.mkOption {
      type = lib.types.str;
      default = "vim";
      description = "Default text editor (sets EDITOR/VISUAL env vars)";
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

    };

    # =========================================================================
    # NETWORKING
    # =========================================================================

    networking = {
      bridges = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["br-mgmt" "br-pentest" "br-comms" "br-browse" "br-dev" "br-builder" "br-lurking" "br-files"];
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

      vsockPorts = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {
          xpra          = 14500;
          metrics       = 14501;
          staging       = 14502;
          colorscheme   = 14503;
          switch        = 14504;
          pulse         = 14505;
          waypipeLaunch = 14508;
          displayMode   = 14509;
          builderBuild  = 14510;
          builderStatus = 14511;
          gitsyncGit    = 14512;
          gitsyncStatus = 14513;
          vaultAgent    = 14514;
          exitNodes     = 14515;
          lanControl    = 14516;
        };
        description = "vsock port assignments for Hydrix services. Override to avoid collisions with other software.";
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
            bridge = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            subnet = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            workspace = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            label = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Short display label (e.g. OFFICE) used in polybar workspace-desc";
            };
            hasDisplay = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this VM runs a display-mode service (waypipe/xpra). False for headless infra VMs.";
            };
            focusBorder = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Focus border color for this VM's windows in Hyprland. Named color (red, yellow, ...) or hex RRGGBBAA. Matches hydrix.vmThemeSync.focusBorder in the VM's own config.";
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

      infraVmRegistry = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            vmName = lib.mkOption {type = lib.types.str;};
            cid = lib.mkOption {type = lib.types.int;};
            bridge = lib.mkOption {type = lib.types.nullOr lib.types.str; default = null;};
            subnet = lib.mkOption {type = lib.types.nullOr lib.types.str; default = null;};
            workspace = lib.mkOption {type = lib.types.nullOr lib.types.int; default = null;};
            label = lib.mkOption {type = lib.types.str; default = "";};
            hasDisplay = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this VM runs a display-mode service. Defaults false for infra VMs.";
            };
          };
        });
        default = {};
        description = ''
          Registry entries for infrastructure VMs (router, builder, etc.).
          Merged into /etc/hydrix/vm-registry.json alongside profile VMs.
          Declared by infra VM modules; read by the same runtime tooling.
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

      githubSecretsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to the encrypted github.yaml file in your hydrix-config repo.
          Set this in your machine config: hydrix.secrets.githubSecretsFile = ../secrets/github.yaml;
        '';
      };

      files = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            file = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
            };
            keys = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule {
                options = {
                  outFile = lib.mkOption { type = lib.types.str; };
                  mode    = lib.mkOption { type = lib.types.str; default = "0600"; };
                };
              });
              default = {};
              description = ''
                Keys to extract from the sops file (per-key mode).
                Each entry extracts one YAML key to a separate output file.
                When empty (default), the entire file is decrypted as-is (whole-file mode).
              '';
            };
            outFile = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Whole-file mode only (keys = {}): output filename inside /run/secrets/<name>/.
                Defaults to the basename of file (e.g. "discord.yaml" for secrets/discord.yaml).
              '';
            };
            vmDir = lib.mkOption {
              type = lib.types.str;
              description = "Subdirectory name under /run/hydrix-secrets/<vm>/ for this secret type.";
            };
          };
        });
        default = {};
        description = ''
          Declarative sops secret files. Each enabled entry with a non-null file becomes
          a hydrix-sops-decrypt-<name>.service and can be provisioned into VMs by listing
          the name in hydrix.microvmHost.vms.<vmname>.secrets.
        '';
      };

      wifi = {
        enable = lib.mkEnableOption "WiFi credential provisioning to router VM";
      };

      wifiSecretsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to the encrypted wifi.yaml file in your hydrix-config repo.
          Set this in your machine config: hydrix.secrets.wifiSecretsFile = ../secrets/wifi.yaml;
          Run setup-wifi-secrets to create this file from your existing modules/wifi.nix.
        '';
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
        description = ''
          Build-time colorscheme name for VM inheritance. When vmColors.enable is true
          and this is non-null, VMs use this colorscheme for Stylix theming and the
          Alacritty background color instead of their own colorscheme. Set in flake.nix
          by extracting the host machine's hydrix.colorscheme.
          Consumed by: theming/programs/alacritty.nix,
                       theming/graphical/scripts.nix,
                       theming/graphical/stylix.nix.
        '';
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
  };

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
  ];
}
