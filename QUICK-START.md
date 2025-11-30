# Hydrix Quick Start - Essential Commands

Quick reference for testing Hydrix on Zephyrus.

---

## 🚦 Start Here

```bash
# Go to Hydrix directory
cd /home/traum/Hydrix

# Check flake is valid
nix flake check --no-build

# Test detection without building
./test-nixbuild-detection.sh
```

---

## 📦 Building Images

### Host Configuration (Zephyrus)
```bash
# Dry-run (doesn't install, just tests)
sudo nixos-rebuild dry-build --flake .#zephyrus --impure

# Build for next boot (safe, doesn't change current system)
sudo nixos-rebuild boot --flake .#zephyrus --impure

# Apply immediately (only do if confident)
sudo nixos-rebuild switch --flake .#zephyrus --impure

# Or just use nixbuild.sh (auto-detects)
./nixbuild.sh
```

### Router VM Image
```bash
# Build router VM (~5-15 min)
nix build .#router-vm

# Check result
ls -lh result/

# Deploy with generated script
./generated/scripts/autostart-router-vm.sh
```

### Pentest VM Image
```bash
# Build base image
nix build .#pentest-vm-base

# Check result
ls -lh result/
```

---

## 🖥️ VM Management

### List VMs
```bash
# Show all VMs (running and stopped)
sudo virsh list --all

# Show only running VMs
sudo virsh list
```

### Start/Stop VMs
```bash
# Start VM
sudo virsh start <vm-name>

# Stop VM (graceful)
sudo virsh shutdown <vm-name>

# Stop VM (force)
sudo virsh destroy <vm-name>

# Delete VM definition (doesn't delete disk)
sudo virsh undefine <vm-name>
```

### Connect to VM
```bash
# Console (text mode)
sudo virsh console <vm-name>
# Exit with: Ctrl+]

# GUI (if using virt-manager)
virt-manager
```

### VM Information
```bash
# Show VM details
sudo virsh dominfo <vm-name>

# Show VM network info
sudo virsh domifaddr <vm-name>

# Show VM disks
sudo virsh domblklist <vm-name>
```

---

## 🔍 System Information

### Current System
```bash
# Full system info
hostnamectl

# Just hostname
hostname

# Current specialisation
cat /run/current-system/configuration-name 2>/dev/null || echo "base-setup"

# System generation
nixos-rebuild list-generations
```

### Hardware Detection
```bash
# Vendor and model
hostnamectl | grep -i "Hardware"

# Chassis type (vm, laptop, desktop)
hostnamectl | grep -i "Chassis"

# PCI devices (for VFIO)
lspci | grep -i wifi
lspci | grep -i network
```

---

## 🔧 Troubleshooting

### Flake Issues
```bash
# Show flake info
nix flake metadata

# Update flake inputs
nix flake update

# Check flake syntax
nix flake check
```

### Build Issues
```bash
# Clean build cache
sudo nix-collect-garbage

# Rebuild with verbose output
sudo nixos-rebuild switch --flake .#zephyrus --impure --show-trace --verbose
```

### VM Issues
```bash
# Check libvirt status
sudo systemctl status libvirtd

# Restart libvirt
sudo systemctl restart libvirtd

# Check VM logs
sudo journalctl -u libvirtd | tail -50

# Inside VM: check shaping service
sudo journalctl -u hydrix-shaping -xe
```

### Network Issues
```bash
# Check libvirt networks
sudo virsh net-list --all

# Start default network
sudo virsh net-start default

# Enable autostart
sudo virsh net-autostart default
```

---

## 📁 Important Paths

### Hydrix
```
/home/traum/Hydrix/                      # Main repo
├── flake.nix                            # System configurations
├── nixbuild.sh                          # Auto-detect rebuild script
├── profiles/machines/zephyrus.nix       # Zephyrus config
├── generated/                           # Auto-generated configs
│   ├── modules/zephyrus-consolidated.nix
│   └── scripts/autostart-router-vm.sh
└── modules/                             # Shared modules
```

### VM Images
```
/nix/store/.../nixos.qcow2               # Built images (via result/ symlink)
/var/lib/libvirt/images/                 # Deployed VM disks
```

### Dotfiles (Backup)
```
/home/traum/dotfiles/                    # Current working config (DON'T DELETE)
```

---

## 🎯 Common Workflows

### Test Hydrix Without Installing
```bash
cd /home/traum/Hydrix
sudo nixos-rebuild dry-build --flake .#zephyrus --impure
```

### Deploy Router VM
```bash
cd /home/traum/Hydrix
nix build .#router-vm
./generated/scripts/autostart-router-vm.sh
sudo virsh console router-vm-passthrough
```

### Deploy Pentest VM
```bash
cd /home/traum/Hydrix
nix build .#pentest-vm-base

# Manual deployment
sudo cp result/nixos.qcow2 /var/lib/libvirt/images/pentest-test.qcow2
sudo virt-install \
  --name pentest-test \
  --memory 4096 \
  --vcpus 2 \
  --disk /var/lib/libvirt/images/pentest-test.qcow2,bus=virtio \
  --import \
  --os-variant nixos-unstable \
  --network network=default \
  --graphics spice \
  --noautoconsole

sudo virsh console pentest-test
```

### Switch to Hydrix (When Ready)
```bash
cd /home/traum/Hydrix
sudo nixos-rebuild boot --flake .#zephyrus --impure
sudo reboot
# Select new boot entry in bootloader
```

### Rollback to Dotfiles
```bash
# At bootloader: Select "NixOS - Previous Configuration"
# Then:
cd ~/dotfiles && ./nixbuild.sh
```

---

## 🆘 Emergency Recovery

### System Won't Boot
1. At bootloader, select "NixOS - Previous Configuration"
2. After boot, rebuild: `cd ~/dotfiles && ./nixbuild.sh`

### VM Won't Start
```bash
# Destroy and undefine
sudo virsh destroy <vm-name>
sudo virsh undefine <vm-name>

# Delete disk
sudo rm /var/lib/libvirt/images/<vm-name>.qcow2

# Rebuild image
nix build .#<vm-type>

# Redeploy
```

### Flake Build Fails
```bash
# Clean cache
sudo nix-collect-garbage

# Update inputs
nix flake update

# Try again
sudo nixos-rebuild dry-build --flake .#zephyrus --impure --show-trace
```

---

## 📊 Testing Phases (TL;DR)

1. **Phase 1**: Test builds → `sudo nixos-rebuild dry-build --flake .#zephyrus --impure`
2. **Phase 2**: Build router VM → `nix build .#router-vm && ./generated/scripts/autostart-router-vm.sh`
3. **Phase 3**: Build pentest VM → `nix build .#pentest-vm-base` + manual deploy
4. **Phase 4** (optional): Migrate host → `sudo nixos-rebuild boot --flake .#zephyrus --impure && sudo reboot`

**Read TESTING-GUIDE.md for detailed instructions.**

---

## 🔗 Quick Links

- Full testing guide: `TESTING-GUIDE.md`
- nixbuild.sh fix details: `NIXBUILD-FIX-SUMMARY.md`
- Project docs: `CLAUDE.md`
- Implementation guide: `IMPLEMENTATION-GUIDE.md`

---

**Pro Tip**: Keep dotfiles working until Hydrix is fully tested and stable!
