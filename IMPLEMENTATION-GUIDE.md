# Hydrix Implementation Guide - Critical Reference for Development

**Date Created**: 2025-11-27
**Purpose**: Comprehensive guide to properly implement Hydrix by learning from working systems
**Status**: ACTIVE - Read this FIRST before making ANY changes to Hydrix

---

## ⚠️ CRITICAL PROBLEM THAT OCCURRED

### What Broke
A `nixos-rebuild` was attempted that **broke the system** because the Hydrix flake imported a generated configuration WITHOUT properly understanding the existing working setup.

### Root Cause
**Assumptions were made instead of learning from the working system.**

Specifically:
1. `Hydrix/profiles/machines/zephyrus.nix` (line 10) imported:
   ```nix
   imports = [
     /home/traum/dotfiles/modules/zephyrusconf.nix
   ];
   ```

2. **Problem**: This file is **COMMENTED OUT** in the working dotfiles flake (line 103)
3. **Problem**: This creates a hard dependency on dotfiles, breaking Hydrix's standalone nature
4. **Problem**: It imports a file that the working system doesn't even use

### The Lesson
**NEVER assume. ALWAYS read and understand the working configuration first.**

---

## 📋 MANDATORY APPROACH

Before implementing ANYTHING in Hydrix, follow this process:

### Phase 1: LEARN - Analyze Working Systems

1. **Read dotfiles flake.nix** - Understand the actual module imports
2. **Read each imported module** - Understand what they do
3. **Identify the pattern** - How are things structured?
4. **Document dependencies** - What depends on what?
5. **Read splix setup** - Understand the router/VM automation approach
6. **Compare and contrast** - What's different between machines?

### Phase 2: UNDERSTAND - Map the Architecture

1. **Hardware configuration** - How is it handled?
2. **Machine-specific configs** - What makes each machine unique?
3. **Shared modules** - What's common across all machines?
4. **Specializations** - How are different modes handled?
5. **Bootstrap process** - How does a machine get configured?

### Phase 3: DESIGN - Plan Hydrix Structure

1. **Standalone requirement** - No dependencies on dotfiles or splix
2. **Template-driven** - Reproducible across machines
3. **Modular** - Clean separation of concerns
4. **Self-contained** - Everything needed is in Hydrix

### Phase 4: IMPLEMENT - Build Carefully

1. **Start minimal** - Get basic system booting first
2. **Add incrementally** - One module at a time
3. **Test frequently** - Verify each addition works
4. **Document changes** - Update this guide with learnings

---

## 🔍 WORKING DOTFILES ANALYSIS

### Dotfiles Repository Structure

```
~/dotfiles/
├── flake.nix                    # Main flake defining all configurations
├── modules/
│   ├── configuration.nix        # Base system config (all machines)
│   ├── hwconf.nix              # Hardware config wrapper (imports /etc/nixos/hardware-configuration.nix)
│   ├── zephyrus.nix            # Zephyrus-specific config
│   ├── zenbook.nix             # Zenbook-specific config
│   ├── razer.nix               # Razer-specific config
│   ├── i3.nix                  # i3 window manager
│   ├── packages.nix            # System packages
│   ├── services.nix            # System services
│   ├── users.nix               # User configuration
│   ├── colors.nix              # Color schemes
│   ├── virt.nix                # Virtualization
│   ├── audio.nix               # Audio configuration
│   ├── scripts.nix             # System scripts
│   └── router-generated/       # Generated router configs
│       └── zephyrus-consolidated.nix
```

### Zephyrus Configuration (Working Setup)

**File**: `/home/traum/dotfiles/flake.nix` (lines 86-123)

```nix
zephyrus = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
        { nixpkgs.config.allowUnfree = true; }
        { nixpkgs.overlays = [ overlay-unstable ]; }
        inputs.nix-index-database.nixosModules.nix-index

        # Base system configuration
        ./modules/configuration.nix
        ./modules/hwconf.nix

        # Device specific configurations
        ./modules/zephyrus.nix
        #./modules/zephyrusconf.nix    # ← COMMENTED OUT - NOT USED!

        # Core functionality modules
        ./modules/i3.nix
        ./modules/packages.nix
        ./modules/services.nix
        ./modules/users.nix
        ./modules/colors.nix
        #./modules/hosts.nix
        ./modules/virt.nix
        #./modules/scripts.nix
        ./modules/audio.nix

        # Additional feature modules (all commented out)
        #./modules/pentesting.nix
        #./modules/proxychains.nix
        #./modules/dev.nix
        #./modules/steam.nix
    ];
};
```

**Key Observations**:
1. Uses `./modules/hwconf.nix` (NOT `./modules/zephyrusconf.nix`)
2. Many modules are commented out (minimal setup)
3. `scripts.nix` is commented out
4. `hosts.nix` is commented out

### Zenbook Configuration (Working Setup)

**File**: `/home/traum/dotfiles/flake.nix` (lines 126-175)

```nix
zenbook = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
        { nixpkgs.config.allowUnfree = true; }
        { nixpkgs.overlays = [ overlay-unstable ]; }
        inputs.nix-index-database.nixosModules.nix-index

        # Base system configuration
        ./modules/configuration.nix
        ./modules/hwconf.nix

        # Device specific configurations
        ./modules/zenbook.nix
        ./modules/i3.nix
        ./modules/monitor-hotplug.nix

        # Core functionality modules
        ./modules/packages.nix
        ./modules/services.nix
        ./modules/users.nix
        ./modules/colors.nix
        #./modules/hosts.nix         # ← COMMENTED OUT
        ./modules/virt.nix
        ./modules/scripts.nix        # ← ENABLED (unlike zephyrus)

        # Additional feature modules
        #./modules/pentesting.nix
        #./modules/proxychains.nix
        #./modules/dev.nix
        ./modules/steam.nix          # ← ENABLED (unlike zephyrus)
        #./modules/gaming.nix
        ./modules/audio.nix
        ./modules/firefox.nix
    ];
};
```

**Key Observations**:
1. Same base structure as zephyrus
2. Uses `./modules/hwconf.nix` (standard across all machines)
3. Has `monitor-hotplug.nix` (zenbook-specific)
4. Has `scripts.nix` enabled (zephyrus doesn't)
5. Has `steam.nix` and `firefox.nix` enabled

### Hardware Configuration Pattern

**File**: `/home/traum/dotfiles/modules/hwconf.nix`

```nix
{ config, lib, pkgs, ... }:

let
  # Find the ESP path among the filesystems
  getEspPath = filesystems:
    let
      # Filter filesystems to find ones mounted at /boot or /boot/efi
      bootMounts = lib.filterAttrs
        (mountPoint: _: mountPoint == "/boot" || mountPoint == "/boot/efi")
        filesystems;

      # Get the first mount point (if any)
      firstBoot = lib.head (lib.attrNames bootMounts);
    in
      if firstBoot != null then firstBoot else "/boot";

  espPath = getEspPath config.fileSystems;
in {
  imports = [ /etc/nixos/hardware-configuration.nix ];  # ← KEY: Uses system hardware config

  boot.loader = lib.mkForce {
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = espPath;
    };
  };
}
```

**Key Insights**:
- Imports `/etc/nixos/hardware-configuration.nix` (system-generated)
- Configures GRUB bootloader
- Auto-detects ESP path
- Uses `lib.mkForce` to override defaults
- This is the ONLY place that imports the hardware config

### Zephyrus-Specific Module

**File**: `/home/traum/dotfiles/modules/zephyrus.nix` (partial - key sections)

```nix
{ config, pkgs, lib, ... }:

let
  inherit (pkgs.lib) mkForce;
in
{
  imports = [
    ./router-generated/zephyrus-consolidated.nix  # ← Router/VM setup
  ];

  # Make detection script available system-wide and other packages
  environment.systemPackages = with pkgs; lib.mkAfter [
    # ASUS-specific packages
    asusctl
    bluez
    blueman

    # Power management
    powertop
    acpi
    acpid

    # NVIDIA/CUDA
    cudatoolkit
    linuxPackages.nvidia_x11

    # VM management
    virt-manager
    virt-viewer
    OVMF
    # ... etc
  ];

  # Host-specific name
  networking.hostName = lib.mkForce "zeph";

  # Power management
  powerManagement = {
    enable = true;
    powertop.enable = true;
    cpuFreqGovernor = "powersave";
  };

  # TLP, auto-cpufreq, thermald, NVIDIA, etc.
  # ... (detailed configuration)

  # Bootloader override
  boot.loader = {
    systemd-boot.enable = false;
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;
      # ...
    };
    efi.canTouchEfiVariables = true;
  };
}
```

**Key Insights**:
- Imports router-generated config
- Sets hostname with `mkForce`
- Adds machine-specific packages
- Configures power management (laptop-specific)
- Overrides bootloader configuration
- Does NOT import hardware config (that's in hwconf.nix)

### Base Configuration Module

**File**: `/home/traum/dotfiles/modules/configuration.nix` (partial - key sections)

```nix
{ config, pkgs, lib, ... }:

{
  # Suspend on lid close
  services.logind.lidSwitch = "suspend";

  # Lock screen before suspend
  systemd.services.i3lock-on-suspend = { ... };

  # Autorandr for monitor management
  services.autorandr.enable = true;

  # Set ranger as default file manager
  xdg.mime.defaultApplications = {
    "inode/directory" = "ranger.desktop";
  };

  # Nix settings
  nix.settings.download-buffer-size = 524288000;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Systemd optimizations
  systemd = {
    services.nix-daemon.enable = true;
    extraConfig = ''
      DefaultTimeoutStopSec=10s
    '';
  };

  # earlyoom to prevent freezes
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    enableNotifications = true;
  };

  # Kernel settings
  boot.kernel.sysctl = {
    "kernel.sysrq" = 1;
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;
    # ... etc
  };

  # zram swap
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Binary cache
  nix.settings = {
    substituters = [ ... ];
    trusted-public-keys = [ ... ];
  };

  # PAM limits
  security.pam.loginLimits = [ ... ];

  # Enable all firmware
  hardware.enableAllFirmware = true;

  # Fish shell
  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;

  # Qt/GTK
  qt = {
    enable = true;
    platformTheme = "gtk2";
  };

  # Environment variables
  environment.variables = {
    GDK_SCALE = "1.5";
    GDK_DPI_SCALE = "1.0";
    QT_SCALE_FACTOR = "1.5";
    XCURSOR_SIZE = "32";
    BAT_THEME = "ansi";
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_USE_XINPUT2 = "1";
  };

  # Use latest kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Default networking
  networking.hostName = "nix"; # default, overridden by machine configs
  networking.networkmanager.enable = true;

  # Firewall
  networking.firewall.allowedTCPPorts = [ 22 80 8080 4444 4445 8000 ];
  networking.firewall.allowedUDPPorts = [ 22 53 80 4444 4445 5353 5355 5453 ];
  networking.firewall.enable = true;

  # Time zone and locale
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";

  # X11
  services.xserver.enable = true;
  services.xserver.displayManager.startx.enable = true;
  services.xserver.windowManager.i3.enable = true;
  services.xserver.xkb = {
    layout = "se";
    variant = "";
  };

  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 10d";
  };

  # Auto-optimize store
  nix.settings.auto-optimise-store = true;

  # System state version
  system.stateVersion = "22.11";
}
```

**Key Insights**:
- Contains ALL base system configuration
- Sets defaults that can be overridden
- No hardware-specific configuration
- Shared across ALL machines
- Sets default hostname (overridden by machine configs)
- Configures X11, i3, fish, etc.

---

## 🔍 SPLIX ANALYSIS

### Splix Repository Purpose

Splix is the **router VM automation system** that:
1. Detects hardware (WiFi cards, IOMMU groups)
2. Builds a router VM with WiFi passthrough
3. Generates machine-specific VFIO configurations
4. Creates NixOS specializations (base, router, maximalism modes)

**Location**: `~/splix`

### Key Splix Components

1. **Hardware Detection Script**: `scripts/hardware-identify.sh`
   - Detects WiFi cards and PCI addresses
   - Checks IOMMU support
   - Identifies alternative network interfaces
   - Generates compatibility score

2. **Setup Script**: `scripts/setup.sh`
   - Runs hardware detection
   - Generates router credentials
   - Builds router VM image
   - Creates consolidated configuration
   - Deploys VMs to libvirt

3. **Generated Configuration**: `generated/modules/{machine}-consolidated.nix`
   - Conditional VFIO passthrough
   - Router specialization
   - Maximalism specialization
   - Autostart services
   - Status commands

### Splix Generated Output Structure

```
generated/
├── modules/
│   └── zephyrus-consolidated.nix    # Machine-specific VFIO + specializations
└── scripts/
    └── autostart-router-vm.sh       # VM autostart script
```

### How Dotfiles Uses Splix Output

**File**: `/home/traum/dotfiles/modules/zephyrus.nix` (line 10)

```nix
imports = [
  ./router-generated/zephyrus-consolidated.nix
];
```

The `router-generated/` directory in dotfiles contains the output from splix.

---

## 🎯 HYDRIX REQUIREMENTS

### What Hydrix Must Be

1. **Standalone Repository**
   - No dependencies on ~/dotfiles
   - No dependencies on ~/splix
   - Contains everything needed to configure a machine

2. **Template-Driven**
   - Easy to add new machines
   - Reproducible setup process
   - Clear structure and organization

3. **Combines Best of Both**
   - Base system configuration (from dotfiles)
   - Router/VM automation (from splix)
   - Clean, maintainable code

4. **Self-Documenting**
   - Clear README
   - Commented configurations
   - This implementation guide

### What Hydrix Must Do

1. **Replace ~/dotfiles** for system configuration
2. **Replace ~/splix** for router/VM automation
3. **Provide a single source of truth** for all machines
4. **Make adding new machines trivial**

---

## 📐 CORRECT HYDRIX STRUCTURE

### Proposed Directory Layout

```
Hydrix/
├── flake.nix                        # Main flake (like dotfiles)
├── CLAUDE.md                        # Project documentation
├── IMPLEMENTATION-GUIDE.md          # This file
│
├── modules/
│   ├── base/
│   │   ├── configuration.nix        # Base system (from dotfiles/modules/configuration.nix)
│   │   ├── hardware-config.nix      # Hardware wrapper (from dotfiles/modules/hwconf.nix)
│   │   ├── users.nix               # User configuration
│   │   ├── services.nix            # System services
│   │   ├── audio.nix               # Audio configuration
│   │   └── virt.nix                # Virtualization base
│   │
│   ├── desktop/
│   │   ├── i3.nix                  # i3 window manager
│   │   ├── packages.nix            # System packages
│   │   └── colors.nix              # Color schemes
│   │
│   ├── shell/
│   │   └── fish.nix                # Fish shell configuration
│   │
│   └── router/
│       ├── router-vm-config.nix    # Router VM build config
│       └── router-vm.nix           # Router VM NixOS config
│
├── profiles/
│   ├── machines/
│   │   ├── zephyrus.nix            # Zephyrus-specific config
│   │   └── zenbook.nix             # Zenbook-specific config
│   │
│   └── vms/
│       ├── pentest-base.nix        # Pentest VM base
│       └── pentest-full.nix        # Pentest VM full
│
├── generated/                       # Auto-generated configs
│   ├── modules/
│   │   └── {machine}-consolidated.nix
│   └── scripts/
│       └── autostart-router-vm.sh
│
├── scripts/
│   ├── hardware-identify.sh         # Hardware detection
│   ├── setup.sh                     # Machine setup automation
│   └── add-machine.sh               # Template for adding machines
│
└── templates/
    ├── machine-profile.nix.template
    └── flake-entry.nix.template
```

### Critical File Mappings

**From dotfiles to Hydrix**:
```
dotfiles/modules/configuration.nix  → Hydrix/modules/base/configuration.nix
dotfiles/modules/hwconf.nix         → Hydrix/modules/base/hardware-config.nix
dotfiles/modules/zephyrus.nix       → Hydrix/profiles/machines/zephyrus.nix
dotfiles/modules/i3.nix             → Hydrix/modules/desktop/i3.nix
dotfiles/modules/packages.nix       → Hydrix/modules/desktop/packages.nix
dotfiles/modules/users.nix          → Hydrix/modules/base/users.nix
dotfiles/modules/services.nix       → Hydrix/modules/base/services.nix
dotfiles/modules/audio.nix          → Hydrix/modules/base/audio.nix
dotfiles/modules/virt.nix           → Hydrix/modules/base/virt.nix
dotfiles/modules/colors.nix         → Hydrix/modules/desktop/colors.nix
```

**From splix to Hydrix**:
```
splix/scripts/hardware-identify.sh         → Hydrix/scripts/hardware-identify.sh
splix/scripts/setup.sh                     → Hydrix/scripts/setup.sh
splix/modules/router/router-vm-config.nix  → Hydrix/modules/router/router-vm-config.nix
splix/generated/modules/*                  → Hydrix/generated/modules/*
```

---

## ✅ IMPLEMENTATION CHECKLIST

### Phase 1: Setup Base System Configuration

- [ ] Copy `dotfiles/modules/configuration.nix` → `Hydrix/modules/base/configuration.nix`
- [ ] Copy `dotfiles/modules/hwconf.nix` → `Hydrix/modules/base/hardware-config.nix`
- [ ] Copy `dotfiles/modules/users.nix` → `Hydrix/modules/base/users.nix`
- [ ] Copy `dotfiles/modules/services.nix` → `Hydrix/modules/base/services.nix`
- [ ] Copy `dotfiles/modules/audio.nix` → `Hydrix/modules/base/audio.nix`
- [ ] Copy `dotfiles/modules/virt.nix` → `Hydrix/modules/base/virt.nix`
- [ ] Verify all paths are correct and no dotfiles references remain

### Phase 2: Setup Desktop Environment

- [ ] Copy `dotfiles/modules/i3.nix` → `Hydrix/modules/desktop/i3.nix`
- [ ] Copy `dotfiles/modules/packages.nix` → `Hydrix/modules/desktop/packages.nix`
- [ ] Copy `dotfiles/modules/colors.nix` → `Hydrix/modules/desktop/colors.nix`
- [ ] Verify all paths are correct

### Phase 3: Setup Machine Profiles

- [ ] Read `dotfiles/modules/zephyrus.nix` completely
- [ ] Create `Hydrix/profiles/machines/zephyrus.nix` based on dotfiles version
- [ ] Remove import of `/home/traum/dotfiles/modules/zephyrusconf.nix`
- [ ] Update router-generated import path to `../../generated/modules/zephyrus-consolidated.nix`
- [ ] Read `dotfiles/modules/zenbook.nix` completely
- [ ] Create `Hydrix/profiles/machines/zenbook.nix` based on dotfiles version
- [ ] Verify all imports are relative to Hydrix, not dotfiles

### Phase 4: Verify Router/VM Setup

- [ ] Verify `scripts/setup.sh` is standalone (no dotfiles/splix references)
- [ ] Verify generated configs go to `Hydrix/generated/`
- [ ] Verify autostart scripts reference `~/Hydrix/generated/scripts/`
- [ ] Test router VM build independently

### Phase 5: Update Flake Structure

- [ ] Update `flake.nix` zephyrus configuration to match dotfiles pattern
- [ ] Update `flake.nix` zenbook configuration to match dotfiles pattern
- [ ] Verify all module paths are correct
- [ ] Verify no absolute paths to dotfiles or splix

### Phase 6: Test Build (Dry Run)

- [ ] Run `nix flake check` to verify flake syntax
- [ ] Run `nixos-rebuild dry-build --flake .#zephyrus --impure` to test build
- [ ] Fix any errors that appear
- [ ] Verify all modules are found
- [ ] Verify no missing dependencies

### Phase 7: Test Actual Build

- [ ] Backup current system configuration
- [ ] Create system restore point if possible
- [ ] Run `nixos-rebuild switch --flake .#zephyrus --impure` on a non-critical boot
- [ ] Verify system boots successfully
- [ ] Verify all functionality works (WiFi, graphics, sound, etc.)
- [ ] Document any issues

### Phase 8: Add Zenbook Support

- [ ] Follow same process for zenbook
- [ ] Test on actual zenbook hardware
- [ ] Document zenbook-specific configurations

---

## 🚨 CRITICAL RULES - READ BEFORE EVERY CHANGE

1. **NEVER import from dotfiles or splix** - Hydrix must be standalone
2. **ALWAYS use relative paths** - No absolute paths like `/home/traum/dotfiles/`
3. **READ the working config first** - Understand before copying
4. **TEST incrementally** - Don't change everything at once
5. **DOCUMENT changes** - Update this guide with learnings
6. **VERIFY imports** - Make sure all imports point to Hydrix files
7. **CHECK for commented modules** - Don't enable modules that dotfiles has disabled
8. **PRESERVE hardware config pattern** - Use hwconf.nix pattern, not machine-specific hardware imports
9. **USE mkForce appropriately** - Understand when to override vs set
10. **VALIDATE before rebuild** - Use `nix flake check` and `--dry-build` first

---

## 🔧 SPECIFIC FIXES NEEDED

### Fix Zephyrus Profile

**Current (BROKEN)**: `Hydrix/profiles/machines/zephyrus.nix`
```nix
imports = [
  /home/traum/dotfiles/modules/zephyrusconf.nix  # ← WRONG!
];
```

**Should Be**: `Hydrix/profiles/machines/zephyrus.nix`
```nix
imports = [
  ../../generated/modules/zephyrus-consolidated.nix  # Router/VM specializations
];

# All other zephyrus-specific config here (ASUS, NVIDIA, power management, etc.)
# Do NOT import hardware config (that's handled by modules/base/hardware-config.nix)
```

### Fix Flake Module Imports

**Current**: `Hydrix/flake.nix` zephyrus configuration
```nix
zephyrus = nixpkgs.lib.nixosSystem {
  modules = [
    # ...
    ./profiles/machines/zephyrus.nix
    ./generated/modules/zephyrus-consolidated.nix  # ← Duplicated!
    ./modules/base/system-config.nix
    # ...
  ];
};
```

**Should Be**: Match dotfiles pattern exactly
```nix
zephyrus = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    { nixpkgs.config.allowUnfree = true; }
    { nixpkgs.overlays = [ overlay-unstable ]; }
    nix-index-database.nixosModules.nix-index

    # Base system configuration (replaces dotfiles/modules/configuration.nix)
    ./modules/base/configuration.nix

    # Hardware config wrapper (replaces dotfiles/modules/hwconf.nix)
    ./modules/base/hardware-config.nix

    # Machine-specific config (replaces dotfiles/modules/zephyrus.nix)
    # This will import the router-generated config internally
    ./profiles/machines/zephyrus.nix

    # Core functionality modules (only those enabled in dotfiles)
    ./modules/desktop/i3.nix
    ./modules/desktop/packages.nix
    ./modules/base/services.nix
    ./modules/base/users.nix
    ./modules/desktop/colors.nix
    ./modules/base/virt.nix
    ./modules/base/audio.nix

    # NOTE: scripts.nix, hosts.nix are commented out in dotfiles - don't add them!
  ];
};
```

---

## 📝 QUESTIONS TO ANSWER BEFORE PROCEEDING

Before making ANY changes to Hydrix, answer these questions:

1. **What modules does the working dotfiles use for this machine?**
   - Read the flake.nix
   - List each module
   - Note which are commented out

2. **What does each module do?**
   - Read the module file
   - Understand its purpose
   - Note dependencies

3. **How is hardware configuration handled?**
   - Where is hardware-configuration.nix imported?
   - Is it direct or through a wrapper?
   - Are there machine-specific hardware configs?

4. **What makes this machine unique?**
   - What's in the machine-specific config?
   - What packages are machine-specific?
   - What services are machine-specific?

5. **How will this work standalone?**
   - Are all paths relative?
   - Are there any dotfiles references?
   - Can this build without dotfiles present?

6. **What are we changing and why?**
   - Document the specific change
   - Explain the reasoning
   - Predict potential issues

---

## 🎓 KEY LEARNINGS

### Dotfiles Pattern

1. **Single hardware config wrapper** (`hwconf.nix`) used by all machines
2. **Machine configs don't import hardware** - that's handled by the base
3. **Commented modules are intentional** - don't assume they should be enabled
4. **Overlays for unstable packages** - common pattern
5. **Machine-specific packages in machine config** - not in shared packages.nix

### Splix Pattern

1. **Hardware detection is thorough** - checks IOMMU, alternative interfaces
2. **Generated configs are machine-specific** - based on actual hardware
3. **Specializations for different modes** - base, router, maximalism
4. **Autostart scripts are templated** - generated during setup

### Integration Pattern

1. **Dotfiles imports splix output** - through router-generated directory
2. **Splix is run once per machine** - generates static config
3. **Updates require re-running setup.sh** - to regenerate configs

---

## 🔄 RECOMMENDED IMPLEMENTATION ORDER

1. **Start with base system**
   - Get configuration.nix and hardware-config.nix working
   - Test that a minimal system can boot

2. **Add desktop environment**
   - Add i3.nix
   - Add packages.nix
   - Add colors.nix
   - Test that desktop works

3. **Add machine specifics**
   - Create zephyrus.nix (WITHOUT router config first)
   - Test zephyrus boots and works

4. **Add router/VM functionality**
   - Generate zephyrus-consolidated.nix
   - Import it into zephyrus.nix
   - Test specializations work

5. **Repeat for zenbook**
   - Follow same pattern
   - Document differences

---

## 📚 REFERENCE COMMANDS

### Checking Dotfiles Working Config
```bash
# See what dotfiles actually builds for zephyrus
nix flake show ~/dotfiles

# See the exact modules used
grep -A 30 "zephyrus = " ~/dotfiles/flake.nix

# Check if a module is commented
grep -n "zephyrusconf" ~/dotfiles/flake.nix
```

### Building Hydrix Safely
```bash
# Verify flake syntax
nix flake check ~/Hydrix

# Test build without applying
nixos-rebuild dry-build --flake ~/Hydrix#zephyrus --impure

# Build to test configuration
nixos-rebuild test --flake ~/Hydrix#zephyrus --impure

# Only after testing - apply permanently
nixos-rebuild switch --flake ~/Hydrix#zephyrus --impure
```

### Comparing Configurations
```bash
# Compare current system with dotfiles
diff <(nixos-rebuild dry-build --flake ~/dotfiles#zephyrus --impure 2>&1) \
     <(nixos-rebuild dry-build --flake ~/Hydrix#zephyrus --impure 2>&1)
```

---

## ⚙️ NEXT STEPS FOR NEW CHAT SESSION

When starting a new chat to fix Hydrix:

1. **Read this guide completely**
2. **Read CLAUDE.md for project context**
3. **Examine dotfiles flake.nix for zephyrus**
4. **Read each module that zephyrus uses**
5. **Examine Hydrix current structure**
6. **Identify all problems**
7. **Create implementation plan**
8. **Fix incrementally with testing**
9. **Update this guide with learnings**

---

## 📋 PROBLEM CHECKLIST

Before declaring Hydrix "fixed", verify:

- [ ] No imports from ~/dotfiles
- [ ] No imports from ~/splix
- [ ] All paths are relative to Hydrix
- [ ] Hardware config uses same pattern as dotfiles
- [ ] Only modules enabled in dotfiles are enabled
- [ ] Machine configs match dotfiles pattern
- [ ] Flake structure matches dotfiles
- [ ] Generated configs go to Hydrix/generated/
- [ ] Scripts reference Hydrix paths
- [ ] Can build without dotfiles present
- [ ] Can boot successfully
- [ ] All hardware works (WiFi, graphics, audio, etc.)
- [ ] Specializations work (base, router, maximalism)
- [ ] No assumptions were made

---

**END OF IMPLEMENTATION GUIDE**

*This guide should be treated as the source of truth for Hydrix development.*
*Update this guide as you learn more about the system.*
*Never assume - always verify against working configurations.*
