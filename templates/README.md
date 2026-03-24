# Hydrix Templates

This directory contains templates used by `install-hydrix.sh` and `setup-hydrix.sh` to generate user configurations.

## Template Architecture

Users get a separate `~/hydrix-config/` directory that imports Hydrix as a flake input. Templates provide the initial structure for this directory.

```
┌─────────────────────────────────────────────────────────────┐
│                     SETUP TIME                               │
├─────────────────────────────────────────────────────────────┤
│  install-hydrix.sh / setup-hydrix.sh                         │
│                                                              │
│  1. Auto-detect hardware (CPU, WiFi, ASUS, serial)          │
│  2. Copy templates/user-config/ → ~/hydrix-config/          │
│  3. Generate machines/<serial>.nix from detected hardware   │
│  4. Pre-build essential microVMs                             │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    ~/hydrix-config/                           │
├─────────────────────────────────────────────────────────────┤
│  flake.nix              Imports Hydrix from GitHub           │
│  machines/<serial>.nix  Machine config (all hydrix.* opts)  │
│  profiles/              VM profile customizations            │
│  specialisations/       Boot mode extra packages             │
│  shared/common.nix      Settings shared across machines     │
└─────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
templates/
├── user-config/                    # Template for ~/hydrix-config/
│   ├── flake.nix                   # Main flake (imports Hydrix)
│   ├── README.md                   # User-facing documentation
│   ├── machines/
│   │   └── example-serial.nix      # Machine config template
│   ├── profiles/                   # VM profile customizations
│   │   ├── browsing/
│   │   │   ├── default.nix         # Browsing VM overrides
│   │   │   └── packages/
│   │   │       └── default.nix     # vm-sync managed packages
│   │   ├── pentest/
│   │   ├── dev/
│   │   ├── comms/
│   │   └── lurking/
│   ├── specialisations/
│   │   ├── _base.nix               # Minimal packages (all modes)
│   │   ├── lockdown.nix            # Default mode extras
│   │   ├── administrative.nix      # Admin mode extras
│   │   ├── fallback.nix            # Fallback mode extras
│   │   └── leisure.nix.example     # Example custom specialisation
│   └── shared/
│       └── common.nix              # Cross-machine settings
└── README.md                       # This file
```

## Templates

### flake.nix
**Copied to**: `~/hydrix-config/flake.nix`
**Purpose**: Main flake that imports Hydrix from GitHub, auto-discovers machine configs, and defines all VM targets.

Key settings users may customize:
- `hostUsername` — primary user (used for VM user config)
- `localHydrixPath` — set to local clone path for development

### machines/example-serial.nix
**Copied to**: `~/hydrix-config/machines/<serial>.nix`
**Purpose**: Complete machine config using `hydrix.*` options.

The setup scripts copy this template and substitute detected values:
- `hydrix.username` — detected from current user
- `hydrix.hostname` — detected or prompted
- `hydrix.hardware.platform` — detected CPU vendor
- `hydrix.hardware.vfio.pciIds` — detected WiFi vendor:device ID
- `hydrix.hardware.vfio.wifiPciAddress` — detected WiFi PCI address
- `hydrix.locale.*` — detected from current system

Machine configs are named by hardware serial (`/sys/class/dmi/id/product_serial`) for automatic detection during reinstalls.

### profiles/
**Copied to**: `~/hydrix-config/profiles/`
**Purpose**: User customizations layered on top of Hydrix base VM profiles.

Each profile directory contains:
- `default.nix` — User overrides (colorscheme, extra packages, hosts)
- `packages/default.nix` — Auto-generated package list (managed by `vm-sync`)

Profiles are overlays — Hydrix base profiles provide all core functionality, user profiles add customizations on top.

### specialisations/
**Copied to**: `~/hydrix-config/specialisations/`
**Purpose**: Extra packages per boot mode.

The framework defines the infrastructure for each mode (lockdown, administrative, fallback). These files are for the user's extra packages per mode.

### shared/common.nix
**Copied to**: `~/hydrix-config/shared/common.nix`
**Purpose**: Settings applied to all machines. Optional — all options commented out by default.

## How Setup Scripts Use Templates

### install-hydrix.sh (Fresh Install)
1. Partitions disk via disko
2. Copies `templates/user-config/` to `/mnt/home/<user>/hydrix-config/`
3. Generates `machines/<serial>.nix` with detected hardware
4. Runs `nixos-install` with the generated flake
5. Pre-builds microVMs (router, builder, browsing)

### setup-hydrix.sh (Migrate Existing NixOS)
1. Detects current system config (user, locale, WiFi)
2. Copies `templates/user-config/` to `~/hydrix-config/`
3. Generates `machines/<serial>.nix` with detected hardware
4. Handles legacy migration (`machine.nix` → `machines/<serial>.nix`)
5. Supports multi-machine: add to existing config or create fresh

### Multi-Machine Support

Both scripts support managing multiple machines from a single hydrix-config repo:

| Scenario | Behavior |
|----------|----------|
| Fresh install, no existing config | Creates new `~/hydrix-config/` |
| Fresh install, clone existing | Clones repo, adds `machines/<serial>.nix` |
| Existing config detected | Offers: add machine, clone different repo, or start fresh |
| Legacy `machine.nix` format | Auto-migrates to `machines/<serial>.nix` |
