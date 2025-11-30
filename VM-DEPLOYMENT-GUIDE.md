# Hydrix VM Deployment Guide

**Last Updated**: 2025-11-30
**Status**: ✅ Production Ready

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [VM Types](#vm-types)
5. [Detailed Workflow](#detailed-workflow)
6. [Managing VMs](#managing-vms)
7. [Updating VMs](#updating-vms)
8. [Troubleshooting](#troubleshooting)
9. [Advanced Usage](#advanced-usage)

---

## Overview

Hydrix uses a **two-stage deployment system** for VMs:

1. **Base Image** (built once, ~2-3GB)
   - Core desktop environment (i3, fish, alacritty, rofi)
   - Essential CLI tools (git, vim, tmux, ranger)
   - Shaping service for first-boot configuration

2. **Shaping Process** (first boot)
   - Detects VM type from hostname
   - Clones Hydrix repository
   - Rebuilds with type-specific profile
   - Installs all specialized packages

**Benefits**:
- Fast iteration (reuse base image)
- Easy updates (git pull inside VM)
- Flexible (same base → any type)
- Declarative (everything in Nix)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      HOST SYSTEM                            │
│                                                             │
│  1. ./scripts/build-vm.sh --type pentest --name google     │
│     ├─> Checks/builds base image                           │
│     ├─> Calculates resources (75% for pentest)             │
│     ├─> Copies base image                                  │
│     ├─> Injects hostname: "pentest-google"                 │
│     └─> Creates VM in libvirt                              │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    VM FIRST BOOT                            │
│                                                             │
│  2. Boot → TTY (auto-login)                                │
│     └─> systemd starts hydrix-shape.service                │
│                                                             │
│  3. Shaping Service:                                       │
│     ├─> hostname = "pentest-google"                        │
│     ├─> type = "pentest" (extracted from hostname)         │
│     ├─> git clone https://github.com/.../Hydrix.git        │
│     ├─> cd /etc/nixos/hydrix                               │
│     └─> nixbuild-vm (detects type, rebuilds)               │
│                                                             │
│  4. nixbuild-vm script:                                    │
│     └─> nixos-rebuild switch --flake .#vm-pentest --impure │
│                                                             │
│  5. Full Profile Applied:                                  │
│     ├─> Core desktop (from base)                           │
│     ├─> Pentest packages (nmap, burpsuite, metasploit)     │
│     ├─> Red theme                                          │
│     └─> Marks as shaped (/etc/nixos/.hydrix-shaped)        │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│               SUBSEQUENT BOOTS                              │
│                                                             │
│  6. Boot → TTY                                             │
│     ├─> Shaping service: "Already shaped, skipping..."     │
│     └─> Type "x" → i3 launches                             │
│                                                             │
│  7. Full pentest environment ready!                        │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

```bash
# Install dependencies
nix-shell -p libvirt qemu libguestfs virt-manager

# Ensure libvirtd is running
sudo systemctl start libvirtd
sudo systemctl enable libvirtd

# Add user to libvirt group
sudo usermod -a -G libvirt $USER
newgrp libvirt
```

### Deploy Your First VM

```bash
# Navigate to Hydrix directory
cd /home/traum/Hydrix

# Deploy a pentest VM named "google"
./scripts/build-vm.sh --type pentest --name google

# This will:
# 1. Build base image if needed (~10-15 min first time)
# 2. Create VM with 75% resources
# 3. Set hostname to "pentest-google"
# 4. Start VM (auto-shapes on first boot)
```

### Connect to VM

```bash
# Using virt-manager (recommended)
virt-manager
# → Select "pentest-google" → Open

# Or using virt-viewer
virt-viewer qemu:///system pentest-google

# Credentials
# Username: traum
# Password: (as set in modules/base/users.nix)
```

---

## VM Types

### Available Types

| Type | Purpose | Resources | Theme | Examples |
|------|---------|-----------|-------|----------|
| **pentest** | Penetration testing | 75% CPU/RAM | Red | nmap, burpsuite, metasploit, sqlmap |
| **dev** | Software development | 75% CPU/RAM | Purple | vscode, docker, compilers, databases |
| **browsing** | Web browsing & media | 50% CPU/RAM | Green | firefox, vlc, libreoffice |
| **comms** | Communication apps | 25% CPU/RAM | Blue | signal, telegram, tor-browser |

### Resource Calculation Examples

**Example Host**: 16 cores, 32GB RAM

```bash
# Pentest VM (75%)
./scripts/build-vm.sh --type pentest --name google
# → 12 vCPUs, 24GB RAM

# Dev VM (75%)
./scripts/build-vm.sh --type dev --name rust
# → 12 vCPUs, 24GB RAM

# Browsing VM (50%)
./scripts/build-vm.sh --type browsing --name leisure
# → 8 vCPUs, 16GB RAM

# Comms VM (25%)
./scripts/build-vm.sh --type comms --name signal
# → 4 vCPUs, 8GB RAM
```

---

## Detailed Workflow

### Phase 1: Base Image Creation

**Base Image Contents** (`profiles/base-vm.nix`):
```
✓ NixOS base system
✓ User configuration (traum with sudo)
✓ QEMU guest tools (virtio, spice)
✓ Core desktop:
  - i3-gaps (window manager)
  - fish shell + starship prompt
  - alacritty terminal
  - rofi launcher
  - polybar status bar
  - dunst notifications
✓ Essential CLI tools:
  - git, vim, wget, curl
  - htop, ranger, tmux, fzf
  - eza, bat, zoxide
✓ Shaping service (systemd oneshot)
✓ nixbuild-vm script (hostname-aware rebuild)
```

**Build Command**:
```bash
# Manual build (optional - auto-built on first deploy)
nix build .#base-vm-qcow

# Result: ./result/nixos.qcow2 (~2-3GB)
```

### Phase 2: VM Deployment

**Deployment Script** (`scripts/build-vm.sh`):

```bash
./scripts/build-vm.sh --type TYPE --name NAME [OPTIONS]

# Required:
  --type TYPE        VM type: pentest, comms, browsing, dev
  --name NAME        Instance name (e.g., google, signal)

# Optional:
  --disk SIZE       Disk size (default: 100G)
  --bridge BRIDGE   Network bridge (default: virbr2)
  --force-rebuild   Rebuild base image even if exists
```

**What the script does**:
1. Validates dependencies (nix, virsh, virt-install, virt-customize)
2. Checks for base image (builds if missing)
3. Calculates resources based on type
4. Copies base image to `/var/lib/libvirt/images/<type>-<name>.qcow2`
5. **Injects hostname** using `virt-customize --hostname <type>-<name>`
6. Resizes disk to specified size
7. Creates VM in libvirt with:
   - Name: `<type>-<name>`
   - Memory/vCPUs: Based on type percentage
   - CPU: host-passthrough (full performance)
   - Disk: virtio (fast I/O)
   - Network: virtio on specified bridge
   - Graphics: SPICE optimized

### Phase 3: First Boot Shaping

**Shaping Service** (`modules/vm/shaping.nix`):

1. **Checks marker**: `/etc/nixos/.hydrix-shaped`
   - If exists: Skip (already shaped)
   - If not: Continue with shaping

2. **Detects VM type**:
   ```bash
   hostname=$(hostname)  # e.g., "pentest-google"
   type="${hostname%%-*}"  # extracts "pentest"
   ```

3. **Clones/updates Hydrix**:
   ```bash
   # First boot
   git clone https://github.com/borttappat/Hydrix.git /etc/nixos/hydrix

   # Subsequent reshapes (if marker deleted)
   cd /etc/nixos/hydrix && git pull
   ```

4. **Runs nixbuild-vm**:
   - Script detects hostname
   - Maps to flake entry:
     - "pentest" → `vm-pentest`
     - "comms" → `vm-comms`
     - "browsing" → `vm-browsing`
     - "dev" → `vm-dev`
   - Executes: `nixos-rebuild switch --flake .#vm-<type> --impure`

5. **Marks as shaped**:
   ```bash
   touch /etc/nixos/.hydrix-shaped
   ```

### Phase 4: Full Profile Application

**Profile Structure** (e.g., `profiles/pentest-full.nix`):

```nix
{
  imports = [
    # Base system modules
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix
    ../modules/vm/qemu-guest.nix

    # Core desktop (i3, fish, cli tools)
    ../modules/core.nix
  ];

  # Theme (red for pentest)
  hydrix.colors = {
    accent = "#ea6c73";
  };

  # Type-specific packages
  environment.systemPackages = [
    nmap wireshark burpsuite metasploit
    john hashcat hydra sqlmap
    # ... etc
  ];
}
```

---

## Managing VMs

### List VMs

```bash
# List all VMs
sudo virsh list --all

# List running VMs
sudo virsh list
```

### Start/Stop VMs

```bash
# Start VM
sudo virsh start pentest-google

# Shutdown VM (graceful)
sudo virsh shutdown pentest-google

# Force stop VM
sudo virsh destroy pentest-google

# Restart VM
sudo virsh reboot pentest-google
```

### Delete VMs

```bash
# Stop VM first
sudo virsh destroy pentest-google

# Delete VM definition and disk
sudo virsh undefine pentest-google --nvram

# Remove disk image (if needed)
sudo rm /var/lib/libvirt/images/pentest-google.qcow2
```

### VM Information

```bash
# View VM details
sudo virsh dominfo pentest-google

# View VM disk info
sudo qemu-img info /var/lib/libvirt/images/pentest-google.qcow2

# View VM console (TTY)
sudo virsh console pentest-google
# (Press Ctrl+] to exit)
```

---

## Updating VMs

### Update Hydrix Configuration

**Inside the VM**:

```bash
# Pull latest Hydrix changes
cd /etc/nixos/hydrix
git pull

# Rebuild with updated configuration
nixbuild-vm

# Or manually specify flake entry
nixos-rebuild switch --flake .#vm-pentest --impure
```

### Rebuild Specific VM Type

**Inside any VM**:

```bash
# Auto-detects type from hostname and rebuilds
nixbuild-vm
```

**How it works**:
1. Reads hostname (e.g., "pentest-google")
2. Extracts type ("pentest")
3. Maps to flake entry ("vm-pentest")
4. Rebuilds: `nixos-rebuild switch --flake .#vm-pentest --impure`

### Reshape VM from Scratch

**If you want to re-run the shaping process**:

```bash
# Inside the VM
sudo rm /etc/nixos/.hydrix-shaped
sudo systemctl start hydrix-shape.service

# Or just reboot (service runs on boot)
sudo reboot
```

### Update Base Image

**When you update core.nix or base-vm.nix**:

```bash
# Rebuild base image
nix build .#base-vm-qcow --rebuild

# New VMs will use updated base
# Existing VMs: update via git pull + nixbuild-vm inside VM
```

---

## Troubleshooting

### Base Image Build Fails

```bash
# Check Nix syntax
nix flake check

# Build with verbose output
nix build .#base-vm-qcow --print-build-logs

# Common issues:
# - Missing imports: Check all paths in profiles/base-vm.nix
# - Module conflicts: Check for duplicate imports
# - Package errors: Check nixpkgs version compatibility
```

### VM Won't Start

```bash
# Check libvirtd status
sudo systemctl status libvirtd

# Check VM definition
sudo virsh dumpxml pentest-google

# Check libvirt logs
sudo journalctl -u libvirtd -f

# Common issues:
# - Disk permissions: sudo chown libvirt-qemu:kvm /var/lib/libvirt/images/*.qcow2
# - Bridge missing: Check 'ip link show virbr2'
# - Resource limits: Check host available RAM/CPU
```

### Shaping Service Fails

```bash
# Inside the VM, check service status
sudo systemctl status hydrix-shape.service

# View service logs
sudo journalctl -u hydrix-shape.service -f

# Common issues:
# - Git clone fails: Check network connectivity
# - Rebuild fails: Check /etc/nixos/hydrix/flake.nix syntax
# - Wrong hostname: Check 'hostname' output matches expected pattern
```

### Hostname Not Set Correctly

```bash
# Check if virt-customize is installed
which virt-customize

# Install if missing
nix-shell -p libguestfs

# Manually set hostname in existing VM
# (Inside the VM)
sudo hostnamectl set-hostname pentest-google

# Verify
hostname
```

### Wrong VM Type Applied

```bash
# Check hostname
hostname  # Should be "<type>-<name>"

# Check shaping marker
cat /etc/nixos/.hydrix-shaped  # Exists = already shaped

# Fix:
# 1. Set correct hostname: sudo hostnamectl set-hostname <type>-<name>
# 2. Remove marker: sudo rm /etc/nixos/.hydrix-shaped
# 3. Re-run shaping: sudo systemctl start hydrix-shape.service
```

### Performance Issues

```bash
# Check resource allocation
sudo virsh dominfo pentest-google | grep -E "CPU|memory"

# Check host resources
htop

# Common issues:
# - Over-allocated: Multiple 75% VMs running simultaneously
# - CPU pinning: Check if host has enough cores
# - Disk I/O: Check if using virtio (not IDE)
```

---

## Advanced Usage

### Custom Disk Size

```bash
# Deploy with 200G disk
./scripts/build-vm.sh --type dev --name rust --disk 200G
```

### Custom Network Bridge

```bash
# Deploy on different bridge
./scripts/build-vm.sh --type pentest --name google --bridge virbr1
```

### Force Rebuild Base Image

```bash
# Rebuild even if base image exists
./scripts/build-vm.sh --type pentest --name google --force-rebuild
```

### Clone Existing VM

```bash
# Stop source VM
sudo virsh shutdown pentest-google

# Clone disk
sudo cp /var/lib/libvirt/images/pentest-google.qcow2 \
        /var/lib/libvirt/images/pentest-amazon.qcow2

# Set new hostname
sudo virt-customize -a /var/lib/libvirt/images/pentest-amazon.qcow2 \
     --hostname pentest-amazon

# Import as new VM
sudo virt-install --connect qemu:///system \
  --name pentest-amazon \
  --memory 24576 \
  --vcpus 12 \
  --disk /var/lib/libvirt/images/pentest-amazon.qcow2 \
  --os-variant nixos-unstable \
  --boot hd \
  --import \
  --noautoconsole
```

### Export/Import VMs

```bash
# Export VM
sudo virsh dumpxml pentest-google > pentest-google.xml
sudo cp /var/lib/libvirt/images/pentest-google.qcow2 ~/backup/

# Import VM (on another machine)
sudo cp ~/backup/pentest-google.qcow2 /var/lib/libvirt/images/
sudo virsh define pentest-google.xml
sudo virsh start pentest-google
```

### Snapshot VMs

```bash
# Create snapshot
sudo virsh snapshot-create-as pentest-google snapshot1 \
  "Before major update"

# List snapshots
sudo virsh snapshot-list pentest-google

# Restore snapshot
sudo virsh snapshot-revert pentest-google snapshot1

# Delete snapshot
sudo virsh snapshot-delete pentest-google snapshot1
```

### Add New VM Type

1. **Create profile** in `profiles/<type>-full.nix`:
   ```nix
   { config, pkgs, lib, ... }:
   {
     imports = [
       ../modules/base/nixos-base.nix
       ../modules/base/users.nix
       ../modules/base/networking.nix
       ../modules/vm/qemu-guest.nix
       ../modules/core.nix
     ];

     hydrix.colors = {
       accent = "#yourcolor";
     };

     environment.systemPackages = [ /* your packages */ ];
   }
   ```

2. **Add to flake.nix**:
   ```nix
   vm-<type> = nixpkgs.lib.nixosSystem {
     system = "x86_64-linux";
     modules = [
       { nixpkgs.config.allowUnfree = true; }
       { nixpkgs.overlays = [ overlay-unstable ]; }
       nix-index-database.nixosModules.nix-index
       ./profiles/<type>-full.nix
     ];
   };
   ```

3. **Update build-vm.sh** resource allocation:
   ```bash
   case "$type" in
       <type>)
           percent=XX
           log "<Type> VM - allocation (XX%)"
           ;;
   ```

4. **Update nixbuild-vm.sh** mapping:
   ```bash
   case "$vm_type" in
       <type>)
           echo "vm-<type>"
           ;;
   ```

5. **Deploy**:
   ```bash
   ./scripts/build-vm.sh --type <type> --name <name>
   ```

---

## File Reference

### Key Files

```
Hydrix/
├── flake.nix                    # Main flake with all VM configurations
├── modules/
│   ├── core.nix                 # Core components (i3, fish, cli tools)
│   ├── base/                    # Base system modules
│   │   ├── nixos-base.nix
│   │   ├── users.nix
│   │   ├── networking.nix
│   │   └── ...
│   ├── vm/
│   │   ├── qemu-guest.nix       # QEMU guest tools
│   │   └── shaping.nix          # First-boot shaping service
│   ├── wm/i3.nix                # i3 window manager
│   ├── shell/                   # Shell configuration
│   └── theming/colors.nix       # Color scheme system
├── profiles/
│   ├── base-vm.nix              # Universal base image (built once)
│   ├── pentest-full.nix         # Pentest VM profile (75%)
│   ├── comms-full.nix           # Comms VM profile (25%)
│   ├── browsing-full.nix        # Browsing VM profile (50%)
│   └── dev-full.nix             # Dev VM profile (75%)
└── scripts/
    ├── build-vm.sh              # VM deployment script
    └── nixbuild-vm.sh           # VM rebuild script (hostname-aware)
```

---

## Next Steps

1. **Deploy your first VM**: Follow the [Quick Start](#quick-start)
2. **Explore VM types**: Try different types for different purposes
3. **Customize profiles**: Edit `profiles/*-full.nix` for your needs
4. **Update configurations**: Use `git pull` + `nixbuild-vm` inside VMs
5. **Report issues**: Document any problems in CLAUDE.md

---

**For router VM setup**, see `ROUTER-VM-SUCCESS.md`
**For implementation details**, see `IMPLEMENTATION-GUIDE.md`
**For project overview**, see `CLAUDE.md`
