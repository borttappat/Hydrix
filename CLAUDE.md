# Hydrix Project - Technical Documentation

**Last Updated**: 2025-11-29
**Status**: ⚠️ REQUIRES REBUILD - Implementation guide created, needs careful restructuring | ✅ nixbuild.sh fixed
**Goal**: Clean, declarative VM automation system that replaces both ~/dotfiles and ~/splix

---

## 🚨 CRITICAL - READ FIRST

**STOP**: Before making ANY changes to Hydrix, read `/home/traum/Hydrix/IMPLEMENTATION-GUIDE.md`

**What Happened**: A system rebuild broke because assumptions were made instead of learning from the working dotfiles setup.

**The Problem**:
- Hydrix imported `/home/traum/dotfiles/modules/zephyrusconf.nix` (which is COMMENTED OUT in dotfiles)
- This created a hard dependency on dotfiles, breaking standalone nature
- Generated module was imported without understanding the base system

**The Fix**:
- Read and understand the working dotfiles configuration FIRST
- Copy the exact module structure from dotfiles
- Use hwconf.nix pattern (imports /etc/nixos/hardware-configuration.nix)
- Machine profiles should NOT import hardware configs directly
- Follow the implementation guide step-by-step

**Key Learnings**:
1. Dotfiles uses `hwconf.nix` wrapper for ALL machines (not machine-specific hardware configs)
2. Machine profiles import router-generated configs, not hardware configs
3. Many modules are intentionally commented out in dotfiles
4. NEVER make assumptions - always read the working config first

---

## ✅ RESOLVED - nixbuild.sh Mode Switching Issue

**Resolution Date**: 2025-11-29

**What Was Fixed**:
1. ✅ Removed problematic live mode-switching commands
2. ✅ Implemented proper build strategy: `boot` for router/maximalism, `switch` for base/fallback
3. ✅ Created reusable `detect_specialisation()` and `rebuild_with_specialisation()` functions
4. ✅ Added Zenbook support with specialisation awareness
5. ✅ Improved VM detection using both `Chassis` field and `Hardware Vendor`
6. ✅ Updated templates with clear instructions for adding new machines

**How It Works Now**:
- **VM Detection**: Checks `Chassis: vm` or `Hardware Vendor: QEMU/VMware` → uses hostname pattern
- **Physical Detection**: Uses `Hardware Model` keywords (Zephyrus, Zenbook, etc.)
- **Specialisation Detection**:
  - Primary: Check `/run/current-system/configuration-name` for mode labels
  - Fallback: Check running VMs as last resort
- **Rebuild Strategy**:
  - Router/Maximalism modes: Use `nixos-rebuild boot` (requires reboot for kernel params)
  - Base/Fallback modes: Use `nixos-rebuild switch` (safe to apply live)

**Correct rebuild flow**:
1. Boot into desired mode via bootloader (select specialisation at boot)
2. Run `./nixbuild.sh` - detects current mode, rebuilds in that mode
3. Router/maximalism: requires reboot to apply changes
4. Base/fallback: applies changes live (no reboot needed)

**Testing**:
- Created `test-nixbuild-detection.sh` to verify detection logic
- Tested successfully on Zephyrus (detects correctly)
- Syntax validated with `bash -n`

---

## Project Vision

Build a streamlined repository that:
- Extracts best configurations from ~/dotfiles
- Uses static, declarative theming (no pywal complexity)
- Implements two-stage deployment: minimal base → first-boot shaping → purpose-specific system
- Will replace both ~/dotfiles and ~/splix as single source of truth

**Key Design Choices**:
1. **Static Color Schemes**: Each VM type gets predefined colors (red for pentest, blue for comms, etc.)
   - No runtime color generation, colors defined in Nix modules
   - Visual differentiation built-in

2. **Two-Stage System**:
   - **Base Images**: Small, built once, include shaping service
   - **First-Boot Shaping**: VM clones Hydrix repo, applies full profile
   - **Full Profiles**: All packages and configs for specific purpose

3. **Simple Module Organization**: Consolidated modules, not over-granular
   - Only create separate modules for things that need actual configuration
   - Group related packages together

---

## Current Dotfiles Setup Analysis

### Repository Locations

```
~/dotfiles/          ← Current working NixOS config (source of truth for QOL)
  ├── modules/       ← NixOS modules (i3, packages, users, etc.)
  ├── scripts/bash/  ← Automation scripts
  ├── configs/       ← Application configs
  └── fish/          ← Shell configuration

~/splix/             ← VM automation experiments (reference for hardware detection)
  ├── scripts/setup.sh        ← Full automation workflow
  └── scripts/hardware-identify.sh  ← Hardware detection logic

~/Hydrix/            ← NEW: Clean template-driven VM system (this repo)
  └── [To be built]
```

### Boot Flow (Critical Understanding)

```
1. System Boots → TTY
   └─> services.getty.autologinUser = "traum" (auto-login to console)

2. User Types "x"
   └─> Starts X server
   └─> Executes ~/.xinitrc

3. .xinitrc (~/.dotfiles/xorg/.xinitrc)
   └─> VM Detection: hostname check for "VM" pattern
   │   ├─> IF VM: Set Mod1 (Alt), configure Virtual-1/qxl-0 display
   │   └─> IF Host: Set Mod4 (Super), manage eDP + external monitors
   └─> wal -Rn (restore pywal colors)
   └─> load-display-config.sh (resolution detection)
   └─> Template i3 config with variables (MOD_KEY, I3_FONT_SIZE, GAPS_INNER)
   └─> Template polybar config (POLYBAR_FONT_SIZE, POLYBAR_FONT)
   └─> exec i3

4. i3 Starts
   └─> autostart.sh runs
       └─> Configure external monitors (xrandr)
       └─> Start picom (compositor)
       └─> Link dunst config from wal cache
       └─> Launch polybar on all monitors
```

**Key Files**:
- `/home/traum/dotfiles/xorg/.xinitrc` - Initial X setup
- `/home/traum/dotfiles/scripts/bash/i3launch.sh` - Display resolution logic
- `/home/traum/dotfiles/scripts/bash/autostart.sh` - i3 autostart
- `/home/traum/dotfiles/scripts/bash/load-display-config.sh` - Resolution variables

### The "x" Command

The **"x"** command is actually just the `startx` command that comes with X11. The user types "x" at the TTY prompt, which:
1. `startx` is available via `xorg.xinit` package
2. Reads `~/.xinitrc` for initialization
3. Starts the X server and window manager

**NixOS Module**: `services.xserver.displayManager.startx.enable = true;`

---

## Color/Theme Management: The "walrgb" Flow

**Central Script**: `walrgb.sh` (in scripts.nix as system-wide command)

### What `walrgb` Does:

```bash
walrgb /path/to/wallpaper.jpg
```

1. **Runs pywal** on the provided wallpaper
2. **Extracts primary color** from `~/.cache/wal/colors`
3. **Updates RGB lighting**:
   - ASUS machines: `asusctl` LED control
   - Other machines: OpenRGB
4. **Restarts polybar** (`polybar-msg cmd restart`)
5. **Updates Zathura colors** (PDF reader)
6. **Updates Firefox** via pywalfox
7. **Updates GTK themes** (wal-gtk.sh)
8. **Updates Dunst** (notification daemon)
   - Links `~/.cache/wal/dunstrc` → `~/.config/dunst/dunstrc`
   - Restarts dunst
9. **Updates startpage** (~/dotfiles/misc/startpage.html)
10. **Updates GitHub Pages** colors (~/borttappat.github.io/)

**Related Scripts**:
- `randomwalrgb.sh` - Random wallpaper + walrgb
- `nixwal.sh` - Updates nix-colors file
- `wal-gtk.sh` - GTK theme integration
- `zathuracolors.sh` - PDF reader colors

---

## Desktop Environment Components

### Window Manager: i3-gaps

**Module**: `~/dotfiles/modules/i3.nix`
**Features**:
- **Resolution-aware**: Font size, gaps, border width change with resolution
- **VM-aware**: Uses Alt (Mod1) in VMs, Super (Mod4) on host
- **Template-based**: `config.base` → `config` with injected variables

**Resolutions Supported**:
- 1920x1080/1200: Cozette 8, gaps 6, border 2
- 2560x1440: Cozette 9, gaps 8, border 2
- 2880x1800: Cozette 10, gaps 10, border 3
- 3840x2160: Cozette 12, gaps 12, border 4

**Key Packages**:
```nix
i3-gaps
i3lock-color
picom
feh
rofi
dunst
libnotify
```

### Status Bar: Polybar

**Template**: `~/.config/polybar/config.ini.template`
**Variables**: `POLYBAR_FONT_SIZE`, `POLYBAR_FONT`
**Launch**: Multi-monitor aware (launches on all connected displays)

### Notifications: Dunst

**Config**: Symlinked from `~/.cache/wal/dunstrc` (pywal-generated)
**Restart**: After walrgb runs

### Application Launcher: Rofi

**Theme**: Pywal-integrated

### Compositor: Picom

**Disabled**: On VMs (detected via hostname)
**Enabled**: On host machines

---

## Shell & CLI Environment

### Shell: Fish

**Config**: `~/dotfiles/fish/config.fish`

**Key Features**:
- **Vi keybindings**: `fish_vi_key_bindings`
- **Pywal integration**: Loads `~/.cache/wal/sequences` on interactive start
- **Starship prompt**: `starship init fish | source`
- **Zoxide**: Directory jumping (`zoxide init fish | source`)
- **Directory memory**: Saves/restores last directory in `/tmp/last_fish_dir`
- **Asciinema recording**: Auto-start if `~/.recording_active` exists

**Important Abbreviations**:
```fish
# System
abbr rb 'systemctl reboot'
abbr sd 'shutdown -h now'
abbr suspend 'systemctl suspend'

# Navigation
abbr ... 'cd ../..'
abbr j 'joshuto'
abbr r 'ranger'

# File listing (eza)
abbr ls 'eza -A --color=always --group-directories-first'
abbr l 'eza -Al --color=always --group-directories-first'

# Git
abbr gs 'git status'
abbr ga 'git add'
abbr gc 'git commit -m'
abbr gp 'git push -uf origin main'

# Utilities
abbr bat 'bat --theme=ansi'
abbr h 'htop'
```

### Modern CLI Tools

**Replacements**:
- `ls` → `eza` (better ls)
- `cat` → `bat` (syntax highlighting)
- `grep` → `ugrep` (faster grep)
- `cd` → `zoxide` (cd with memory)
- `du` → `du-dust` (visual disk usage)
- `top` → `bottom` / `htop` (process monitors)

**Terminal**: Alacritty (unstable package)

---

## VM Detection Logic

**Pattern**: Checks hostname for "VM" (case-insensitive)

```bash
hostname=$(hostnamectl | grep "Icon name:" | cut -d ":" -f2 | xargs)
if [[ $hostname =~ [vV][mM] ]]; then
    # VM-specific settings
fi
```

### VM Behavior:
- **Modifier Key**: Mod1 (Alt) instead of Mod4 (Super)
- **Display**: Virtual-1 or qxl-0 (QEMU displays)
- **Resolution**: 2560x1440 preferred, fallback to 1920x1200
- **Compositor**: Picom disabled
- **SPICE**: `spice-vdagent -x` started

### Host Behavior:
- **Modifier Key**: Mod4 (Super)
- **Display**: eDP (internal) + external monitors
- **Resolution**: Native or downscaled (2880x1800 → 1920x1200)
- **Compositor**: Picom enabled
- **Monitors**: xrandr manages multi-display layout

---

## Essential Packages to Port

### Desktop Environment (QOL Base)
```nix
# Window Manager
i3-gaps
i3lock-color
picom
polybar
rofi
dunst
libnotify

# Visual
feh               # Wallpaper
pywal             # Color scheme generator
pywalfox-native   # Firefox integration

# Terminal
alacritty
fish
starship
```

### CLI Tools (QOL)
```nix
# Modern replacements
eza               # ls
bat               # cat
ugrep             # grep
zoxide            # cd
du-dust           # du
bottom            # top

# Essential utilities
fzf               # Fuzzy finder
ranger / joshuto  # File managers
tmux              # Terminal multiplexer
rsync             # File sync
git / gh          # Version control
```

### X11 Essentials
```nix
xorg.xinit        # startx
xorg.xrandr       # Display management
xorg.xrdb         # X resources
xorg.xmodmap      # Key mapping
xorg.xorgserver   # X server
xdotool           # X automation
xclip             # Clipboard
```

### System Utilities
```nix
vim               # Editor
wget / curl       # Downloads
killall           # Process management
unzip / rar       # Archives
brightnessctl     # Backlight control
pciutils          # lspci
```

### QEMU Guest Tools (VM-specific)
```nix
qemu-guest-agent
spice-vdagent
spice-gtk
```

---

## Hydrix Implementation Plan

### Phase 1: Extract Core Modules

1. **modules/base/**
   - `nixos-base.nix` - Basic NixOS settings (from configuration.nix)
   - `users.nix` - User creation with sudo NOPASSWD
   - `networking.nix` - Basic network config

2. **modules/desktop/**
   - `i3.nix` - i3 WM with resolution awareness
   - `polybar.nix` - Status bar
   - `dunst.nix` - Notifications
   - `rofi.nix` - Launcher
   - `theming.nix` - Pywal integration + walrgb script

3. **modules/shell/**
   - `fish.nix` - Fish shell config
   - `zoxide.nix` - Directory jumping
   - `cli-tools.nix` - Modern CLI replacements

4. **modules/vm/**
   - `qemu-guest.nix` - QEMU guest tools
   - `vm-detection.nix` - Hostname-based VM detection

### Phase 2: Create Base Profiles

**profiles/pentest-base.nix**:
```nix
{ config, pkgs, ... }: {
  imports = [
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix
    ../modules/desktop/i3.nix
    ../modules/desktop/polybar.nix
    ../modules/desktop/dunst.nix
    ../modules/desktop/rofi.nix
    ../modules/desktop/theming.nix
    ../modules/shell/fish.nix
    ../modules/shell/zoxide.nix
    ../modules/shell/cli-tools.nix
    ../modules/vm/qemu-guest.nix
    ../modules/vm/vm-detection.nix
    # Add pentesting-specific packages
  ];

  networking.hostName = "pentest-vm";
}
```

### Phase 3: Flake Setup

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }: {
    packages.x86_64-linux = {
      pentest-vm-base = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [ ./profiles/pentest-base.nix ];
        format = "qcow";
      };
    };
  };
}
```

### Phase 4: Copy Configurations

**configs/** directory structure:
```
configs/
├── i3/
│   └── config.base         # Template i3 config
├── polybar/
│   └── config.ini.template # Template polybar config
├── dunst/
│   └── dunstrc.template    # Template dunst config
├── rofi/
│   └── config.rasi         # Rofi theme
├── fish/
│   ├── config.fish         # Fish configuration
│   └── functions/          # Fish functions
└── alacritty/
    └── alacritty.toml      # Terminal config
```

---

## Key Insights & Decisions

### 1. Template System is Critical

All configs use templates with variables:
- `${MOD_KEY}` - Mod1 for VMs, Mod4 for host
- `${I3_FONT_SIZE}` - Resolution-based
- `${GAPS_INNER}` - Resolution-based
- `${POLYBAR_FONT_SIZE}` - Resolution-based

**Must preserve**: `load-display-config.sh` logic for setting these variables

### 2. VM Detection is Pervasive

Not just i3 modifier - affects:
- Compositor (picom)
- Display manager
- Resolution handling
- SPICE agent startup

**Must preserve**: Hostname-based VM detection in multiple places

### 3. Pywal is Central

Everything themes around pywal:
- Colors stored in `~/.cache/wal/`
- Multiple apps read from this cache
- `walrgb` orchestrates updates across all apps

**Must preserve**: The walrgb workflow and cache structure

### 4. startx + .xinitrc Pattern

User experience:
1. Boot to TTY
2. Type "x"
3. System starts

**Must preserve**: `services.xserver.displayManager.startx.enable = true`

### 5. Multi-Monitor Awareness

Everything handles multiple monitors:
- xrandr positioning (external above internal)
- Polybar launches on all monitors
- feh wallpaper restoration after xrandr

**Must preserve**: Multi-monitor detection in autostart.sh

---

## Scripts to Port

### Critical Scripts (Port First)
1. **walrgb.sh** - Central theming script
2. **autostart.sh** - i3 startup automation
3. **i3launch.sh** - Display resolution logic
4. **load-display-config.sh** - Set environment variables

### Supporting Scripts (Port Second)
5. **randomwalrgb.sh** - Random wallpaper
6. **nixwal.sh** - Update nix-colors
7. **wal-gtk.sh** - GTK theming
8. **zathuracolors.sh** - PDF reader colors
9. **lock.sh** - Screen lock
10. **alacritty.sh** - Terminal config updates

### From Splix
11. **hardware-identify.sh** - Hardware detection for router VMs
12. **deploy-vm.sh** - VM deployment automation

---

## Testing Checklist

### VM Boot Test
- [ ] VM boots to TTY
- [ ] Type "x" starts i3
- [ ] Alt (Mod1) is modifier key
- [ ] Display is 1920x1200 or 2560x1440
- [ ] No picom running
- [ ] SPICE agent running

### Desktop Environment Test
- [ ] i3 starts with correct gaps/fonts
- [ ] Polybar shows on all monitors
- [ ] Dunst notifications work
- [ ] Rofi launches with Super+d
- [ ] Wallpaper loads on startup

### Theming Test
- [ ] `walrgb /path/to/image.jpg` works
- [ ] Colors update in all apps
- [ ] Polybar restarts automatically
- [ ] Dunst uses new colors
- [ ] No RGB errors on non-ASUS hardware

### Shell Test
- [ ] Fish shell loads
- [ ] Starship prompt shows
- [ ] Zoxide works (`z` command)
- [ ] Abbreviations work (ls, gs, etc.)
- [ ] Vi keybindings active

### Multi-Monitor Test (Host)
- [ ] External monitor detected
- [ ] Positioned above internal
- [ ] Polybar on both displays
- [ ] Wallpaper spans correctly

---

## Current Implementation

### Repository Structure
```
modules/
├── base/          # Core system (nixos-base, users, networking, virt)
├── wm/            # i3-gaps + all graphical packages
├── shell/         # Fish + CLI tools
├── theming/       # Static color scheme options
└── vm/            # qemu-guest, shaping service

profiles/
├── pentest-base.nix    # Minimal base
└── pentest-full.nix    # Full pentest system with red theme

configs/           # (To be populated)
scripts/           # (To be populated)
```

### How It Works

**Build base image:**
```bash
nix build .#pentest-vm-base
# Small image with: NixOS base + git + shaping service
```

**Deploy VM:**
```bash
./deploy-vm.sh --type pentest --name grief
# Creates VM with hostname "pentest-grief"
```

**First boot:**
1. Shaping service detects VM type from hostname
2. Clones Hydrix repo to /etc/nixos/hydrix
3. Runs: nixos-rebuild switch --flake .#vm-pentest
4. Installs purpose-specific packages and configs
5. Marks as shaped, won't run again

**Updates:**
```bash
cd /etc/nixos/hydrix && git pull && nixos-rebuild switch --flake .#vm-pentest
```

### Static Theming

Colors defined in profile, templated into configs:
```nix
hydrix.colors = {
  accent = "#ea6c73";  # Red for pentest
  # ... full palette
};
```

**Planned schemes:**
- Pentest: Red
- Comms: Blue
- Browsing: Green
- Dev: Purple

---

## Next Steps

### Immediate (Phase 2)
- Copy config files from ~/dotfiles to configs/
- Port essential scripts to scripts/
- Adapt configs to use static color options
- Test build: `nix build .#pentest-vm-base`

### Soon (Phase 3)
- Create router profile (from ~/splix)
- Create additional VM type profiles (comms, browsing, dev)
- Port deployment scripts
- Test full workflow

### Eventually
- Deploy and test all VM types
- Replace ~/dotfiles and ~/splix
- Production use

---

## References

**Dotfiles**: `/home/traum/dotfiles`
**Splix**: `/home/traum/splix`
**Original Plan**: `/home/traum/Hydrix/PROJECT.md` (note: plan changed to new repo approach)

**Key dotfiles modules to study**:
- `modules/i3.nix` - WM setup
- `modules/packages.nix` - Package list
- `modules/users.nix` - User config
- `modules/configuration.nix` - Base system
- `modules/scripts.nix` - walrgb implementation
- `fish/config.fish` - Shell setup

**Key scripts to study**:
- `xorg/.xinitrc` - X startup
- `scripts/bash/autostart.sh` - i3 autostart
- `scripts/bash/i3launch.sh` - Display logic
- `scripts/bash/walrgb.sh` - Theming orchestration

---

## 🔄 CORRECT IMPLEMENTATION APPROACH (2025-11-27)

### Phase 1: Analysis (COMPLETED)
- ✅ Read dotfiles flake.nix for zephyrus and zenbook
- ✅ Identified hwconf.nix pattern (imports /etc/nixos/hardware-configuration.nix)
- ✅ Documented all modules used in working setup
- ✅ Understood base/machine-specific separation
- ✅ Created comprehensive implementation guide

### Phase 2: Base Modules (TODO)
Copy these modules from dotfiles → Hydrix:
- [ ] `configuration.nix` → `modules/base/configuration.nix`
- [ ] `hwconf.nix` → `modules/base/hardware-config.nix`
- [ ] `users.nix` → `modules/base/users.nix`
- [ ] `services.nix` → `modules/base/services.nix`
- [ ] `audio.nix` → `modules/base/audio.nix`
- [ ] `virt.nix` → `modules/base/virt.nix`

### Phase 3: Desktop Modules (TODO)
Copy these modules from dotfiles → Hydrix:
- [ ] `i3.nix` → `modules/desktop/i3.nix`
- [ ] `packages.nix` → `modules/desktop/packages.nix`
- [ ] `colors.nix` → `modules/desktop/colors.nix`

### Phase 4: Machine Profiles (TODO)
Create standalone machine profiles:
- [ ] Create `profiles/machines/zephyrus.nix` based on dotfiles version
  - Remove dotfiles import
  - Import router-generated config relatively
  - Keep all ASUS/NVIDIA/power configs
- [ ] Create `profiles/machines/zenbook.nix` based on dotfiles version
  - Follow same pattern as zephyrus

### Phase 5: Update Flake (TODO)
- [ ] Restructure flake.nix to match dotfiles pattern
- [ ] Ensure all imports are relative to Hydrix
- [ ] Match module list exactly to dotfiles (including commented modules)

### Phase 6: Validation (TODO)
- [ ] `nix flake check`
- [ ] `nixos-rebuild dry-build --flake .#zephyrus --impure`
- [ ] Test build on non-critical boot
- [ ] Verify all functionality
- [ ] Document any issues

### Critical Rules for Implementation
1. **READ FIRST, CODE SECOND**: Understand the working config before copying
2. **EXACT REPLICATION**: Match dotfiles structure exactly
3. **NO ASSUMPTIONS**: If unsure, read the source file
4. **RELATIVE PATHS**: All imports must be relative to Hydrix
5. **TEST INCREMENTALLY**: Build and test after each phase
6. **UPDATE GUIDE**: Document learnings in IMPLEMENTATION-GUIDE.md

---

*This document will be updated as implementation progresses.*
*Always refer to IMPLEMENTATION-GUIDE.md for detailed instructions.*
