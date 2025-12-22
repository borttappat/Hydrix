# Hydrix Templates

This directory contains templates used by setup.sh to generate machine-specific configurations.

## Generated/Modified Files

When `scripts/setup.sh` runs, it:
- Creates `profiles/machines/<hostname>.nix` - Machine profile from `machine-profile-full.nix.template`
- Updates `modules/base/users.nix` - Replaces 'traum' with detected user (if different)
- Creates `generated/scripts/autostart-router-vm.sh` - Router VM autostart script

## Templates

### machine-profile-full.nix.template
**Used by**: `scripts/setup.sh`
**Purpose**: Complete machine profile with VFIO passthrough, bridges, and specialisations

**Variables**:
- `{{MACHINE_NAME}}` - Hostname/machine identifier
- `{{DATE}}` - Generation timestamp
- `{{CPU_PLATFORM}}` - CPU vendor (intel/amd)
- `{{IS_ASUS}}` - Whether system is ASUS hardware (true/false)
- `{{PRIMARY_ID}}` - WiFi device vendor:product ID (e.g., "8086:a0f0")
- `{{PRIMARY_PCI}}` - WiFi PCI address (e.g., "0000:00:14.3")
- `{{PRIMARY_PCI_SHORT}}` - Short PCI format for virt-install (e.g., "00:14.3")
- `{{PRIMARY_DRIVER}}` - WiFi kernel driver to blacklist (e.g., "iwlwifi")
- `{{PRIMARY_INTERFACE}}` - WiFi interface name (e.g., "wlan0")
- `{{IOMMU_PARAM}}` - IOMMU kernel parameter (intel_iommu=on or amd_iommu=on)
- `{{USER}}` - Detected username
- `{{HW_IMPORTS}}` - Conditional hardware module imports (Intel, ASUS, user config)

**Generated Features**:
- VFIO passthrough configuration for WiFi NIC
- Network bridges (br-mgmt, br-pentest, br-office, br-browse, br-dev)
- Router VM autostart systemd service
- Fallback specialisation (re-enables WiFi, disables VFIO)
- Lockdown specialisation (isolates host from internet)
- Status commands (vm-status, router-status, lockdown-status, fallback-status)

### flake-entry.nix.template
Template for adding new machine configurations to flake.nix (reference only - setup.sh has its own inline version)

### router-vm-config.nix.template
Template for router VM configuration with user credential placeholders

## How nixbuild.sh Works

`scripts/nixbuild.sh` uses **hostname-based detection** - no templates needed:

**Physical machines:**
```bash
# Uses hostname directly as flake target
FLAKE_TARGET="$HOSTNAME"
# Builds: nixos-rebuild switch --flake .#<hostname>
```

**VMs:**
```bash
# Extracts type from hostname pattern (e.g., "pentest-google" → "pentest")
VM_TYPE="${hostname%%-*}"
FLAKE_TARGET="vm-${VM_TYPE}"
# Builds: nixos-rebuild switch --flake .#vm-pentest
```

**Specialisation handling:**
- Detects current specialisation (lockdown/router/fallback)
- Maintains same mode across rebuilds
- Mode changes require reboot via bootloader

## Critical Rule: Mode Switching

**IMPORTANT**: Machines with specialisations that change kernel parameters or blacklist modules:
- **CANNOT switch modes live** (requires reboot)
- nixbuild.sh **detects and maintains current mode**
- Mode changes happen via **bootloader menu selection**

**Why?**
- Kernel parameters (`intel_iommu=on`, `vfio-pci.ids=...`) require reboot
- Kernel module blacklists require reboot
- Attempting to switch live will appear to work but won't actually apply changes

**Correct flow**:
1. Boot into desired mode via bootloader
2. Run `scripts/nixbuild.sh` - rebuilds in current mode
3. To change modes: reboot and select different specialisation in bootloader
