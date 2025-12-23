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
├── br-pentest  (192.168.101.x) - Pentesting VMs
├── br-office   (192.168.102.x) - Office/comms VMs
├── br-browse   (192.168.103.x) - Browsing VMs
└── br-dev      (192.168.104.x) - Development VMs

Router VM (WiFi passthrough)
├── Handles all internet connectivity
├── DHCP for each bridge
├── NAT to internet
└── VPN policy routing (lockdown mode)
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

### Immediate Priority - VM Issues
1. **Fix browsing VM colorscheme** - nvid.json exists but not applying to cursor/terminal like pentest VM (mardu.json) does
2. **Remove git pull from VM rebuild scripts** - All VM profiles (pentest, browsing, comms, dev) auto-pull, breaking local changes
3. **Commit fish config updates** - nb alias now calls ~/Hydrix/scripts/nixbuild.sh

### High Priority - Core Functionality
4. Set up shared folders between host and each VM (virtiofs or 9p)
5. Isolate br-* bridges from each other (VMs on same bridge can communicate, not across bridges)

### Medium Priority - Polish
6. Change font from Cozette to Tamzen - Update across all VMs and host configs
7. Add LUKS encryption to VM builds with auto-generated passwords
8. Create `modules/base/locale.nix` - Centralized locale/keyboard module (currently in local/shared.nix)
9. Create `modules/base/disk.nix` - LUKS/boot settings module

### Cleanup (Deferred)
10. Remove obsolete files: `add-machine.sh`, old templates, `.bak` files
11. Remove or update obsolete modules: `hydrix-embed.nix`, `shaping.nix` (replaced by full VM setup)

## Recently Completed

- ✅ Local secrets management system implemented
- ✅ Password prompting during setup.sh
- ✅ Per-VM secrets isolation
- ✅ Auto-detection of locale/timezone/keyboard from system
- ✅ Host setup tested on Zenbook (Intel + ASUS)
- ✅ **VMs hardcoded to always use "user"** - Fixed unpredictable username switching (was picking up host env vars)
- ✅ All VM profiles now have consistent setup (hydrix-clone, Firefox, static colors, xinitrc)
- ✅ Fish config updated with `nb` alias for smart rebuilding

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
├── core.nix                    # Core essentials for all systems (dynamic username)
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

## Bridge Isolation Requirements

Each br-* bridge should be isolated:
- VMs on `br-pentest` can communicate with each other
- VMs on `br-pentest` CANNOT reach VMs on `br-office`, `br-browse`, etc.
- All bridges route through router VM for internet
- Router VM manages inter-bridge policy (default: deny)

## Shared Folders (TODO)

Each VM should have access to a shared folder with the host:
- Use virtiofs (preferred) or 9p
- Mount at `/shared` or similar in VM
- Host path: `/home/<user>/shared/<vm-type>/` or similar
- Allows easy file transfer without network

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

1. **Browsing VM colorscheme not applying** - nvid.json exists but cursor/terminal not using it (pentest VM works fine with mardu.json)
2. **VM rebuild scripts auto-pull** - Breaking local changes, need to remove git pull from all VM profiles
3. **Font should be Tamzen** - Currently using Cozette, need to change globally

## Notes for Contributors

- **Always use --impure** when rebuilding (local config requires it)
- **Never commit local/** - Contains secrets and personal info
- **Test on fresh install** - Use templates/local/*.example to verify portability
- **VMs use "user"** - Standard VM username, never use hardcoded personal usernames
- **Host uses local/host.nix** - Dynamic username from local config
