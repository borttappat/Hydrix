# Hydrix Theming System - Migration & Architecture Guide

**Created**: 2025-11-30
**Status**: ✅ COMPLETE - Ready for Testing
**Goal**: Port dotfiles theming workflow to Hydrix with hybrid static/dynamic approach

**Last Build Test**: 2025-11-30 - `nixos-rebuild build` succeeded (2 minutes)

---

## Overview

This document details the migration of the complete theming system from `~/dotfiles` to `~/Hydrix`. The architecture supports both **static VM colors** (per VM type) and **dynamic host theming** (walrgb workflow) using the same template files and scripts.

---

## Current Dotfiles Theming Workflow

### Components

1. **`.xinitrc`** (`~/dotfiles/xorg/.xinitrc`)
   - Bootstraps X session
   - Detects VM vs host
   - Restores pywal colors (`wal -Rn`)
   - Loads display configuration
   - Generates configs from templates
   - Starts i3

2. **`load-display-config.sh`** (`~/dotfiles/scripts/bash/load-display-config.sh`)
   - Reads `display-config.json`
   - Detects current resolution
   - Applies machine-specific overrides
   - Exports variables for template substitution

3. **`links.sh`** (`~/dotfiles/scripts/bash/links.sh`)
   - Deploys template files to `~/.config`
   - Creates symlinks for all dotfiles
   - Manages config file placement

4. **`walrgb.sh`** (`~/dotfiles/scripts/bash/walrgb.sh`)
   - Runs pywal on wallpaper
   - Updates RGB lighting (asusctl/openrgb)
   - Restarts polybar
   - Updates all app colors
   - Orchestrates dynamic theming

### Template System

All configs use variable substitution:
- `${MOD_KEY}` - Mod1 (Alt) for VMs, Mod4 (Super) for host
- `${I3_FONT_SIZE}` - Resolution-based font sizing
- `${GAPS_INNER}` - Resolution-based gaps
- `${POLYBAR_FONT_SIZE}` - Resolution-based polybar sizing
- `${ALACRITTY_FONT_SIZE}` - Resolution-based terminal font
- And many more...

### Boot Flow

```
System Boot → TTY (auto-login)
    ↓
User types "x" (startx)
    ↓
.xinitrc executes
    ├─> wal -Rn (restore colors)
    ├─> load-display-config.sh (export variables)
    ├─> sed templates → actual configs
    └─> exec i3
         ↓
    autostart.sh runs
         ├─> xrandr (multi-monitor)
         ├─> picom (if not VM)
         └─> polybar
```

---

## Hydrix Architecture

### Key Insight

**Both VMs and hosts can use identical templates** by ensuring:
- VMs have a **static pywal cache** (generated once, never changes)
- Hosts have a **dynamic pywal cache** (updated via walrgb)

The templates don't care where colors come from - they just read `~/.cache/wal/`!

### Directory Structure

```
~/Hydrix/
├── configs/
│   ├── display-config.json          # Resolution/machine settings (from dotfiles)
│   ├── i3/
│   │   ├── config.template          # Variable-based i3 config
│   │   └── config.base              # Base i3 config (no variables)
│   ├── alacritty/
│   │   └── alacritty.toml.template  # Variable-based terminal config
│   ├── polybar/
│   │   └── config.ini.template      # Variable-based status bar config
│   ├── dunst/
│   │   └── dunstrc.template         # Variable-based notification config
│   ├── rofi/
│   │   └── config.rasi.template     # Variable-based launcher config
│   ├── fish/
│   │   └── config.fish              # Shell configuration
│   ├── firefox/
│   │   ├── profiles.ini
│   │   └── traum/
│   │       ├── user.js.template
│   │       └── chrome/
│   │           ├── userChrome.css.template
│   │           └── userContent.css.template
│   ├── xorg/
│   │   ├── .xinitrc                 # X session bootstrap
│   │   └── .Xmodmap                 # Key mappings
│   ├── zathura/
│   │   └── zathurarc                # PDF reader config
│   ├── ranger/
│   │   ├── rifle.conf
│   │   ├── rc.conf
│   │   └── scope.sh
│   ├── joshuto/
│   │   ├── joshuto.toml
│   │   ├── mimetype.toml
│   │   └── preview_file.sh
│   ├── starship/
│   │   └── starship.toml            # Prompt config
│   ├── htop/
│   │   └── htoprc                   # Process monitor config
│   ├── picom/
│   │   └── picom.conf               # Compositor config
│   └── wal/
│       └── templates/
│           └── dunstrc              # Pywal dunst template
│
├── scripts/
│   ├── walrgb.sh                    # Full dynamic theming (host machines)
│   ├── load-display-config.sh       # Variable provider for templates
│   ├── load-display-config.fish     # Fish version
│   ├── links.sh                     # Config deployment script
│   ├── vm-static-colors.sh          # NEW: Generate static pywal cache for VMs
│   ├── autostart.sh                 # i3 autostart logic
│   ├── nixwal.sh                    # Update nix-colors
│   ├── wal-gtk.sh                   # GTK theme integration
│   ├── zathuracolors.sh             # PDF reader colors
│   └── randomwalrgb.sh              # Random wallpaper + walrgb
│
├── modules/
│   ├── theming/
│   │   ├── base.nix                 # Shared theming infrastructure
│   │   ├── static-colors.nix        # VM type color definitions + static cache
│   │   └── dynamic.nix              # Host pywal/walrgb setup
│   └── desktop/
│       └── xinitrc.nix              # Manages .xinitrc deployment
│
└── profiles/
    ├── pentest-full.nix             # Imports theming/static-colors.nix
    ├── comms-full.nix               # Imports theming/static-colors.nix
    ├── browsing-full.nix            # Imports theming/static-colors.nix
    ├── dev-full.nix                 # Imports theming/static-colors.nix
    └── zephyrus.nix                 # Imports theming/dynamic.nix
```

---

## Implementation Plan

### Phase 1: Copy Configs & Scripts to Hydrix

**Configs to copy** (from `~/dotfiles` to `~/Hydrix/configs/`):
- `display-config.json`
- `i3/config.template`
- `i3/config.base`
- `alacritty/alacritty.toml.template`
- `polybar/config.ini.template`
- `dunst/dunstrc.template`
- `rofi/config.rasi.template`
- `fish/config.fish`
- `fish/fish_variables`
- `fish/functions/*.fish`
- `firefox/profiles.ini`
- `firefox/traum/user.js.template`
- `firefox/traum/chrome/*.template`
- `xorg/.xinitrc`
- `xorg/.Xmodmap`
- `xorg/.xsessionrc`
- `zathura/zathurarc`
- `ranger/*.conf` + `scope.sh`
- `joshuto/*.toml` + `preview_file.sh`
- `starship/starship.toml`
- `htop/htoprc`
- `picom/picom.conf`
- `wal/templates/dunstrc`

**Scripts to copy** (from `~/dotfiles/scripts/bash/` to `~/Hydrix/scripts/`):
- `walrgb.sh`
- `load-display-config.sh`
- `load-display-config.fish`
- `links.sh`
- `autostart.sh`
- `nixwal.sh`
- `wal-gtk.sh`
- `zathuracolors.sh`
- `randomwalrgb.sh`

### Phase 2: Create Static Color Generator

**New script**: `~/Hydrix/scripts/vm-static-colors.sh`

Purpose: Generates a static pywal cache for VMs based on VM type.

```bash
#!/usr/bin/env bash
# Generates a static pywal cache for VMs based on VM type

VM_TYPE="$1"  # pentest, comms, browsing, dev

case "$VM_TYPE" in
    pentest)
        COLOR_WALLPAPER="/path/to/red-wallpaper.jpg"
        ;;
    comms)
        COLOR_WALLPAPER="/path/to/blue-wallpaper.jpg"
        ;;
    browsing)
        COLOR_WALLPAPER="/path/to/green-wallpaper.jpg"
        ;;
    dev)
        COLOR_WALLPAPER="/path/to/purple-wallpaper.jpg"
        ;;
esac

# Generate pywal cache from wallpaper
wal -n -i "$COLOR_WALLPAPER"

# Mark as generated
touch ~/.cache/wal/.static-colors-generated
```

**Color Scheme Definitions**:
- **Pentest**: Red accent (#ea6c73) - aggressive, warning
- **Comms**: Blue accent (#6c89ea) - calm, communication
- **Browsing**: Green accent (#73ea6c) - safe, browsing
- **Dev**: Purple accent (#ba6cea) - creative, development

### Phase 3: Create Nix Modules

#### `modules/theming/base.nix` - Shared Infrastructure

```nix
{ config, pkgs, lib, ... }:

{
  # Install theming dependencies
  environment.systemPackages = with pkgs; [
    pywal
    jq  # For display-config.json parsing
    xorg.xrandr
    imagemagick  # For wal
  ];

  # Deploy scripts to system
  environment.systemPackages = [
    (pkgs.writeScriptBin "load-display-config"
      (builtins.readFile ../../scripts/load-display-config.sh))
  ];

  # Ensure .cache/wal directory exists for all users
  systemd.tmpfiles.rules = [
    "d /home/traum/.cache/wal 0755 traum users -"
  ];
}
```

#### `modules/theming/static-colors.nix` - For VMs

```nix
{ config, lib, pkgs, ... }:

{
  imports = [ ./base.nix ];

  # Add static color generator script
  environment.systemPackages = [
    (pkgs.writeScriptBin "vm-static-colors"
      (builtins.readFile ../../scripts/vm-static-colors.sh))
  ];

  # Generate static pywal cache on first boot
  systemd.services.vm-static-colors = {
    description = "Generate static color scheme for VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "traum";
      ExecStart = "${pkgs.bash}/bin/bash ${pkgs.writeScript "vm-colors" ''
        #!/usr/bin/env bash
        if [ ! -f /home/traum/.cache/wal/.static-colors-generated ]; then
          ${pkgs.writeScriptBin "vm-static-colors" (builtins.readFile ../../scripts/vm-static-colors.sh)}/bin/vm-static-colors ${config.hydrix.vmType}
        fi
      ''}";
    };
  };

  # Define VM type option
  options.hydrix.vmType = lib.mkOption {
    type = lib.types.enum [ "pentest" "comms" "browsing" "dev" ];
    description = "VM type for static color scheme";
  };
}
```

#### `modules/theming/dynamic.nix` - For Host

```nix
{ config, pkgs, ... }:

{
  imports = [ ./base.nix ];

  # Add full walrgb workflow
  environment.systemPackages = with pkgs; [
    (pkgs.writeScriptBin "walrgb" (builtins.readFile ../../scripts/walrgb.sh))
    (pkgs.writeScriptBin "randomwalrgb" (builtins.readFile ../../scripts/randomwalrgb.sh))
    (pkgs.writeScriptBin "nixwal" (builtins.readFile ../../scripts/nixwal.sh))
    (pkgs.writeScriptBin "wal-gtk" (builtins.readFile ../../scripts/wal-gtk.sh))
    (pkgs.writeScriptBin "zathuracolors" (builtins.readFile ../../scripts/zathuracolors.sh))

    pywalfox-native
    asusctl  # For ASUS hardware RGB
    openrgb  # For generic RGB
  ];
}
```

#### `modules/desktop/xinitrc.nix` - Deploy .xinitrc

```nix
{ config, pkgs, lib, ... }:

{
  # Enable startx
  services.xserver.displayManager.startx.enable = true;

  # Deploy configs using home-manager
  home-manager.users.traum = {
    # X session bootstrap
    home.file.".xinitrc".source = ../../configs/xorg/.xinitrc;
    home.file.".Xmodmap".source = ../../configs/xorg/.Xmodmap;

    # Template files
    home.file.".config/i3/config.template".source = ../../configs/i3/config.template;
    home.file.".config/i3/config.base".source = ../../configs/i3/config.base;
    home.file.".config/alacritty/alacritty.toml.template".source = ../../configs/alacritty/alacritty.toml.template;
    home.file.".config/polybar/config.ini.template".source = ../../configs/polybar/config.ini.template;
    home.file.".config/dunst/dunstrc.template".source = ../../configs/dunst/dunstrc.template;
    home.file.".config/rofi/config.rasi.template".source = ../../configs/rofi/config.rasi.template;

    # Display config
    home.file.".config/display-config.json".source = ../../configs/display-config.json;

    # Scripts
    home.file.".config/scripts/load-display-config.sh".source = ../../scripts/load-display-config.sh;
    home.file.".config/scripts/load-display-config.fish".source = ../../scripts/load-display-config.fish;

    # Other configs
    home.file.".config/fish/config.fish".source = ../../configs/fish/config.fish;
    home.file.".config/zathura/zathurarc".source = ../../configs/zathura/zathurarc;
    home.file.".config/starship/starship.toml".source = ../../configs/starship/starship.toml;
    home.file.".config/picom/picom.conf".source = ../../configs/picom/picom.conf;
    # ... etc for all other configs
  };
}
```

### Phase 4: Update Profiles

#### VM Profile Example (`profiles/pentest-full.nix`)

```nix
{ config, pkgs, ... }:

{
  imports = [
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/vm/qemu-guest.nix
    ../modules/wm/i3.nix
    ../modules/shell/fish.nix
    ../modules/theming/static-colors.nix  # Static VM theming
    ../modules/desktop/xinitrc.nix
  ];

  # Set VM type for static colors
  hydrix.vmType = "pentest";  # Generates red theme

  networking.hostName = "pentest-vm";
}
```

#### Host Profile Example (`profiles/zephyrus.nix`)

```nix
{ config, pkgs, ... }:

{
  imports = [
    # ... existing imports ...
    ../modules/theming/dynamic.nix  # Dynamic host theming
    ../modules/desktop/xinitrc.nix
  ];

  networking.hostName = "zephyrus";
}
```

---

## How It Works

### VM Workflow

1. **Build**: `nix build '.#pentest-vm-qcow'`
   - Includes `static-colors.nix` module
   - Sets `hydrix.vmType = "pentest"`

2. **First Boot**:
   - `vm-static-colors.service` runs
   - Generates red pywal cache → `~/.cache/wal/`
   - Marks as generated (`.static-colors-generated`)

3. **User types "x"**:
   - `.xinitrc` runs
   - `wal -Rn` restores static red colors
   - `load-display-config.sh` exports variables
   - Templates → configs (with red colors + VM variables)
   - i3 starts with red theme

4. **Subsequent boots**:
   - Same flow, always red
   - Static cache never changes

### Host Workflow

1. **Build**: `nixos-rebuild switch --flake .#zephyrus`
   - Includes `dynamic.nix` module
   - Deploys `walrgb` script

2. **User types "x"**:
   - `.xinitrc` runs
   - `wal -Rn` restores last dynamic colors
   - `load-display-config.sh` exports variables
   - Templates → configs
   - i3 starts

3. **User runs `walrgb wallpaper.jpg`**:
   - Generates new colors from wallpaper
   - Updates `~/.cache/wal/`
   - Updates RGB lighting
   - Restarts polybar
   - Updates all app colors

4. **Next boot**:
   - `wal -Rn` restores new colors
   - Workflow continues

---

## File Deployment Strategy

### Option 1: Bash Script (Initial)

Use modified `links.sh` in activation script:
```nix
system.activationScripts.linkHydrixConfigs = ''
  ${pkgs.bash}/bin/bash ${../../scripts/links.sh}
'';
```

### Option 2: NixOS home-manager (Preferred)

Deploy each file individually via `home.file` (shown in xinitrc.nix above).

**Pros**:
- Declarative
- Nix-managed
- Automatic cleanup

**Cons**:
- More verbose
- Requires listing every file

### Option 3: Hybrid

- Templates: home-manager
- Scripts: environment.systemPackages with writeScriptBin
- Configs: activation script

---

## Color Scheme Definitions

### Pentest (Red)
```
Accent: #ea6c73
Wallpaper: /path/to/red-themed.jpg
Purpose: Offensive security, penetration testing
Visual: Aggressive, warning, high-alert
```

### Comms (Blue)
```
Accent: #6c89ea
Wallpaper: /path/to/blue-themed.jpg
Purpose: Communication, messaging, email
Visual: Calm, trustworthy, communication
```

### Browsing (Green)
```
Accent: #73ea6c
Wallpaper: /path/to/green-themed.jpg
Purpose: Web browsing, research
Visual: Safe, natural, browsing
```

### Dev (Purple)
```
Accent: #ba6cea
Wallpaper: /path/to/purple-themed.jpg
Purpose: Development, coding, building
Visual: Creative, technical, development
```

---

## Testing Checklist

### VM Testing (Static Colors)
- [ ] Build pentest VM
- [ ] First boot generates red static cache
- [ ] Type "x" starts i3 with red theme
- [ ] Polybar is red
- [ ] Dunst notifications are red
- [ ] Rofi launcher is red
- [ ] Static cache persists across reboots
- [ ] Colors never change

### Host Testing (Dynamic Colors)
- [ ] Build on zephyrus
- [ ] Type "x" starts i3 with last colors
- [ ] `walrgb` command available
- [ ] `walrgb wallpaper.jpg` updates all colors
- [ ] Polybar restarts automatically
- [ ] RGB lighting updates
- [ ] Next boot restores new colors

### Template Testing
- [ ] Resolution detection works
- [ ] Machine overrides apply (zen high-DPI)
- [ ] External monitor detection works
- [ ] Font sizes scale correctly
- [ ] Gaps scale with resolution
- [ ] VM mod key is Alt (Mod1)
- [ ] Host mod key is Super (Mod4)

---

## Migration Checklist

### Phase 1: File Migration
- [ ] Create `~/Hydrix/configs/` directory structure
- [ ] Copy all template files from dotfiles
- [ ] Create `~/Hydrix/scripts/` directory
- [ ] Copy all scripts from dotfiles
- [ ] Update script paths to reference Hydrix

### Phase 2: Static Color System
- [ ] Create `vm-static-colors.sh`
- [ ] Gather/create VM type wallpapers (red, blue, green, purple)
- [ ] Test static color generation manually

### Phase 3: Nix Modules
- [ ] Create `modules/theming/base.nix`
- [ ] Create `modules/theming/static-colors.nix`
- [ ] Create `modules/theming/dynamic.nix`
- [ ] Create `modules/desktop/xinitrc.nix`
- [ ] Test module imports

### Phase 4: Profile Updates
- [ ] Update `profiles/pentest-full.nix`
- [ ] Update `profiles/comms-full.nix`
- [ ] Update `profiles/browsing-full.nix`
- [ ] Update `profiles/dev-full.nix`
- [ ] Update `profiles/zephyrus.nix`

### Phase 5: Testing
- [ ] Build and test pentest VM
- [ ] Build and test on zephyrus
- [ ] Verify walrgb workflow
- [ ] Verify static colors persist
- [ ] Test all templates generate correctly

### Phase 6: Cleanup
- [ ] Remove bash dependencies where possible
- [ ] Convert scripts to pure Nix
- [ ] Optimize activation scripts
- [ ] Document any gotchas

---

## Future Nixification

Once the bash-based system is working, these can be converted to pure Nix:

1. **Template Generation**: Use `substituteAll` in Nix instead of sed
2. **Color Definitions**: Move to Nix attrsets instead of bash case statements
3. **Display Config**: Parse JSON in Nix instead of bash+jq
4. **File Deployment**: Use home-manager exclusively

**Philosophy**: Get it working with bash first, optimize later.

---

## Key Benefits

✅ **Same templates everywhere** - No duplication between host/VM
✅ **Same .xinitrc logic** - Proven workflow preserved
✅ **Static VM colors** - Declarative per type (red/blue/green/purple)
✅ **Dynamic host theming** - Full walrgb capability maintained
✅ **Self-contained** - No dependency on ~/dotfiles after migration
✅ **Nix-managed** - Deployed via modules, not manual symlinking
✅ **Incremental migration** - Can convert to pure Nix gradually

---

## Troubleshooting

### Static colors not generating in VM
- Check `systemctl status vm-static-colors.service`
- Verify wallpaper paths exist
- Check pywal is installed
- Verify user permissions on `~/.cache/wal/`

### Templates not generating configs
- Verify `load-display-config.sh` is executable
- Check `display-config.json` is accessible
- Verify all template variables are exported
- Check sed syntax in `.xinitrc`

### walrgb not working on host
- Verify pywal is installed
- Check script is in PATH
- Verify RGB tools (asusctl/openrgb) are available
- Check pywalfox-native is installed

### Colors not persisting across reboots
- Verify `wal -Rn` runs in `.xinitrc`
- Check `~/.cache/wal/` directory exists
- Verify wal cache has colors file

---

**Next Steps**: Begin Phase 1 - Copy configs and scripts to Hydrix.

---

## ✅ IMPLEMENTATION COMPLETE (2025-11-30)

All phases completed successfully. System ready for deployment.

### What Was Implemented:

**Phase 1: File Migration** ✅
- Copied all configs from ~/dotfiles/configs/ → ~/Hydrix/configs/
- Copied all scripts from ~/dotfiles/scripts/bash/ → ~/Hydrix/scripts/
- Created directory structure for all config types

**Phase 2: Static Color System** ✅
- Created `vm-static-colors.sh` for VM type-based color generation
- Defined 4 color schemes (pentest=red, comms=blue, browsing=green, dev=purple)
- Generates full 16-color pywal-compatible palette

**Phase 3: Nix Modules** ✅
- `modules/theming/base.nix` - Core dependencies (pywal, jq, xrandr)
- `modules/theming/static-colors.nix` - VM static color service
- `modules/theming/dynamic.nix` - Host walrgb workflow
- `modules/desktop/xinitrc.nix` - Config deployment via home-manager

**Phase 4: Script Path Updates** ✅
- All ~/dotfiles references → ~/.config/
- Scripts deployed via writeScriptBin to PATH
- Fish config cleaned up (removed dotfiles function wrappers)
- i3 config updated to use ~/.config/scripts/

**Phase 5: Integration** ✅
- Added home-manager to all flake configurations
- Set home.stateVersion = "25.05"
- Updated flake.nix for correct home-manager version (release-25.05)
- Fixed duplicate environment.systemPackages in base.nix

### Build Status:

```bash
# Tested commands (all succeeded):
nixos-rebuild dry-build --flake '.#zephyrus' --impure  ✅ (warnings only)
nixos-rebuild build --flake '.#zephyrus' --impure      ✅ (2 minutes)
```

### Ready for Deployment:

```bash
sudo nixos-rebuild switch --flake '.#zephyrus' --impure
```

After rebuild, the system will:
1. Deploy all configs to ~/.config/ via home-manager
2. Add scripts to PATH (walrgb, nixwal, alacritty.sh, etc.)
3. Maintain same boot workflow: TTY → "x" → i3
4. Support dynamic theming with `walrgb /path/to/wallpaper.jpg`

### Comparison with Dotfiles:

| Aspect | Dotfiles | Hydrix |
|--------|----------|--------|
| Config deployment | Manual (`links.sh`) | Automatic (home-manager) |
| Script location | `~/dotfiles/scripts/bash/` | System PATH |
| Theming | `walrgb.sh` via full path | `walrgb` command |
| Template processing | `.xinitrc` (same) | `.xinitrc` (same) |
| Resolution detection | `load-display-config.sh` | `load-display-config.sh` |
| Monitor-aware terminal | `alacritty.sh` | `alacritty.sh` |

**The workflow is identical, just self-contained in Hydrix.**

---

## Next Steps After Deployment

1. **Test X session**: Type "x" at TTY, verify i3 starts
2. **Test theming**: Run `walrgb ~/Wallpapers/some-image.jpg`
3. **Test scripts**: Verify all PATH scripts work (nixwal, zathuracolors, etc.)
4. **Test multi-monitor**: Verify alacritty.sh scales correctly on external monitors
5. **Build VM**: Test `nix build '.#base-vm-qcow'` with new theming

