# Hydrix

**Secure VM- and isolation-based workstation framework**

Hydrix is an options-driven NixOS framework that provides complete network isolation through VM compartmentalization. Your WiFi hardware is passed directly to a router VM via VFIO, giving you granular control over network traffic while maintaining a hardened host.

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture Overview](#architecture-overview)
- [Installation](#installation)
- [Configuration](#configuration)
- [Colorscheme System](#colorscheme-system)
- [VM Theme Sync](#vm-theme-sync)
- [Font System](#font-system)
- [MicroVM Management](#microvm-management)
  - [Task Pentest VMs](#task-pentest-vms-per-engagement)
  - [Files VM (Encrypted Inter-VM Transfer)](#files-vm-encrypted-inter-vm-transfer)
- [Vsock Communication](#vsock-communication)
- [VM Store Sharing](#vm-store-sharing)
- [Build System](#build-system)
- [Shell](#shell)
- [Workspace Integration](#workspace-integration)
- [Lockscreen](#lockscreen)
- [Keybindings](#keybindings)
- [Scripts Reference](#scripts-reference)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

Fresh install from NixOS live environment
```bash
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
```

Or create a user config from template
```bash
nix flake init -t github:borttappat/Hydrix
```

After installation, your configuration lives at `~/hydrix-config/`.

---

## Architecture Overview

```
+---------------------------------------------------------------------+
|                         HOST (Lockdown Mode)                        |
|   - No direct internet access                                       |
|   - WiFi hardware passed to router VM via VFIO                      |
|   - Bridge networks for VM isolation                                |
+---------------------------------------------------------------------+
                            |
         +---- br-mgmt (192.168.100.0/24) --------+
         +---- br-pentest (192.168.101.0/24) -----+
         +---- br-comms (192.168.102.0/24) -------+
         +---- br-browse (192.168.103.0/24) ------+--- Router VM (WiFi)
         +---- br-dev (192.168.104.0/24) ---------+
         +---- br-shared (192.168.105.0/24) ------+
         +---- br-builder (192.168.106.0/24) -----+
         +---- br-lurking (192.168.107.0/24) -----+
         +---- br-files (192.168.108.0/24) -------+
                            |
     +-----------+----------+------------+-----------+-----------+
     |           |          |            |           |           |
+--------+  +--------+  +--------+  +---------+  +--------+  +--------+
|Browsing|  |Pentest |  |  Dev   |  | Builder |  |Gitsync |  | Files  |
|  VM    |  |   VM   |  |   VM   |  |   VM    |  |  VM    |  |  VM    |
|CID:103 |  |CID:102 |  |CID:105 |  |CID:210  |  |CID:211 |  |CID:212 |
+--------+  +--------+  +--------+  +---------+  +--------+  +--------+
```

> **CIDs and subnets are user-configurable.** Built-in profiles (browsing, pentest, dev, comms, lurking) ship with default CIDs/subnets but these are declared in each profile's `meta.nix` in your `hydrix-config/profiles/<name>/meta.nix`. The host module writes all profile metadata to `/etc/hydrix/vm-registry.json` at activation — all scripts, polybar, and i3 read from there at runtime, never from hardcoded maps. Adding a new VM type requires only `profiles/<name>/meta.nix` + `profiles/<name>/default.nix` in your config.

### VM Registry (`/etc/hydrix/vm-registry.json`)

Generated at NixOS activation from all profile `meta.nix` files. Every runtime tool reads from here — no hardcoded CID or workspace maps anywhere in scripts or modules.

```json
{
  "pentest":  { "vmName": "microvm-pentest",  "cid": 102, "bridge": "br-pentest",  "subnet": "192.168.102", "workspace": 2, "label": "PENTEST"  },
  "browsing": { "vmName": "microvm-browsing", "cid": 103, "bridge": "br-browse",   "subnet": "192.168.103", "workspace": 3, "label": "BROWSING" },
  "comms":    { "vmName": "microvm-comms",    "cid": 104, "bridge": "br-comms",    "subnet": "192.168.104", "workspace": 4, "label": "COMMS"    },
  "office":   { "vmName": "microvm-office",   "cid": 107, "bridge": "br-office",   "subnet": "192.168.107", "workspace": 7, "label": "OFFICE"   }
}
```

**Convention: `vsockCid` = subnet last octet = i3 workspace.** All three use the same number. Custom profiles start at CID 107+. Reserved: 200 (router), 210 (builder), 211 (gitsync).

Each entry drives: i3 `for_window` border rules, polybar workspace-desc label, `ws-app`/`ws-rofi` workspace→VM routing, `focus-rofi` menu, `vm-sync` profile targeting, and file transfer IP resolution.

### Boot Modes (Specialisations)

| Mode | Purpose | Internet Access |
|------|---------|-----------------|
| **Lockdown** (default) | Hardened, isolated host | VMs only (via router) |
| **Administrative** | Full functionality | Host + VMs |
| **Fallback** | Emergency direct WiFi | Host direct (no VMs) |

Switch modes live (no reboot needed between lockdown and administrative):

```bash
hydrix-switch administrative    # Live switch to admin mode
hydrix-switch lockdown          # Live switch to lockdown mode
hydrix-mode                     # Show current mode
```

### VM Types

**MicroVM** (Recommended):
- Boot time: ~2-3 seconds
- Uses QEMU with virtiofs for shared /nix/store
- Display via xpra over vsock

**Libvirt** (Alternative):
- Boot time: ~8-10 seconds
- Traditional qcow2 images
- Good for encrypted VMs

---

## Installation

### Fresh Install (From Live Environment)

```bash
# Download and run installer
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
```

The installer will:
1. **Auto-detect hardware**: CPU (Intel/AMD), WiFi PCI address, ASUS features
2. **Prompt for configuration**: Username, hostname, locale, disk, WiFi credentials
3. **Partition disk**: GPT with EFI, optional LUKS encryption
4. **Generate config** in `~/hydrix-config/`:
   - `flake.nix` - Main flake importing Hydrix
   - `machines/<hostname>.nix` - Your machine configuration
   - `specialisations/` - Boot mode configurations

### Migration from Existing NixOS

```bash
# Run the setup script
./scripts/setup-hydrix.sh
```

This auto-detects your current system configuration and generates a minimal Hydrix config preserving your existing disk layout.

### Generated Configuration Structure

```
~/hydrix-config/
├── flake.nix                    # Imports Hydrix from GitHub
├── machines/
│   └── <hostname>.nix           # Your machine config (all options here)
├── profiles/                    # VM profile customizations (overlay on Hydrix base)
│   ├── browsing/
│   │   ├── default.nix          # Your customizations
│   │   └── packages/            # Custom packages (via vm-sync)
│   ├── pentest/
│   ├── dev/
│   ├── comms/
│   └── lurking/
├── colorschemes/                # Custom colorschemes (override framework ones)
├── fonts/                       # Custom font configuration
├── shared/
│   └── common.nix               # Settings for all machines
└── specialisations/
    ├── _base.nix                # Shared base packages
    ├── lockdown.nix             # Lockdown mode config
    ├── administrative.nix       # Admin mode config
    └── fallback.nix             # Fallback mode config
```

### Profile Customization

User profiles are layered ON TOP of Hydrix base profiles. You get all base functionality plus your customizations:

```nix
# profiles/pentest/default.nix
{ config, lib, pkgs, ... }:
{
  imports = [ ./packages ];

  # Override colorscheme (base uses nvid)
  hydrix.colorscheme = "nord";

  # Add extra packages
  environment.systemPackages = with pkgs; [ gobuster ffuf ];

  # Add CTF hosts
  networking.extraHosts = ''
    10.10.10.1  target.htb
  '';
}
```

### Flake Location Detection

Hydrix auto-detects your config with this priority:
1. `$HYDRIX_FLAKE_DIR` environment variable
2. `~/hydrix-config/` (user mode - imports from GitHub)
3. `~/Hydrix/` (developer mode - local clone)

### User Flake Example

```nix
{
  inputs.hydrix.url = "github:borttappat/Hydrix";
  inputs.nixpkgs.follows = "hydrix/nixpkgs";

  outputs = { hydrix, ... }:
  let
    userProfiles = ./profiles;  # Your profile customizations
  in {
    nixosConfigurations.myhost = hydrix.lib.mkHost {
      modules = [ ./machines/myhost.nix ];
    };

    # MicroVMs with user profiles overlaid on Hydrix base
    nixosConfigurations.microbrowse = hydrix.lib.mkMicroVM {
      profile = "browsing";
      hostname = "microbrowse";
      inherit userProfiles;  # Your customizations in ./profiles/browsing/
    };

    nixosConfigurations.microhack = hydrix.lib.mkMicroVM {
      profile = "pentest";
      hostname = "microhack";
      inherit userProfiles;
    };

    # Router and builder (no user profiles needed)
    nixosConfigurations.microrouter = hydrix.lib.mkMicrovmRouter {};
    nixosConfigurations.microbuild = hydrix.lib.mkMicrovmBuilder {};
  };
}
```

### Library Functions

| Function | Purpose |
|----------|---------|
| `hydrix.lib.mkHost` | Create host configuration |
| `hydrix.lib.mkMicroVM` | Create MicroVM configuration |
| `hydrix.lib.mkMicrovmRouter` | Create MicroVM router |
| `hydrix.lib.mkMicrovmBuilder` | Create builder VM for lockdown mode |
| `hydrix.lib.mkVM` | Create libvirt VM (for images) |
| `hydrix.lib.mkLibvirtRouter` | Create libvirt router (fallback) |

---

## Configuration

All configuration is done through `hydrix.*` options in your machine config file (`machines/<hostname>.nix`).

### Identity & User

```nix
{
  hydrix = {
    username = "user";
    hostname = "hydrix";
    colorscheme = "hydrix";

    user = {
      hashedPassword = null;         # mkpasswd -m sha-512 (null = prompt on first login)
      sshPublicKeys = [];            # SSH authorized_keys
      extraGroups = [];              # Additional groups beyond defaults
    };

    locale = {
      timezone = "America/New_York";
      language = "en_US.UTF-8";
      consoleKeymap = "us";
      xkbLayout = "us";
      xkbVariant = "";
    };
  };
}
```

### Default Applications

```nix
{
  hydrix = {
    terminal = "alacritty";
    shell = "fish";                  # fish, bash, or zsh
    browser = "firefox";
    editor = "vim";
    fileManager = "ranger";
    imageViewer = "feh";
    mediaPlayer = "mpv";
    pdfViewer = "zathura";
  };
}
```

### Hardware

```nix
{
  hydrix.hardware = {
    platform = "intel";              # "intel", "amd", or "generic"
    isAsus = false;                  # ASUS-specific features (aura, power-profile)

    vfio = {
      enable = true;                 # Enable VFIO for PCI passthrough
      pciIds = [ "8086:a840" ];      # PCI vendor:device IDs to bind to vfio-pci
      wifiPciAddress = "00:14.3";    # PCI address of WiFi card for passthrough
    };

    grub.gfxmodeEfi = "1920x1200";  # GRUB EFI graphics mode
  };
}
```

### Router

```nix
{
  hydrix.router = {
    type = "microvm";               # "microvm", "libvirt", or "none"
    autostart = true;

    wifi = {
      # Single network (legacy)
      ssid = "MyNetwork";
      password = "secret";           # Consider using sops-nix

      # Multiple networks (takes precedence if non-empty)
      networks = [
        { ssid = "HomeNetwork"; password = "secret"; priority = 100; }
        { ssid = "WorkNetwork"; password = "secret2"; priority = 50; }
      ];
    };

    # Mullvad VPN integration
    vpn.mullvad = {
      enable = true;
      privateKey = "";               # WireGuard private key
      address = "";                  # Assigned VPN address (e.g., 10.65.x.x/32)
      exitNodes = {
        se-sto = { server = "se-sto-wg-001.relays.mullvad.net"; publicKey = "..."; };
      };
    };

    # Libvirt router options (when type = "libvirt")
    libvirt.wan = {
      mode = "auto";                # "auto", "pci-passthrough", "macvtap", "none"
      device = null;                # Auto-detect, or specify PCI address / interface name
      preferWireless = true;
    };
  };
}
```

### Networking

```nix
{
  hydrix.networking = {
    bridges = [ "br-mgmt" "br-pentest" "br-comms" "br-browse" "br-dev" "br-shared" "br-builder" "br-lurking" ];
    hostIp = "192.168.100.1";
    routerIp = "192.168.100.253";
    subnets = {
      mgmt = "192.168.100";
      pentest = "192.168.101";
      comms = "192.168.102";
      browse = "192.168.103";
      dev = "192.168.104";
      shared = "192.168.105";
      builder = "192.168.106";
      lurking = "192.168.107";
    };
  };
}
```

### MicroVM Host

```nix
{
  hydrix.microvmHost = {
    enable = true;

    # Customizable VM names (defaults shown)
    vmNames = {
      browse = "microvm-browsing";
      hack = "microvm-pentest";
      dev = "microvm-dev";
      comms = "microvm-comms";
      lurk = "microvm-lurking";
      build = "microvm-builder";
      router = "microvm-router";
    };

    vms = {
      microbrowse = { enable = true; autostart = false; };
      microhack = { enable = true; };
      microdev = { enable = true; secrets.github = true; };
      microcomms = { enable = true; };
      microlurk = { enable = true; };
    };
  };

  hydrix.builder.enable = true;      # Builder VM for lockdown mode builds
}
```

### Graphical Configuration

```nix
{
  hydrix.graphical = {
    enable = true;
    standalone = false;              # true for libvirt VMs with own display
    colorscheme = "hydrix";
    wallpaper = "/path/to/wallpaper.jpg";
    polarity = "dark";

    # Font configuration
    font = {
      family = "Iosevka";
      size = 10;                      # Base size at 96 DPI

      # Per-app font size multipliers (final size = base * scale_factor * relation)
      relations = {
        alacritty = 1.0;
        polybar = 1.0;
        rofi = 1.0;
        dunst = 1.0;
        firefox = 1.2;
        gtk = 1.0;
      };

      # Standalone mode overrides (no external monitor)
      standaloneRelations = {};       # e.g., { alacritty = 1.05; }

      overrides.alacritty = 12;       # Fixed size (bypass scaling)
      familyOverrides.polybar = "Tamzen";
    };

    # UI dimensions
    ui = {
      gaps = 15;
      border = 2;
      barHeight = 23;
      barPadding = 2;
      cornerRadius = 2;
      shadowRadius = 18;
      floatingBar = true;
      bottomBar = true;              # Bottom bar with VM metrics
      polybarStyle = "modular";      # unibar, modular, or pills

      # Workspace labels (attrset mapping number to label)
      workspaceLabels = {
        "1" = "I"; "2" = "II"; "3" = "III"; "4" = "IV"; "5" = "V";
        "6" = "VI"; "7" = "VII"; "8" = "VIII"; "9" = "IX"; "10" = "X";
      };

      # Window opacity
      opacity = {
        active = 1.0;
        inactive = 1.0;
        overlay = 0.85;              # Unified opacity for terminals/overlays
        overlayOverrides = { alacritty = 0.95; };
        rules = { "Polybar" = 95; }; # Per-window-class opacity rules
        exclude = [ "Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc" ];
      };

      # Rofi/Dunst dimensions
      rofiWidth = 800;
      rofiHeight = 400;
      dunstWidth = 300;
      dunstOffset = 24;

      # Compositor animations
      compositor.animations = "modern"; # "none" or "modern" (bouncy picom v12)
    };

    # VM resource bar (inside VMs)
    vmBar = {
      enable = true;
      position = "bottom";
    };

    # DPI scaling
    scaling = {
      auto = true;
      applyOnLogin = true;
      referenceDpi = 96;
      internalResolution = "1920x1200";
      standaloneScaleFactor = 1.0;
    };

    # Blue light filter
    bluelight = {
      enable = true;
      defaultTemp = 4500;
      minTemp = 2500;
      maxTemp = 6500;
      step = 200;                    # Temperature adjustment per keypress
      schedule = {
        dayTemp = 6500;
        nightTemp = 3500;
        dayStart = 7;
        nightStart = 20;
      };
    };

    # Lockscreen
    lockscreen = {
      idleTimeout = 600;             # Seconds before auto-lock (null to disable)
      font = "CozetteVector";
      fontSize = 143;
      clockSize = 104;
      text = "Enter password";
      wrongText = "Ah ah ah! You didn't say the magic word!!";
      verifyText = "Verifying...";
      blur = true;
    };

    # Splash screen
    splash = {
      enable = true;
      title = "HYDRIX";
      text = "initializing...";
      maxTimeout = 15;
    };
  };
}
```

### Graphical Package Tiers

`modules/graphical/packages.nix` and `modules/graphical/home.nix` install different sets of packages depending on the system type, controlled by two derived booleans:

```nix
isHost    = vmType == null || vmType == "host";
isMicrovm = !isHost && !graphical.standalone;
```

| Tier | Condition | What it gets |
|---|---|---|
| **microvm** | VM with `standalone = false` | Theming only: pywal, wpgtk, feh, imagemagick, xrdb, pulseaudio, xclip/xsel |
| **standalone** | VM with `standalone = true` | Adds: polybar, rofi, picom, xdotool, unclutter, xcape, scrot, flameshot, X11 tools |
| **host** | `vmType = "host"` | Adds: i3lock, brightnessctl, libvibrant, xorg.xinit, xorg.xorgserver |

**Why:** MicroVMs forward apps to the host via xpra — they have no local window manager and no physical display. Installing a compositor (picom), screenshot tools (flameshot, scrot), or hardware controls (brightnessctl, libvibrant) would be dead weight. Standalone libvirt VMs run a full i3 desktop via virt-manager and need the WM stack, but still have no physical backlight or lockscreen. Only the host needs those.

The `standalone` option on a VM config is the switch:

```nix
hydrix.graphical.standalone = true;   # libvirt VM with own display → full WM tier
hydrix.graphical.standalone = false;  # microVM via xpra → theming only (default)
```

### Power Management

```nix
{
  hydrix.power = {
    defaultProfile = "balanced";     # "powersave", "balanced", or "performance"
    chargeLimit = null;              # Battery charge limit % (20-100, null = no limit)
  };
}
```

Change at runtime: `power-mode <powersave|balanced|performance>`

ASUS laptops also have `power-profile` which coordinates both the ASUS platform profile (fan curves) and CPU power mode together:

```bash
power-profile quiet        # ASUS Quiet + CPU powersave
power-profile balanced     # ASUS Balanced + CPU balanced
power-profile performance  # ASUS Performance + CPU performance
power-profile status       # Show both profiles
```

#### What Each Mode Does

| Setting | Powersave | Balanced | Performance |
|---------|-----------|----------|-------------|
| **Governor** | `powersave` | dynamic (`auto-cpufreq`) | `performance` |
| **Max Frequency** | 60% cap | 100% | 100% |
| **Turbo Boost** | Disabled | Enabled | Enabled |
| **EPP** | `power` | auto-managed | `performance` |
| **auto-cpufreq** | Stopped | Running | Stopped |

- **Powersave**: Hard-caps CPU at 60% max frequency via `intel_pstate/max_perf_pct`, disables turbo boost, and sets the energy performance preference to `power`. Useful for battery life but can feel sluggish under load since the CPU has no headroom beyond 60%.
- **Balanced**: Lets `auto-cpufreq` dynamically manage the governor and turbo based on load. Full frequency range available.
- **Performance**: Locks governor to `performance`, enables turbo, and sets EPP to `performance`. Maximum speed at the cost of power and thermals.

The polybar PWR module shows the current mode (SAVE/AUTO/PERF) and left-clicking cycles through all three modes.

### Polybar Styles

| Style | Description |
|-------|-------------|
| `unibar` | Classic solid bar with `//` separators |
| `modular` | Transparent background with module backgrounds (default) |
| `pills` | Multiple small rounded floating bars |

### Secrets Management

```nix
{
  hydrix.secrets = {
    enable = true;
    github.enable = true;           # Provision GitHub SSH keys to VMs
  };

  # Per-VM secret provisioning
  hydrix.microvmHost.vms.microdev.secrets.github = true;
}
```

### Disk Configuration (Disko)

```nix
{
  hydrix.disko = {
    enable = true;
    device = "/dev/nvme0n1";
    swapSize = "16G";
    layout = "full-disk-luks";      # or "full-disk-plain", "dual-boot-luks"
  };
}
```

### User Colorschemes

Custom colorschemes in your hydrix-config take priority over framework ones:

```nix
{
  hydrix.userColorschemesDir = ./colorschemes;  # Point to your colorschemes/
}
```

---

## Colorscheme System

Hydrix uses a colorscheme system based on pywal with real-time synchronization between host and VMs.

### Available Colorschemes

Located in `colorschemes/`:
- `hydrix` - Default teal/cyan theme
- `nord` - Nord blue palette
- `nvid` - Nvidia-inspired greens
- `punk` - Pink/purple cyberpunk
- `modgruv` - Gruvbox-inspired warm
- `zero` - Pure black minimal
- `blues`, `dunes`, `nebula`, `perp`, `deeporange`, `mardu`

### Host Commands

| Command | Description |
|---------|-------------|
| `walrgb <image>` | Generate and apply colors from image |
| `randomwal` | Random wallpaper from ~/Pictures/wallpapers |
| `restore-colorscheme` | Revert to configured colorscheme |
| `refresh-colors` | Reload all apps with current colors |
| `save-colorscheme <name>` | Save current colors as new scheme |

### VM Commands

| Command | Description |
|---------|-------------|
| `wal-sync` | Sync colors from host |
| `set-colorscheme-mode <mode>` | Set inheritance mode |
| `get-colorscheme-mode` | Show current mode |

### Colorscheme Inheritance Modes

VMs can inherit colors from the host in three modes:

| Mode | Background | Text Colors | Use Case |
|------|------------|-------------|----------|
| `full` | Host | Host | VM identical to host |
| `dynamic` | Host | VM's own | Visual distinction (default) |
| `none` | VM's own | VM's own | Ignore host theme |

Set in VM config:
```nix
hydrix.colorschemeInheritance = "dynamic";
```

Or at runtime:
```bash
set-colorscheme-mode dynamic
```

### How Colorscheme Sync Works

1. **Host applies colorscheme** via `walrgb`:
   - Extracts colors using pywal
   - Updates Xresources, i3, polybar, dunst, Firefox, GTK
   - Sets RGB lighting (ASUS Aura/OpenRGB)
   - Pushes colors to running VMs via vsock

2. **VMs receive colors** via:
   - **Vsock push** (instant) - Port 14503
   - **9p polling** (2s interval) - Fallback when no vsock

3. **VM applies based on mode**:
   - `full`: Use all host colors
   - `dynamic`: Merge host background with VM text colors
   - `none`: Ignore, use VM's configured scheme

### Apps Updated by Colorscheme

- **i3**: Focused window border color
- **Polybar**: All bar colors
- **Alacritty**: Terminal colors (mixed mode for VMs)
- **Rofi**: Launcher theme
- **Dunst**: Notification colors
- **Firefox**: Via pywalfox extension
- **GTK**: Via wal-gtk
- **Zathura**: PDF viewer
- **RGB Lighting**: ASUS Aura or OpenRGB

---

## VM Theme Sync

The VM theme sync module eliminates per-VM pywal execution (~500ms) by sharing the host's wal cache directly via virtiofs.

### How It Works

```
Host                                    VM
~/.cache/wal/                           ~/.cache/wal -> /mnt/wal-cache (symlink)
  colors.json  ──virtiofs──>            /mnt/wal-cache/colors.json
  sequences                             colors-runtime.toml (generated at boot)
  colors                                alacritty imports colors-runtime.toml

walrgb <image>
  -> generates wal cache
  -> systemd path detects change
  -> sends REFRESH to VMs via vsock     VM receives REFRESH on port 14503
                                          -> regenerates colors-runtime.toml
                                          -> alacritty live-reloads colors
```

### Fast Startup (No Color Flash)

Without theme sync, VMs would show Nord default colors for ~500ms while pywal runs. The module prevents this through:

1. **wal-cache-link service** — creates the symlink to host cache before xpra starts, so colors exist from the first shell
2. **Pre-generated colors-runtime.toml** — built at boot from the shared `colors.json` via jq, available before any terminal launches
3. **Stylix fish target disabled** — the system-level base16 fish theme applied OSC escape sequences on every shell start, overriding config colors. Disabled with `stylix.targets.fish.enable = mkForce false`
4. **xpra-vsock ordering** — xpra only accepts connections after `wal-cache-link` completes, preventing terminals from launching before colors are ready
5. **Conflicting services disabled** — `vm-colorscheme`, `wal-sync` timer, and `init-wal-cache` are all disabled to prevent overwriting the shared cache

### Dynamic Focus Daemon

Per-VM i3 border colors that change based on which VM's window is focused. A Python i3ipc daemon listens for focus events and updates the border color.

**Modes:**

| Mode | Color Source | Use Case |
|------|-------------|----------|
| `static` | VM profile's colorscheme JSON (color4) | Fixed colors per VM type |
| `dynamic` | Host's live wal cache (configurable color key) | Colors shift with wallpaper |

**Default dynamic color map:**

| VM Type | Color Key | Typical Result |
|---------|-----------|----------------|
| pentest | color1 | Red tones |
| browsing | color2 | Green tones |
| comms | color3 | Yellow tones |
| dev | color5 | Magenta tones |
| lurking | color6 | Cyan tones |
| host | color4 | Blue tones (reserved) |

**Configuration:**

```nix
hydrix.vmThemeSync = {
  enable = true;
  focusDaemon.mode = "dynamic";    # or "static"
  dynamicColorMap = {               # Override default mapping
    pentest = "color1";
    browsing = "color2";
  };
};
```

**Detection:** Windows are identified by title prefix `[<vmtype>]` (e.g., `[browsing] firefox`).

### Enabling

In your machine config:
```nix
hydrix.vmThemeSync.enable = true;
hydrix.vmThemeSync.focusDaemon.mode = "dynamic";
```

In your flake, import `vmThemeSyncModule` for both host and all VMs.

### Focus Override Colors

A third color mode activated at runtime via the `hydrix-focus` CLI:

| Command | Effect |
|---------|--------|
| `hydrix-focus on` | Enable per-VM override colors |
| `hydrix-focus off` | Disable, revert to static/dynamic mode |
| `hydrix-focus toggle` | Toggle override on/off (default action) |
| `hydrix-focus status` | Show current state |

**Per-VM colors** are set in profile configs:

```nix
# profiles/pentest/default.nix
hydrix.vmThemeSync.focusOverrideColor = "#FF5555";
```

When override mode is active (`hydrix-focus on`), the focus daemon reads `focusOverrideColor` from each VM's profile file instead of using the static/dynamic color pipeline. This gives you fixed, hand-picked colors per VM type regardless of wallpaper or colorscheme.

**Marker file:** `~/.cache/hydrix/focus-override-active` — the daemon watches for this via SIGUSR1.

### Wal Cache Pre-population

The `wal-cache-init` service runs on first boot to ensure VMs have colors immediately:

1. Checks if `~/.cache/wal/colors.json` exists — skips if already populated
2. If `graphical.wallpaper` is set, runs `wal -q -i <wallpaper>` to generate cache
3. Otherwise, falls back to the configured `colorscheme` JSON file

This solves the cold-start problem where VMs mount an empty virtiofs share on first boot (host has no wal cache yet), resulting in terminals with no colors until the user runs `walrgb`.

---

## Font System

Fonts are configured via `hydrix.graphical.font` and flow through two separate pipelines for host and VMs.

### Configuration

```nix
{
  hydrix.graphical.font = {
    family = "Iosevka";              # Global font family
    size = 10;                        # Base size at 96 DPI
    relations = {                     # Per-app size multipliers
      alacritty = 1.0;
      polybar = 1.0;
      rofi = 1.2;
      dunst = 0.9;
    };
    familyOverrides = {               # Per-app font family override
      polybar = "Tamzen";             # Use different font for polybar
    };
  };
}
```

### Host Font Pipeline

On the host, `alacritty-dpi` launches terminals with DPI-aware font settings:

1. `dynamic-scaling` detects monitor DPI and writes `~/.config/hydrix/scaling.json`
2. `scaling.json` contains calculated font sizes (fractional, e.g. 10.5) and the font family
3. `alacritty-dpi` reads `scaling.json` at launch time and passes `-o font.size=X -o font.normal.family=Y`
4. This overrides `alacritty.toml` (which has static build-time values from Stylix)

The `scaling.json` font_name is patched by a system activation script on every `rebuild`, so it always reflects the current config even before a display event triggers `dynamic-scaling`.

### VM Font Pipeline

VMs use their own `alacritty.toml` directly — no wrapper overrides:

1. Stylix generates `alacritty.toml` with font family and size from `hydrix.graphical.font`
2. The VM's xpra session sets `WINIT_X11_SCALE_FACTOR=1` globally
3. When launched via xpra (`microvm app` / `ws-app`), plain `alacritty` runs inside the VM
4. Alacritty reads its own config with the correct font

### Updating Fonts

| Action | Host | VMs |
|--------|------|-----|
| Change `font.family` | `rebuild` | `rebuild` + `microvm update <vm>` |
| Change `font.size` | `rebuild` (scaling.json updates) | `rebuild` + `microvm update <vm>` |
| DPI change (new monitor) | Automatic via `dynamic-scaling` | N/A (xpra handles display) |

Font packages must be included in the VM's closure. Add them to `vmPackages` in your font config:

```nix
vmPackages = with pkgs; [ iosevka tamzen scientifica gohufont ];
```

### Live Switch (microvm update)

`microvm update` performs a live config switch that includes home-manager activation. This means font changes in `alacritty.toml` are applied without VM restart. The host dumps nix store registration info to the VM before switching so home-manager can realise new store paths.

New terminal windows pick up the updated font. Already-running terminals keep their current font (alacritty inotify doesn't detect nix store symlink changes).

---

## MicroVM Management

### Commands

```bash
# Lifecycle
microvm build <name>       # Build/rebuild VM image
microvm start <name>       # Start VM (waits for xpra ready)
microvm stop <name>        # Stop VM
microvm restart <name>     # Restart VM

# Applications
microvm app <name> <cmd>   # Launch app (e.g., microvm app microbrowse firefox)
microvm attach <name>      # Attach to xpra session
microvm console <name>     # Serial console (headless VMs)

# Status
microvm status [name]      # Show status
microvm list               # List all VMs
microvm logs <name>        # View logs

# Data Management
microvm snapshot create <name> <snap>  # Create snapshot
microvm snapshot list <name>           # List snapshots
microvm snapshot revert <name> <snap>  # Revert to snapshot
microvm purge <name>                   # Delete all data (fresh start)
```

### Profile VMs

Declared in `hydrix-config/profiles/<name>/meta.nix`, auto-discovered by the flake, tracked in `/etc/hydrix/vm-registry.json`. All values are user-configurable.

**Convention: CID = subnet last octet = workspace.**

| Name | CID | WS | Bridge | Subnet | Persistence |
|------|-----|----|--------|--------|-------------|
| `microvm-pentest` | 102 | 2 | br-pentest | 192.168.102 | persistent |
| `microvm-browsing` | 103 | 3 | br-browse | 192.168.103 | 10GB home |
| `microvm-comms` | 104 | 4 | br-comms | 192.168.104 | Ephemeral |
| `microvm-dev` | 105 | 5 | br-dev | 192.168.105 | 50GB + 20GB docker |
| `microvm-lurking` | 106 | 6 | br-lurking | 192.168.106 | Ephemeral |

Custom profiles start at CID 107+. Use `new-profile <name>` to scaffold one.

### Infrastructure VMs

Fixed CIDs defined in Hydrix framework modules. **Not user-configurable**, not in `profiles/`, not in the vm-registry. Do not assign these CIDs to profile VMs.

| Name | CID | Purpose |
|------|-----|---------|
| `microvm-files` | 212 | Encrypted inter-VM file transfer |
| `microvm-router` | 200 | WiFi VFIO passthrough |
| `microvm-builder` | 210 | Lockdown-mode nix builds |
| `microvm-gitsync` | 211 | Lockdown-mode git push/pull |

### TUI Launcher

```bash
hydrix-tui              # Interactive TUI for VM management
# Or press Mod+m for rofi launcher
```

The TUI's MicroVM menu includes task pentest slots. Task slots display their active engagement name and offer a **Snapshots** sub-menu when stopped.

### Task Pentest VMs (per-engagement)

For work that benefits from isolation per target or engagement, Hydrix supports **task slots**: a fixed pool of pre-declared pentest VMs that can be assigned to named engagements without a host rebuild.

**How it works:**
- Three task slots (`microvm-pentest-task1/2/3`, CIDs 115–117) are declared permanently in the host config via `hydrix-config/tasks/task*.nix`
- Service units, TAP interfaces, and bridges are created once during the initial rebuild
- `microvm pentest create <name>` assigns an engagement to a free slot and builds its closure — no rebuild needed

**One-time setup** (done during any normal rebuild window):

```bash
# Add tasks/task1.nix, task2.nix, task3.nix to your hydrix-config
# See hydrix-config/tasks/ for the slot configs
rebuild    # Registers the slot service units permanently
```

**Engagement workflow:**

```bash
# Start a new engagement
microvm pentest create google           # Assign 'google' to a free slot
microvm start microvm-pentest-task1     # Service unit already exists
microvm snapshot create microvm-pentest-task1 google-clean  # Baseline
microvm app microvm-pentest-task1 alacritty

# Between sessions (revert to known-good state)
microvm stop microvm-pentest-task1
microvm snapshot revert microvm-pentest-task1 google-clean
microvm start microvm-pentest-task1

# Close engagement (volume and snapshots preserved, slot freed)
microvm pentest close google

# Reopen from snapshot
microvm pentest create google --slot 1
microvm snapshot revert microvm-pentest-task1 google-clean
microvm start microvm-pentest-task1

# Purge all data for an engagement
microvm pentest purge google

# View all slots and their status
microvm pentest list
```

**Task slot table:**

| Slot | CID | TAP | Bridge |
|------|-----|-----|--------|
| `microvm-pentest-task1` | 115 | `mv-task-1` | `br-pentest` |
| `microvm-pentest-task2` | 116 | `mv-task-2` | `br-pentest` |
| `microvm-pentest-task3` | 117 | `mv-task-3` | `br-pentest` |

**Adding more slots:** Create `tasks/task4.nix` with CID 118 and `tapId = "mv-task-4"`, then rebuild once. The `microvm pentest` command will discover it automatically.

**Engagement registry:** `hydrix-config/tasks/.engagement-registry` is a JSON file mapping slot names to engagement names. Commit it to track which slot held which engagement.

**When libvirt is better:**
- Engagement needs elastic disk beyond the fixed qcow2 max size
- Lab environment (Windows, Active Directory, multi-machine networks)
- RAM snapshots (suspended mid-session state)

### Files VM (Encrypted Inter-VM Transfer)

The files VM (`microvm-files`, CID 106, fixed infra) is an encrypted jump host for moving files between VMs. It has direct L2 TAP connections to each bridge you grant it access to, so it can reach VMs without going through the router. Source and destination IPs are derived at runtime from the VM registry (`subnet + .10`).

**Security model:**

- File content is **always encrypted** (AES-256-CBC via openssl) before it leaves the source VM
- A random passphrase is generated fresh per transfer on the host and held only in host memory
- The passphrase travels **exclusively via vsock** — it never touches a bridge network
- SHA-256 is verified at every hop; the passphrase is only released to the destination after all checksums match
- Source files are never modified or moved — the original path is always preserved
- The files VM receives only ciphertext during transfer operations (it sees plaintext only during `store`, where it decrypts into its own `/storage`)
- Port 8888 on each VM only accepts connections from the files VM's IP (`.2` on that bridge) — enforced by iptables on each VM

**Transfer flow** (`microvm files transfer pentest/projects/report comms/pentest/`):

```
1. Host generates PASSPHRASE (openssl rand -base64 32) — stays in host memory

2. Host → pentest VM (vsock 14506): ENCRYPT <passphrase> projects/report
   Pentest VM: tar czf - | openssl enc -aes-256-cbc → ~/shared/xfer.enc
   Returns: SHA256=<hash>

3. Host → pentest VM (vsock 14506): SERVE
   Pentest VM starts ephemeral HTTP server on port 8888

4. Host → files VM (vsock 14505): FETCH <pentest-subnet>.10 xfer.enc
   Files VM downloads ciphertext via HTTP  (IP from vm-registry.json)
   Returns: SHA256=<hash>  ← host verifies both hashes match

5. Host → pentest VM (vsock 14506): SERVE_STOP

6. Host → comms VM (vsock 14506): RECEIVE_PREPARE
   Comms VM starts one-shot HTTP upload server on port 8888 (always receives to ~/shared/)

7. Host → files VM (vsock 14505): DELIVER <comms-subnet>.10 xfer.enc
   Files VM HTTP PUTs ciphertext to comms VM  (IP from vm-registry.json)
   Returns: SHA256=<hash>  ← host verifies three-way match

8. Host → comms VM (vsock 14506): DECRYPT <passphrase> shared/xfer.enc pentest/
   Comms VM decrypts + unpacks → ~/pentest/report/, deletes shared/xfer.enc
   Returns: OK

9. Host → pentest VM (vsock 14506): CLEANUP  (deletes ~/shared/xfer.enc)
   Host discards passphrase from memory
```

**Store flow** (`microvm files store pentest/projects/report`):

Steps 1–4 are identical. After the files VM has the ciphertext, the host sends the passphrase via vsock and the files VM decrypts in-place into `/storage/pentest/`. Ciphertext is deleted after successful decryption.

**Setup** in `flake.nix`:

```nix
"microvm-files" = hydrix.lib.mkMicrovmFiles {
  # Bridges the files VM gets direct TAP access to.
  # Only listed VMs can exchange files with each other via this VM.
  accessFrom = [ "pentest" "browsing" "dev" "comms" ];
};
```

Enable in your machine config:

```nix
hydrix.microvmHost.vms."microvm-files".enable = true;
hydrix.microvmFiles.enable = true;
```

**Commands:**

```bash
# Move files between VMs (source files untouched)
microvm files transfer pentest/projects/report comms/pentest/
microvm files transfer dev/src/tool pentest/tools/

# Archive to files VM /storage/ (encrypted, then decrypted in-place)
microvm files store pentest/projects/report

# List stored files
microvm files list
microvm files list pentest
```

**Network layout:**

```
Host (passphrase, orchestration)
 │  vsock 14505 → files VM (CID 106)
 │  vsock 14506 → any regular VM (ENCRYPT/DECRYPT/SERVE/CLEANUP)
 │
Files VM (192.168.108.10 on br-files)
 ├── mv-files-pent → br-pentest  (192.168.101.2)  [if "pentest" in accessFrom]
 ├── mv-files-brow → br-browse   (192.168.103.2)  [if "browsing" in accessFrom]
 ├── mv-files-dev  → br-dev      (192.168.104.2)  [if "dev" in accessFrom]
 ├── mv-files-comm → br-comms    (192.168.102.2)  [if "comms" in accessFrom]
 ├── mv-files-lurk → br-lurking  (192.168.107.2)  [if "lurking" in accessFrom]
 └── mv-files      → br-files    (192.168.108.10) [always]

Regular VMs: static .10 IPs on their bridge
 port 8888: ephemeral HTTP (SERVE or RECEIVE_PREPARE), files VM IP only
 vsock 14506: vm-files-agent (receives host commands)
```

**What the files VM stores** (`/storage/` persistent qcow2, 50GB default):

```
/storage/
├── pentest/    # Files stored from pentest VM
├── comms/      # Files stored from comms VM
├── dev/        # Files stored from dev VM
└── tmp/        # In-transit blobs (cleaned after each operation)
```

**TAP/subnet/CID assignments:**

| Item | Value |
|------|-------|
| Bridge | `br-files` |
| Subnet | `192.168.108.0/24` |
| Files VM IP | `192.168.108.10` |
| Files VM per-bridge IP | `192.168.1xx.2` |
| Router leg | `192.168.108.253` |
| vsock CID | `212` |
| Home TAP | `mv-files` → `br-files` |
| Router TAP | `mv-router-file` → `br-files` |

### In-VM Development (vm-dev workflow)

Test packages without nixos-rebuild using per-package flakes:

```bash
# === Inside VM ===
vm-dev build https://github.com/owner/repo   # Create flake from GitHub
vm-dev run repo                               # Test it works
vm-dev fix repo                               # Analyze build errors, suggest fixes
vm-dev list                                   # List local packages
vm-sync push --name repo                      # Stage for host integration

# === On host ===
vm-sync list                                  # List staged packages from running VMs
vm-sync pull repo --target pentest            # Pull to profiles/pentest/packages/
vm-sync status                                # Show packages per profile
microvm build microhack                       # Rebuild VM with new package
```

**Package locations:**
- VM development: `~/dev/packages/<name>/flake.nix`
- VM staging: `~/staging/<name>/package.nix`
- Host profiles: `~/hydrix-config/profiles/<type>/packages/<name>.nix`

The `vm-sync pull` command automatically:
1. Copies package to your user config's profile
2. Regenerates `packages/default.nix`
3. Stages for git tracking

### Live Switch (microvm update)

`microvm update` builds a new VM config and applies it without restart. 

**How it works:**

1. **Host builds** new VM system closure via `nix build`
2. **Host dumps nix DB registration** for the new closure's store paths to `/var/lib/microvms/<vm>/config/.switch-reg`
3. **Host sends** `SWITCH /nix/store/...` to VM via vsock port 14504
4. **VM loads registration** via `nix-store --load-db` so its local DB knows about host-built paths
5. **VM runs** `switch-to-configuration switch` with full home-manager activation
6. **Result:** new systemd services start, alacritty.toml updates, etc.

**When to use restart instead:**
- Kernel or initrd changes
- New qcow2 volumes added
- Microvm runner configuration changes (memory, CPU, shares)

---

## Vsock Communication

All host-VM communication uses virtio-vsock. No SSH or network access to VMs. Each VM has a unique CID (Context ID).

### Port Assignments

| Port | Service | Direction | Purpose |
|------|---------|-----------|---------|
| 14500 | xpra-vsock | Host → VM | GUI app forwarding and display |
| 14501 | vm-metrics | Host → VM | Poll CPU, RAM, disk, uptime |
| 14502 | vm-staging | Host → VM | List/pull staged packages (vm-sync) |
| 14503 | vm-colorscheme | Host → VM | Push colorscheme updates (REFRESH) |
| 14504 | vm-switch | Host → VM | Live NixOS config switch (SWITCH/TEST/STATUS/PING) |
| 14505 | files-agent | Host → Files VM | File transfer ops (FETCH/DELIVER/STORE/LIST) |
| 14506 | vm-files-agent | Host → any VM | Per-VM file ops (ENCRYPT/DECRYPT/SERVE/CLEANUP) |
| 14510 | builder-build | Host → Builder | Send build commands |
| 14511 | builder-status | Host → Builder | Query builder status |

### Protocol

All services use raw TCP-like streams over vsock. Messages are line-oriented text. The host uses `vsock-cmd` (a small Python helper installed by the framework) for reliable communication:

```bash
# vsock-cmd <cid> <port> [connect-timeout-seconds]
# Reads command from stdin, writes response to stdout.

# Query VM metrics
echo "cpu" | vsock-cmd 101 14501

# Trigger color refresh
echo "REFRESH" | vsock-cmd 101 14503

# Live switch (longer connect timeout for slow VMs)
echo "SWITCH /nix/store/..." | vsock-cmd 101 14504 30

# Query switch status
echo "STATUS" | vsock-cmd 101 14504
```

`vsock-cmd` uses `AF_VSOCK` sockets directly (no socat). It sends one newline-terminated command, then reads until the connection closes — which happens naturally when the per-connection handler exits on the VM side.

---

## VM Store Sharing

VMs share the host's `/nix/store` via virtiofs with a writable overlay, avoiding multi-gigabyte per-VM stores.

### Architecture

```
Host /nix/store (read-only virtiofs)
         |
         v
VM /nix/.ro-store  ─────────┐
                            ├── overlayfs ──> VM /nix/store
VM /nix/.rw-store (qcow2) ──┘
```

- **Lower layer:** `/nix/.ro-store` — host's store via virtiofs (read-only, high performance)
- **Upper layer:** `/nix/.rw-store` — thin-provisioned qcow2 (starts near 0, grows as VM builds packages)
- **Merged:** `/nix/store` — VM sees all host paths plus its own builds

### Filesystem Shares

| Tag | Source (Host) | Mount (VM) | Protocol | Purpose |
|-----|---------------|------------|----------|---------|
| `nix-store` | `/nix/store` | `/nix/.ro-store` | virtiofs | Shared nix store (read-only base) |
| `vm-config` | `/var/lib/microvms/<vm>/config` | `/mnt/vm-config` | 9p | VM config, live switch registration |
| `hydrix-config` | `~/.config/hydrix` | `/mnt/hydrix-config` | 9p | Host config (scaling.json for DPI) |
| `vm-secrets` | `/run/hydrix-secrets/<vm>` | `/mnt/vm-secrets` | virtiofs | GitHub SSH keys |

### Nix DB Registration

Paths exist in the VM's `/nix/store` via virtiofs but the VM's local nix database (`/nix/var/nix/db/db.sqlite`) doesn't know about them. This matters during `microvm update` — home-manager's `nix-store --realise` queries the local DB. The host dumps registration info before switching, and the VM loads it with `nix-store --load-db`.

---

## Build System

### Host Rebuild

```bash
# Standard rebuild (auto-detects specialisation)
rebuild

# Force specific specialisation
rebuild lockdown
rebuild administrative
rebuild fallback

# Options
rebuild -u              # Update flake inputs first
rebuild -p              # Pre-build VM configs after
rebuild -m              # Pre-build microVM runners
rebuild -v              # Verbose output

# Backwards-compat alias
nixbuild                # Same as rebuild
```

### Builder VM (Lockdown Mode)

When the host has no internet (lockdown mode), use the builder VM to fetch packages:

```bash
# Full workflow: start builder -> build -> stop -> build on host
microvm builder build browsing
microvm builder build host

# Manual control
microvm builder start       # Stops host nix-daemon
microvm builder fetch <target>
microvm builder stop        # Restarts host nix-daemon
microvm builder status
microvm builder shell       # Console access
```

**Named targets**:
- `browsing`, `pentest`, `dev`, `comms`, `lurking` - MicroVMs
- `router` - Router VM
- `host` - Host system
- `.#path` - Raw flake paths

**How it works**:
1. Host nix-daemon stops (required for SQLite locking)
2. /nix/store remounted read-write
3. Builder VM starts with virtiofs access to /nix/store
4. Builder fetches dependencies via router VM (has internet)
5. Build outputs written directly to host's /nix/store
6. Builder stops, store remounted read-only
7. Host nix-daemon restarts
8. Host build is instant (all deps cached)

### Libvirt VMs

```bash
# Build base images (one-time, ~9 min per type)
build-base --type browsing
build-base --type pentest --type dev
build-base --all

# Deploy VM instances (instant, ~5 seconds)
deploy-vm --type browsing --name personal --user myuser
deploy-vm --type pentest --name htb --vcpus 8 --memory 16384
deploy-vm --type dev --name work --encrypt    # LUKS encrypted
```

---

## Shell

Fish shell with babelfish for fast environment variable sourcing.

### Babelfish

NixOS modules often source bash scripts to set environment variables (e.g., `/etc/profile`). Fish needs to translate these. Two approaches:

| Method | How | Speed |
|--------|-----|-------|
| `foreign-env` | Spawns bash, diffs environment (~6 calls) | ~170ms |
| `babelfish` | Compiled Go binary, translates syntax directly | ~1ms |

Babelfish is enabled globally via `programs.fish.useBabelfish = true` in the fish module. This applies to both host and VMs.

### Prompt

Starship prompt with git status, directory, command duration. Configured per-host via Hydrix options.

### Navigation

Zoxide for frecency-based `cd` (`z <partial-path>`). Initialized in fish config.

---

## Workspace Integration

Workspaces are mapped to VMs via the `ws-app` script. Pressing `Super+Return` launches a terminal in the correct context — host or VM — based on the focused workspace.

### Workspace Mapping

| Workspace | Target | Behavior |
|-----------|--------|----------|
| WS1 | Host | Always host terminal |
| WS2 | Pentest VM | Active VM tracking |
| WS3 | Browsing VM | Active VM tracking |
| WS4 | Comms VM | Fixed (microvm-comms) |
| WS5 | Dev VM | Active VM tracking |
| WS6-9 | Host | Always host terminal |
| WS10 | Router | Serial console |

### Active VM Tracking

For workspace types that support multiple VMs (pentest, browsing, dev), `ws-app` remembers your last-used VM in `~/.cache/hydrix/active-vms.json`. If the active VM is stopped, it auto-selects the next running VM of that type or falls back to the host.

### Launch Flow

```
Super+Return
  -> ws-app alacritty
  -> detect focused workspace (i3-msg)
  -> map workspace to VM type
  -> if VM workspace:
       -> get active VM for type (or show rofi menu)
       -> xpra control vsock://<CID>:14500 start -- alacritty
       -> auto-attach xpra if not attached
  -> if host workspace:
       -> alacritty-dpi (DPI-aware host terminal)
```

`Super+Shift+Return` always opens a host terminal regardless of workspace.

---

## Lockscreen

The lockscreen uses i3lock-color with pywal integration:

- **Activation**: `Mod+Shift+e` or `hydrix-lock`
- **Auto-lock**: Configurable idle timeout (default 600 seconds)
- **Features**:
  - Screenshot with pixelation blur
  - Clock display with pywal colors
  - Custom text overlays

### Configuration

```nix
hydrix.graphical.lockscreen = {
  idleTimeout = 600;               # null to disable auto-lock
  font = "CozetteVector";
  fontSize = 143;
  clockSize = 104;
  text = "Enter password";
  wrongText = "Ah ah ah! You didn't say the magic word!!";
  verifyText = "Verifying...";
  blur = true;
};
```

---

## Keybindings

### Window Management

| Key | Action |
|-----|--------|
| `Mod+Return` | Terminal (workspace-aware) |
| `Mod+Shift+Return` | Terminal (always on host) |
| `Mod+s` | Floating terminal |
| `Mod+q` | Kill window |
| `Mod+f` | Fullscreen |
| `Mod+Shift+space` | Toggle floating |
| `Mod+h/j/k/l` | Focus direction |
| `Mod+Shift+h/j/k/l` | Move window |
| `Mod+c` | Split vertical |
| `Mod+v` | Split horizontal |
| `Mod+1-0` | Switch workspace |
| `Mod+Shift+1-0` | Move to workspace |
| `Mod+Shift+arrows` | Adjust gaps |

### Applications

| Key | Action |
|-----|--------|
| `Mod+d` | Launcher (workspace-aware: host rofi or VM app menu) |
| `Mod+b` | Firefox |
| `Mod+o` | Obsidian |
| `Mod+Shift+f` | File manager (joshuto) |
| `Mod+Shift+m` | VM app launcher (vm-launch) |
| `Mod+z` | Zathura (PDF viewer) |
| `Mod+m` | Hydrix TUI |

### System

| Key | Action |
|-----|--------|
| `Mod+Shift+e` | Lock screen |
| `Mod+Shift+s` | Suspend |
| `Mod+Shift+v` | Reload display config |
| `Mod+w` | Random wallpaper |
| `Mod+F1/F2/F3` | Volume down/up/mute |
| `Mod+F5/F6` | Color temperature down/up |
| `Mod+F7/F8` | Brightness down/up |
| `Mod+F12` | Screenshot |

### Configuration Editing

| Key | Action |
|-----|--------|
| `Mod+Shift+i` | Edit i3 config |
| `Mod+Shift+p` | Edit polybar config |
| `Mod+Shift+n` | Edit nix machine config |

---

## Scripts Reference

All scripts are wrapped via Nix and available in PATH after installation.

### Build & System

| Command | Purpose |
|---------|---------|
| `rebuild [mode]` | Rebuild host system (lockdown/administrative/fallback) |
| `nixbuild [mode]` | Alias for `rebuild` (backwards compat) |
| `build-base --type <t>` | Build libvirt base image |
| `deploy-vm --type <t>` | Deploy libvirt VM instance |
| `rebuild-libvirt-router` | Rebuild libvirt router (if enabled) |

### Mode Switching

| Command | Purpose |
|---------|---------|
| `hydrix-switch <mode>` | Live switch between lockdown/administrative/fallback |
| `hydrix-mode` | Show current mode and available modes |
| `router-status` | Show router VM and bridge status |

### MicroVM

| Command | Purpose |
|---------|---------|
| `microvm <cmd>` | MicroVM management CLI |
| `microvm build <name>` | Build/rebuild VM |
| `microvm start <name>` | Start VM (waits for xpra) |
| `microvm app <name> <cmd>` | Launch app in VM |
| `microvm stop <name>` | Stop VM |

### Package Sync (vm-dev workflow)

| Command | Purpose |
|---------|---------|
| `vm-sync list` | List staged packages from running VMs |
| `vm-sync pull <pkg> --target <type>` | Pull to profile packages |
| `vm-sync status` | Show packages per profile |
| `vm-sync-tui` | Interactive package sync TUI |

### Colorscheme

| Command | Purpose |
|---------|---------|
| `walrgb <image>` | Apply colorscheme from image |
| `randomwal` | Random wallpaper colorscheme |
| `restore-colorscheme` | Revert to configured scheme |
| `refresh-colors` | Reload all apps |
| `save-colorscheme <name>` | Save current as scheme |

### VPN

| Command | Purpose |
|---------|---------|
| `vpn-assign <vm> <exit>` | Assign Mullvad exit node to VM bridge |
| `vpn-status` | Show VPN status for all bridges |

### Power

| Command | Purpose |
|---------|---------|
| `power-mode <profile>` | Switch power profile (powersave/balanced/performance) |

### Utilities

| Command | Purpose |
|---------|---------|
| `hydrix-tui` | Unified VM management TUI |
| `hydrix-lock` | Activate lockscreen |
| `vm-status` | Show system status (bridges, VMs, etc.) |
| `display-setup` | Reconfigure displays/polybar |
---

## Troubleshooting

### MicroVM Won't Start

```bash
# Check logs
microvm logs <name>

# Verify vsock CID is unique
microvm list

# Ensure host modules are loaded
lsmod | grep vhost_vsock
```

### No Display in VM

```bash
# Check xpra status
xpra info vsock://<CID>:14500

# Re-attach manually
microvm attach <name>
```

### WiFi Not Working in Router

```bash
# Verify VFIO passthrough
lspci -nnk | grep -A3 Wireless

# Check router console
microvm console microrouter

# Verify NetworkManager
nmcli device status
```

### Host Has No Internet (Expected in Lockdown)

This is the intended behavior. Use the builder VM:

```bash
microvm builder build <target>
```

Or switch to administrative mode:

```bash
rebuild administrative
# Or live switch without rebuild:
hydrix-switch administrative
```

### Colors Not Syncing to VM

```bash
# In VM - check mode
get-colorscheme-mode

# Force sync
wal-sync

# Check host colors are active
ls ~/.cache/wal/.active
```

### Display Scaling Issues

```bash
# Recalculate and apply
display-setup

# Adjust resolution step
display-setup --step -1   # Higher resolution
display-setup --step +1   # Lower resolution

# Check current values
cat ~/.config/hydrix/scaling.json
```

---

## Key Files

### User Configuration

| File | Purpose |
|------|---------|
| `~/hydrix-config/machines/<host>.nix` | Your machine configuration |
| `~/hydrix-config/profiles/<type>/` | Your VM profile customizations |
| `~/hydrix-config/profiles/<type>/packages/` | Custom packages (via vm-sync) |
| `~/hydrix-config/colorschemes/` | Custom colorschemes (override framework) |
| `~/hydrix-config/flake.nix` | Main flake (imports Hydrix) |

### Runtime State

| File | Purpose |
|------|---------|
| `~/.config/hydrix/scaling.json` | DPI scaling, font sizes, font family |
| `~/.config/alacritty/colors-runtime.toml` | VM runtime colors (imported by alacritty) |
| `~/.cache/wal/colors.json` | Active pywal colors |
| `~/.cache/wal/.active` | Marker that wal colors are active |
| `~/.cache/wal/.colorscheme-mode` | VM colorscheme inheritance mode |
| `~/.cache/hydrix/active-vms.json` | Workspace-VM tracking (ws-app) |
| `/var/lib/microvms/<name>/` | MicroVM persistent data |
| `/var/lib/microvms/<name>/config/.switch-reg` | Nix DB registration for live switch |
| `/var/lib/libvirt/base-images/` | Libvirt base images |
| `/etc/HYDRIX_MODE` | Current boot mode (lockdown/administrative/fallback) |

---

## Related Documentation

- [secrets/README.md](./secrets/README.md) - Secrets management setup

---

## License

MIT License - See LICENSE file for details.
