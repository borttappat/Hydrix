# Hydrix - Project Context for Claude

## Project Overview

Hydrix is a NixOS-based VM isolation system designed for security-conscious workflows. It provides:
- Host machine with WiFi passthrough to a router VM
- Isolated network bridges for different VM categories (pentest, office, browsing, dev)
- Specialisation-based boot modes (router, lockdown, fallback)
- Template-based machine configuration generation

**Key Goal**: This setup should be usable by anyone, not just the original author. Personal info should be abstracted to local (gitignored) config files.

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
| `scripts/setup.sh` | Initial machine setup - detects hardware, creates configs from templates |
| `scripts/nixbuild.sh` | Rebuilds host/VMs using hostname-based flake detection |
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

### 4. Secrets Management (TODO)
- Use local gitignored config file for secrets
- setup.sh generates with detected/auto-generated values
- Modules read via `--impure` mode
- Goal: repo can be public, personal data stays local

## Current TODO List

### High Priority - Core Functionality
1. Create `modules/base/locale.nix` - Extract locale/keyboard from host `/etc/nixos/configuration.nix`
2. Update setup.sh to detect and populate locale settings
3. Create `modules/base/disk.nix` - LUKS/boot settings from host config
4. Update setup.sh to detect LUKS/boot settings

### Secrets & Privacy
5. Design secrets management (local gitignored `local/secrets.nix`)
6. Implement local secrets file generation in setup.sh
7. Add LUKS encryption to VM builds with auto-generated passwords
8. Abstract username/personal info to local config

### VM Improvements
9. Refactor VM configs - import base modules, remove duplicated settings
10. Set up shared folders between host and each VM (virtiofs or 9p)
11. Isolate br-* bridges from each other (VMs on same bridge can communicate, not across bridges)

### Cleanup (Deferred)
12. Remove obsolete files: `add-machine.sh`, old templates, `.bak` files

## Files to Eventually Clean Up

| File | Status | Reason |
|------|--------|--------|
| `add-machine.sh` | Keep for now | Obsolete - replaced by setup.sh |
| `scripts/setup-machine.sh.bak` | Keep for now | Backup of old script |
| `templates/flake-entry.nix.template` | Keep for now | Only used by obsolete add-machine.sh |
| `templates/router-vm-config.nix.template` | Keep for now | Not used - config is in modules/ |

## Module Structure

```
modules/
├── base/
│   ├── configuration.nix    # Core system config
│   ├── hardware-config.nix  # Hardware (imported from /etc/nixos)
│   ├── users.nix            # User accounts (setup.sh modifies for non-traum)
│   ├── locale.nix           # TODO: Locale/keyboard settings
│   ├── disk.nix             # TODO: LUKS/boot settings
│   ├── services.nix         # System services
│   ├── virt.nix             # Virtualization (libvirt, etc.)
│   ├── audio.nix            # Audio configuration
│   └── hardware/
│       ├── intel.nix        # Intel-specific (graphics, microcode)
│       └── asus.nix         # ASUS-specific (asusd)
├── desktop/
│   ├── firefox.nix
│   └── xinitrc.nix
├── shell/
│   └── packages.nix
├── theming/
│   ├── colors.nix
│   └── dynamic.nix
├── wm/
│   └── i3.nix
├── router-vm-unified.nix    # Router VM configuration
└── lockdown/
    └── router-vm-config.nix # Lockdown router variant
```

## VM Configuration Pattern

VMs should follow this pattern:
```nix
{ config, pkgs, lib, ... }:
{
  imports = [
    # Base modules (shared settings)
    ../base/locale.nix      # TODO
    ../base/disk.nix        # TODO
    # ... other base modules
  ];

  # VM-specific overrides only
  networking.hostName = "pentest-vm";

  # Type-specific packages
  environment.systemPackages = with pkgs; [
    # pentest tools...
  ];
}
```

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

# Rebuild current system
./scripts/nixbuild.sh

# Deploy a VM
./scripts/build-vm.sh --type pentest --name google

# Switch boot modes (requires reboot)
sudo nixos-rebuild boot --flake ~/Hydrix#<hostname>
sudo nixos-rebuild boot --flake ~/Hydrix#<hostname> --specialisation lockdown
sudo nixos-rebuild boot --flake ~/Hydrix#<hostname> --specialisation fallback
```
