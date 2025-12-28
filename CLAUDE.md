# Hydrix - Project Context for Claude

## Project Overview

Hydrix is a NixOS-based VM isolation system designed for security-conscious workflows. It provides:
- Host machine with WiFi passthrough to a router VM
- Isolated network bridges for different VM categories (pentest, office, browsing, dev)
- Specialisation-based boot modes (router, lockdown, fallback)
- Template-based machine configuration generation
- **Local secrets management** - Personal info abstracted to gitignored `local/` directory

**Key Goal**: This setup should be usable by anyone, not just the original author. Personal info is in `local/` (gitignored), allowing the repo to be public.

## Architecture

### Network Layout
```
Host Machine
├── br-mgmt     (192.168.100.x) - Management, host-router communication
├── br-pentest  (192.168.101.x) - Pentesting VMs [ISOLATED]
├── br-office   (192.168.102.x) - Office/comms VMs [ISOLATED]
├── br-browse   (192.168.103.x) - Browsing VMs [ISOLATED]
├── br-dev      (192.168.104.x) - Development VMs [ISOLATED]
└── br-shared   (192.168.105.x) - Shared bridge [CROSSTALK ALLOWED]

Router VM (WiFi passthrough)
├── Handles all internet connectivity
├── DHCP for each bridge
├── NAT to internet
├── VPN policy routing (lockdown mode)
└── Bridge isolation enforcement (nftables)

Bridge Isolation:
  - Isolated bridges (pentest, office, browse, dev) cannot communicate directly
  - br-shared allows VMs to talk to each other across bridge boundaries
  - All VMs can still access internet through router VM
```

### Boot Modes (Specialisations)
- **Default (router)**: WiFi passed to router VM, bridges active, host has internet via router
- **Lockdown**: Same as router but host firewall blocks all outbound (VMs still have internet)
- **Fallback**: Emergency mode - re-enables WiFi on host, disables VFIO, normal networking

## Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | Initial machine setup - detects hardware, creates configs, prompts for password |
| `scripts/nixbuild.sh` | Rebuilds host/VMs using hostname-based flake detection (uses --impure) |
| `scripts/build-vm.sh` | Deploys VM instances from base images |
| `scripts/hardware-identify.sh` | Detects WiFi hardware for VFIO passthrough |

## Critical Design Principles

### 1. Modularity
- **Every key setting belongs in a base module**, not scattered across configs
- Profiles add task-specific packages/settings on top of base
- If migrating settings to new modules, **remove from VM-specific configs**
- VMs should import base modules, not duplicate settings

### 2. Template-Based Generation
- Machine profiles generated from `templates/machine-profile-full.nix.template`
- setup.sh populates placeholders with detected values
- Allows easy modification without touching scripts

### 3. Hostname-Based Detection
- `nixbuild.sh` uses hostname directly as flake target
- No hardcoded machine lists needed
- VMs: hostname pattern `<type>-<name>` → flake `vm-<type>`

### 4. Secrets Management (✅ IMPLEMENTED)
- Local gitignored `local/` directory contains all personal/sensitive data
- Host secrets in `local/host.nix` (username, password hash, SSH keys)
- VM secrets isolated per-type in `local/vms/<type>.nix`
- Shared non-secret config in `local/shared.nix` (timezone, locale, keyboard)
- Modules read via `--impure` flag (required for `builtins.getEnv`)
- setup.sh auto-detects settings from `/etc/nixos/configuration.nix` and prompts for password
- **Principle of least privilege**: VMs only access their specific secrets, never host secrets

## Local Config Structure

```
local/                           # gitignored - your secrets
├── host.nix                    # Host-only: username, password hash, SSH keys
├── shared.nix                  # Non-secret: timezone, locale, keyboard (all systems)
└── vms/
    ├── router.nix              # Router VM secrets only
    ├── pentest.nix             # Pentest VM secrets only
    ├── browsing.nix            # Browsing VM secrets only
    ├── office.nix              # Office VM secrets only
    └── dev.nix                 # Dev VM secrets only

templates/local/                 # committed - examples for new users
├── README.md                   # Setup instructions
├── host.nix.example
├── shared.nix.example
└── vms/
    └── vm.nix.example
```

**Security Model**: Each VM only accesses its own secrets file. Host secrets are never exposed to VMs.

## Current TODO List

### High Priority - Core Functionality
1. **Test lockdown mode** - Verify host isolation while VMs retain internet access
2. ~~**VM workspace workflow**~~ - ✅ Xpra implemented for seamless windows
3. Set up shared folders between host and each VM (virtiofs or 9p)
4. **Per-VM-type Firefox extensions** - Different extension sets per VM type:
   - **Core (all VMs)**: Vimium/Tridactyl (vim bindings)
   - **Browsing VM**: uBlock Origin, Privacy Badger, privacy-focused extensions
   - **Pentest VM**: Wappalyzer, cookie editors, HackTools, FoxyProxy, scanner extensions
   - **Office VM**: Minimal, productivity-focused
   - **Dev VM**: React/Vue devtools, JSON viewers, etc.

### Medium Priority - Polish
3. Add LUKS encryption to VM builds with auto-generated passwords
4. Create `modules/base/locale.nix` - Centralized locale/keyboard module (currently in local/shared.nix)
5. Create `modules/base/disk.nix` - LUKS/boot settings module

### Cleanup (Deferred)
6. Remove obsolete files: `add-machine.sh`, old templates, `.bak` files
7. Remove or update obsolete modules: `hydrix-embed.nix`, `shaping.nix` (replaced by full VM setup)

## Recently Completed

- ✅ **Bridge isolation implemented** - Isolated bridges (pentest, office, browse, dev) cannot communicate directly
- ✅ **br-shared bridge added** - Allows crosstalk between VMs that need to communicate
- ✅ **nftables firewall rules** - Enforces isolation in both standard and lockdown modes
- ✅ **Browsing VM colorscheme fixed** - nvid.json now applying correctly
- ✅ **Firefox extensions fixed** - Extensions now loading in all VM types
- ✅ Local secrets management system implemented
- ✅ Password prompting during setup.sh
- ✅ Per-VM secrets isolation
- ✅ Auto-detection of locale/timezone/keyboard from system
- ✅ Host setup tested on Zenbook (Intel + ASUS)
- ✅ **VMs hardcoded to always use "user"** - Fixed unpredictable username switching (was picking up host env vars)
- ✅ All VM profiles now have consistent setup (hydrix-clone, Firefox, static colors, xinitrc)
- ✅ Fish config updated with `nb` alias for smart rebuilding
- ✅ Firefox fonts fixed in VMs
- ✅ Font changed from Cozette to Tamzen
- ✅ Fish shell standalone (removed all dotfiles references)
- ✅ BloodHound devShell added to flake.nix

## Files to Eventually Clean Up

| File | Status | Reason |
|------|--------|--------|
| `add-machine.sh` | Keep for now | Obsolete - replaced by setup.sh |
| `scripts/setup-machine.sh.bak` | Keep for now | Backup of old script |
| `templates/flake-entry.nix.template` | Keep for now | Only used by obsolete add-machine.sh |
| `templates/router-vm-config.nix.template` | Keep for now | Not used - config is in modules/ |
| `modules/vm/hydrix-embed.nix` | Obsolete | Replaced by full VM setup |
| `modules/vm/shaping.nix` | Obsolete | Replaced by full VM setup |

## Module Structure

```
modules/
├── base/
│   ├── configuration.nix       # Core system config
│   ├── hardware-config.nix     # Hardware (imported from /etc/nixos)
│   ├── users.nix               # Host user accounts (reads from local/host.nix)
│   ├── users-vm.nix            # VM user accounts (isolated, uses "user")
│   ├── local-config.nix        # Local config importer (with VM isolation)
│   ├── system-config.nix       # Performance and desktop essentials
│   ├── services.nix            # System services
│   ├── virt.nix                # Virtualization (libvirt, etc.)
│   ├── audio.nix               # Audio configuration
│   └── hardware/
│       ├── intel.nix           # Intel-specific (graphics, microcode)
│       └── asus.nix            # ASUS-specific (asusd)
├── desktop/
│   ├── firefox.nix             # Firefox with extensions (dynamic username)
│   └── xinitrc.nix             # X session and config deployment (dynamic username)
├── shell/
│   ├── fish.nix                # Fish shell configuration
│   ├── fish-home.nix           # Fish home-manager config (dynamic username)
│   └── packages.nix            # Shell packages
├── theming/
│   ├── base.nix                # Theming infrastructure (VM user: "user")
│   ├── colors.nix              # Dynamic theming (host)
│   ├── static-colors.nix       # Static VM colors (VM user: "user")
│   └── dynamic.nix             # Dynamic pywal theming
├── wm/
│   └── i3.nix                  # i3 window manager
├── pentesting/
│   └── pentesting.nix          # Pentest tools and setup (VM user: "user")
├── vm/
│   ├── qemu-guest.nix          # QEMU/SPICE guest configuration
│   ├── xpra.nix                # Xpra server for seamless window forwarding
│   ├── hydrix-clone.nix        # Clone Hydrix repo on first boot
│   └── networking.nix          # VM networking (DHCP)
├── core.nix                    # Core essentials for all systems (includes xpra)
├── router-vm-unified.nix       # Router VM configuration
└── lockdown/
    └── router-vm-config.nix    # Lockdown router variant
```

## VM Configuration Pattern

VMs use isolated user configuration and secrets:

```nix
{ config, pkgs, lib, ... }:
{
  imports = [
    # Base modules (shared settings)
    ../modules/base/users-vm.nix     # VM user ("user", not host user)
    ../modules/base/networking.nix
    # ... other base modules
  ];

  # VM-specific overrides only
  networking.hostName = "browsing-vm";
  hydrix.vmType = "browsing";

  # Type-specific packages
  environment.systemPackages = with pkgs; [
    # browsing-specific tools...
  ];
}
```

**Key Point**: VMs use `users-vm.nix` which creates user "user" and reads from `local/vms/<type>.nix` for secrets. Host uses `users.nix` which reads from `local/host.nix`.

## Dynamic Username Pattern

All modules that reference usernames now use dynamic detection:

```nix
let
  hydrixPath = builtins.getEnv "HYDRIX_PATH";
  sudoUser = builtins.getEnv "SUDO_USER";
  currentUser = builtins.getEnv "USER";
  effectiveUser = if sudoUser != "" then sudoUser
                  else if currentUser != "" && currentUser != "root" then currentUser
                  else "user";
  basePath = if hydrixPath != "" then hydrixPath else "/home/${effectiveUser}/Hydrix";
  hostConfigPath = "${basePath}/local/host.nix";

  hostConfig = if builtins.pathExists hostConfigPath
    then import hostConfigPath
    else null;

  username = if hostConfig != null && hostConfig ? username
    then hostConfig.username
    else "user";
in
  # Use ${username} in configurations
```

This pattern is used in:
- `modules/base/users.nix`
- `modules/base/system-config.nix`
- `modules/desktop/firefox.nix`
- `modules/desktop/xinitrc.nix`
- `modules/shell/fish-home.nix`
- `modules/core.nix`

## Theming System (✅ IMPLEMENTED)

Hydrix uses a pywal-based theming system with static colorschemes for reproducible builds.

### Colorscheme Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        COLORSCHEME SOURCES                          │
├─────────────────────────────────────────────────────────────────────┤
│  colorschemes/*.json     Named schemes (perp, nebula, nord, etc.)   │
│  vmType fallback         Auto-generated from type (pentest=red...)  │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     CONFIGURATION (Nix)                             │
├─────────────────────────────────────────────────────────────────────┤
│  hydrix.colorscheme = "perp";   # Use named scheme from JSON        │
│  hydrix.vmType = "host";        # Fallback if no colorscheme set    │
│                                                                     │
│  Priority: colorscheme > vmType fallback                            │
│  Default stored in: /etc/hydrix-colorscheme                         │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     RUNTIME SCRIPTS                                 │
├─────────────────────────────────────────────────────────────────────┤
│  walrgb           Change colors on the fly (picks random wallpaper) │
│  randomwalrgb     Random wallpaper + colors                         │
│  restore-colorscheme   Restore to default from /etc/hydrix-colorscheme │
│  apply-colorscheme <file.json>   Apply specific JSON colorscheme   │
│  vm-static-colors <type>   Generate colors for vmType              │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     GENERATED FILES                                 │
├─────────────────────────────────────────────────────────────────────┤
│  ~/.cache/wal/colors.json       Full colorscheme                    │
│  ~/.cache/wal/colors            Simple color list                   │
│  ~/.cache/wal/colors.css        CSS variables                       │
│  ~/.cache/wal/sequences         Terminal escape sequences           │
│  ~/.cache/wal/.static-colors-generated   Marker file               │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `modules/theming/static-colors.nix` | Colorscheme application logic, scripts |
| `colorschemes/*.json` | Named colorschemes (pywal format) |
| `configs/xorg/.xinitrc` | Applies colors on X startup |
| `scripts/walrgb.sh` | Runtime colorscheme changer |
| `scripts/save-colorscheme.sh` | Save current pywal colors as named scheme |

### Usage

**Set default colorscheme in machine profile:**
```nix
# In profiles/machines/<hostname>.nix
hydrix.vmType = "host";
hydrix.colorscheme = "perp";  # Uses colorschemes/perp.json
```

**Change colors on the fly:**
```bash
walrgb                    # Random wallpaper, generate colors
randomwalrgb              # Same as walrgb
restore-colorscheme       # Restore to default from config
```

**Save current colors as new scheme:**
```bash
wal -i /path/to/wallpaper.jpg
./scripts/save-colorscheme.sh my-theme
# Creates colorschemes/my-theme.json
```

### Template Default

New machines created via `setup.sh` use `hydrix.colorscheme = "nvid"` by default.
This is set in `templates/machine-profile-full.nix.template`.

## Bridge Isolation (✅ IMPLEMENTED)

Bridge isolation is enforced via nftables on the router VM:

| Bridge | Subnet (Standard) | Subnet (Lockdown) | Isolation |
|--------|-------------------|-------------------|-----------|
| br-mgmt | 192.168.100.x | 10.100.0.x | Management only |
| br-pentest | 192.168.101.x | 10.100.1.x | **ISOLATED** |
| br-office | 192.168.102.x | 10.100.2.x | **ISOLATED** |
| br-browse | 192.168.103.x | 10.100.3.x | **ISOLATED** |
| br-dev | 192.168.104.x | 10.100.4.x | **ISOLATED** |
| br-shared | 192.168.105.x | 10.100.5.x | **CROSSTALK ALLOWED** |

How isolation works:
- VMs on isolated bridges can only reach the router and internet
- VMs on isolated bridges CANNOT reach VMs on other isolated bridges
- VMs on `br-shared` can talk to any VM on any bridge
- To allow two VMs to communicate, either:
  - Put both on `br-shared`
  - Or put one on `br-shared` and it can reach the other

Deploy a VM to br-shared:
```bash
./scripts/build-vm.sh --type dev --name shared-vm --bridge br-shared
```

## Shared Folders (TODO)

Each VM should have access to a shared folder with the host:
- Use virtiofs (preferred) or 9p
- Mount at `/shared` or similar in VM
- Host path: `/home/<user>/shared/<vm-type>/` or similar
- Allows easy file transfer without network

## VM Window Forwarding - Xpra (IMPLEMENTED)

Xpra enables seamless window forwarding from VMs to the host, allowing individual VM applications to appear as native windows on the host desktop.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           HOST (zen)                                │
├─────────────────────────────────────────────────────────────────────┤
│  Host has IPs on all bridges for direct VM communication:          │
│    br-pentest: 192.168.101.1    br-browse: 192.168.103.1           │
│    br-office:  192.168.102.1    br-dev:    192.168.104.1           │
│    br-shared:  192.168.105.1                                        │
│                                                                     │
│  Commands: xpra-browsing, xpra-pentest, xpra-dev, xpra-comms       │
│  Help: xpra-help                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│  Browsing VM  │   │  Pentest VM   │   │   Dev VM      │
│  Port: 14501  │   │  Port: 14500  │   │  Port: 14504  │
│  Prefix:[BRW] │   │  Prefix:[PTX] │   │  Prefix:[DEV] │
│               │   │               │   │               │
│ xpra-start    │   │ xpra-start    │   │ xpra-start    │
│ (auto on X)   │   │ (auto on X)   │   │ (auto on X)   │
└───────────────┘   └───────────────┘   └───────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `modules/vm/xpra.nix` | VM: Xpra server, firewall, helper scripts, dconf |
| `modules/desktop/xpra-host.nix` | Host: Bridge IPs, attach scripts, vm-run |
| `configs/xorg/.xinitrc` | Auto-starts xpra-start on VM login |
| `configs/i3/config.template` | Keybindings for VM attachment |

### Xpra Port Assignments

| VM Type  | Port  | Bridge      | Title Prefix |
|----------|-------|-------------|--------------|
| pentest  | 14500 | br-pentest  | [PTX]        |
| browsing | 14501 | br-browse   | [BRW]        |
| office   | 14502 | br-office   | [OFC]        |
| comms    | 14503 | br-office   | [COM]        |
| dev      | 14504 | br-dev      | [DEV]        |

### Host Commands

```bash
# Auto-discovery attach (finds VM automatically)
xpra-browsing          # Attach to browsing VM
xpra-pentest           # Attach to pentest VM
xpra-dev               # Attach to dev VM
xpra-comms             # Attach to comms VM
xpra-attach <type>     # Generic: browsing|pentest|dev|comms|ip:port

# Launch apps in VMs via SSH
vm-run browsing firefox
vm-run browsing obsidian
vm-run pentest burpsuite

# Discovery
xpra-list-vms          # Scan for running VMs with Xpra

# Help
xpra-help              # Full command reference
```

### VM Commands

```bash
# Xpra server management (auto-starts on X login)
xpra-start             # Start Xpra server on :100
xpra-stop              # Stop Xpra server
xpra-restart           # Restart Xpra server
xpra-info              # Show status and connection info

# Run apps through Xpra (visible on host)
xpra-run firefox
xpra-run alacritty
xpra-run obsidian

# Help
xpra-help              # Full command reference
```

### i3 Keybindings (Host)

| Binding | Action |
|---------|--------|
| `Mod+F9` | Attach to browsing VM |
| `Mod+F10` | Attach to pentest VM |
| `Mod+F11` | Attach to dev VM |
| `Mod+Shift+F9` | Attach to comms VM |
| `Mod+Shift+o` | Launch Obsidian in browsing VM |
| `Mod+Shift+a` | Launch Claude (firefox) in browsing VM |

### Workflow

1. **Start VM** via virt-manager or `build-vm.sh`
2. **VM auto-starts Xpra** when X session begins (via xinitrc)
3. **From host**, attach: `xpra-browsing` (or use `Mod+F9`)
4. **In VM**, run apps: `xpra-run firefox`
5. **Apps appear** as windows on host desktop
6. **Detach** with `Ctrl+C` or close tray icon

### Packages Installed

**VM** (`modules/vm/xpra.nix`):
- xpra, python3Packages.{numpy,pillow,pygobject3}
- dconf, glib, libnotify (fixes GTK warnings)
- `programs.dconf.enable = true`

**Host** (`modules/desktop/xpra-host.nix`):
- xpra, python3Packages.{numpy,pillow,pygobject3}
- libnotify, glib
- `programs.dconf.enable = true`

### Fallback: Fullscreen VMs per Workspace

If Xpra doesn't meet needs, use virt-manager with fullscreen per workspace:

1. **virt-manager** (current): Double-click VM, press `Super+f` for fullscreen
2. **virt-viewer**: `virt-viewer --connect qemu:///system <vm-name>` (no menu bar)
3. **remote-viewer**: `remote-viewer spice://127.0.0.1:<port>` (direct SPICE)

### Status

- [x] Xpra server module with auto-start (`modules/vm/xpra.nix`)
- [x] Host module with bridge IPs and attach scripts (`modules/desktop/xpra-host.nix`)
- [x] Auto-start xpra on VM X login (xinitrc)
- [x] i3 keybindings for VM attachment
- [x] `xpra-help` command on both host and VM
- [x] dconf/GTK deps to fix warnings
- [ ] Test title prefix for origin indication
- [ ] i3 window rules for VM-specific border colors (optional)

## Home-Manager Troubleshooting

Home-manager runs as a NixOS module via `home-manager-<username>.service`. If configs aren't being applied:

**Check status:**
```bash
systemctl status home-manager-traum.service
journalctl -u home-manager-traum.service -n 30
```

**Common fix - file conflicts:**
```bash
# Remove conflicting files blocking home-manager
rm ~/.xinitrc                              # If manually symlinked
rm ~/.config/zathura/zathurarc.hm-backup   # Old backup blocking new backup

# Restart home-manager
sudo systemctl restart home-manager-traum.service
```

**Force fresh rebuild (if caching issues):**
```bash
nix build ~/Hydrix#nixosConfigurations.zen.config.system.build.toplevel --impure --no-link
sudo nixos-rebuild switch --flake ~/Hydrix#zen --impure
```

**Note:** New bridges require a reboot to be created. If `router-vm-autostart` fails waiting for a bridge, reboot the system.

## Important Commands

```bash
# Initial setup (new machine)
./scripts/setup.sh
# - Detects hardware, locale, timezone, keyboard
# - Prompts for password (secure, hashed)
# - Generates local/ directory with your settings
# - Creates machine profile
# - Builds router VM and system

# Rebuild (works on BOTH host and VMs - auto-detects)
nb
# Or: ~/Hydrix/scripts/nixbuild.sh
# - On host: rebuilds host configuration with specialisation detection
# - On VM: rebuilds VM without pulling (preserves local changes)
# - Automatically uses --impure flag

# Pull and rebuild (VMs only - when you want upstream changes)
cd ~/Hydrix && git pull && nb

# Deploy a VM
./scripts/build-vm.sh --type browsing --name test

# Switch boot modes (host only - requires reboot)
sudo nixos-rebuild boot --flake ~/Hydrix#<hostname> --impure
sudo nixos-rebuild boot --flake ~/Hydrix#<hostname> --specialisation lockdown --impure
sudo nixos-rebuild boot --flake ~/Hydrix#<hostname> --specialisation fallback --impure

# Change password after setup
mkpasswd -m sha-512
# Then edit ~/Hydrix/local/host.nix with the new hash
```

## VM User Information

**IMPORTANT**: VMs always use the username **"user"**, NOT the host username.

- **Host**: Uses your personal username from `local/host.nix` (e.g., "traum")
- **VMs**: Hardcoded to always use "user" (set in `modules/base/users-vm.nix`)
- **Why**: VMs don't have access to `local/` directory (gitignored), so hardcoding prevents unpredictable behavior
- **Custom usernames**: Edit `modules/base/users-vm.nix` directly if needed

When you `su user` on the host, it fails because that user only exists in VMs. This is correct behavior!

## Known Issues

*No critical issues currently tracked.*

## Notes for Contributors

- **Always use --impure** when rebuilding (local config requires it)
- **Never commit local/** - Contains secrets and personal info
- **Test on fresh install** - Use templates/local/*.example to verify portability
- **VMs use "user"** - Standard VM username, never use hardcoded personal usernames
- **Host uses local/host.nix** - Dynamic username from local config
