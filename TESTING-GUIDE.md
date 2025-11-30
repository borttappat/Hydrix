# Hydrix Testing Guide for Zephyrus

**Goal**: Test the complete Hydrix setup on your Zephyrus machine
- Router VM with WiFi passthrough
- Pentest VM base-image → full configuration workflow
- Verify nixbuild.sh auto-detection works

---

## Current Status

✅ **What's Already Set Up:**
- Flake.nix has all configurations defined (zephyrus, vm-router, vm-pentest)
- Machine profile exists: `profiles/machines/zephyrus.nix`
- Generated router config: `generated/modules/zephyrus-consolidated.nix`
- Generated autostart script: `generated/scripts/autostart-router-vm.sh`
- VM profiles exist: `profiles/pentest-base.nix`, `profiles/pentest-full.nix`
- Router VM config: `modules/router/router-vm-config.nix`

⚠️ **Missing Profiles** (not needed for this test):
- comms-base/full, browsing-base/full, dev-base/full (only referenced in flake, not needed yet)

---

## Pre-Testing Checklist

Before you start testing, verify these prerequisites:

### 1. Check Your Current System

```bash
# Verify you're on dotfiles config currently
hostnamectl  # Should show hostname: zeph

# Check if you're in a specialisation mode
cat /run/current-system/configuration-name 2>/dev/null || echo "base-setup"

# Check if VMs are currently running
sudo virsh list --all
```

### 2. Ensure Hydrix is Clean

```bash
cd /home/traum/Hydrix

# Check flake is valid
nix flake check --no-build

# Verify git status (should show our recent changes)
git status
```

### 3. Backup Current Dotfiles Config

```bash
# Your dotfiles is your safety net - don't touch it yet!
# Just verify it's still working
cd ~/dotfiles && ./nixbuild.sh --help
```

---

## Testing Plan: 3 Phases

### Phase 1: Test Hydrix Host Configuration (Low Risk)

**Goal**: Verify the Zephyrus configuration builds without installing it

```bash
cd /home/traum/Hydrix

# 1. Test if zephyrus config builds (dry-run, doesn't install)
sudo nixos-rebuild dry-build --flake .#zephyrus --impure --show-trace

# Expected: Should succeed and show what would be installed
# If this fails, we fix it before proceeding
```

**If successful**, you can optionally test the nixbuild.sh detection:

```bash
# 2. Test nixbuild.sh detection (won't actually build without sudo)
./nixbuild.sh

# Expected output:
# ======================================
# Hydrix NixOS Rebuild
# ======================================
# Architecture: x86_64
# Chassis: laptop 💻
# Vendor: ASUSTeK COMPUTER INC.
# Model: Zephyrus M GU502GV_GU502GV
# Hostname: zeph
# ======================================
# Detected ASUS Zephyrus
# Current mode: [base-setup|router-setup|maximalism-setup]
```

**Outcome**: If both succeed, Hydrix host config is ready to use.

---

### Phase 2: Build Router VM (Medium Risk)

**Goal**: Build and test the router VM image

```bash
cd /home/traum/Hydrix

# 1. Build router VM image (takes 5-15 minutes)
nix build .#router-vm --show-trace

# Expected: Creates result/ symlink pointing to router.qcow2
# Check: ls -lh result/
```

**If successful**, deploy the router VM:

```bash
# 2. Check if router VM already exists
sudo virsh list --all | grep router

# 3a. If router VM exists, destroy it first
sudo virsh destroy router-vm-passthrough 2>/dev/null || true
sudo virsh undefine router-vm-passthrough 2>/dev/null || true

# 3b. Use the generated autostart script to deploy
./generated/scripts/autostart-router-vm.sh

# Expected: Router VM starts with WiFi passthrough
```

**Verify router VM is working:**

```bash
# 4. Connect to router VM console
sudo virsh console router-vm-passthrough
# (Press Ctrl+] to exit console)

# Inside VM, test:
hostnamectl  # Should show: router-vm, Chassis: vm
ip a         # Should show network interfaces
```

**Test nixbuild.sh inside router VM:**

```bash
# Inside router VM console:
cd /etc/nixos  # or wherever Hydrix is mounted
./nixbuild.sh

# Expected output:
# Detected Virtual Machine
# Building router VM configuration...
```

**Outcome**: Router VM is deployed and working, nixbuild.sh detects it as VM.

---

### Phase 3: Build & Test Pentest VM (Full Workflow)

**Goal**: Test the two-stage VM workflow (base → shaping → full)

#### Step 1: Build Pentest Base Image

```bash
cd /home/traum/Hydrix

# 1. Build pentest VM base image (minimal, includes shaping service)
nix build .#pentest-vm-base --show-trace

# Expected: Creates result/ symlink to pentest-base.qcow2
# Check size: ls -lh result/
```

#### Step 2: Deploy Pentest Base VM

You have two options:

**Option A: Manual Deployment (to understand the process)**

```bash
# 1. Copy base image to VM storage
sudo mkdir -p /var/lib/libvirt/images/
sudo cp result/nixos.qcow2 /var/lib/libvirt/images/pentest-test.qcow2

# 2. Create VM from image
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

# 3. Connect to VM
sudo virsh console pentest-test
```

**Option B: Use Setup Script (automated)**

```bash
# If setup.sh supports pentest-only mode:
./scripts/setup.sh --skip-router --vm-name pentest-test

# Check if this works - it should deploy the base image
```

#### Step 3: Test Base Image Boots

```bash
# Inside pentest VM console:
hostnamectl
# Expected: Should show hostname with "pentest-" prefix
# Expected: Chassis: vm

# Check if Hydrix is available (depends on shaping service)
ls -la /etc/nixos/

# Check shaping service status
systemctl status hydrix-shaping
```

#### Step 4: Test Shaping Service (First Boot)

The shaping service should:
1. Detect VM type from hostname
2. Clone Hydrix repo to /etc/nixos/hydrix
3. Run `nixos-rebuild switch --flake .#vm-pentest`
4. Apply full pentest configuration

```bash
# Inside pentest VM, trigger shaping manually (if not auto-run):
sudo systemctl start hydrix-shaping

# Check logs:
sudo journalctl -u hydrix-shaping -f

# Expected:
# - Clones Hydrix repo
# - Detects hostname as pentest-*
# - Runs nixos-rebuild with vm-pentest config
# - Installs all pentest tools
```

#### Step 5: Test nixbuild.sh Inside Shaped VM

```bash
# Inside pentest VM after shaping:
cd /etc/nixos/hydrix
./nixbuild.sh

# Expected output:
# ====================================
# Hydrix NixOS Rebuild
# ====================================
# Architecture: x86_64
# Chassis: vm
# Vendor: QEMU
# Model: Standard PC _Q35 + ICH9, 2009_
# Hostname: pentest-test
# ====================================
# Detected Virtual Machine
# Building pentest VM configuration...
# [builds vm-pentest config]
```

**Outcome**: Complete two-stage workflow verified - base image → shaping → full config.

---

## Phase 4: Full Hydrix Migration (Optional - High Risk)

**⚠️ ONLY DO THIS IF PHASES 1-3 SUCCEED**

**Goal**: Migrate Zephyrus from dotfiles to Hydrix

### Before Migration

1. **Commit everything** in Hydrix:
   ```bash
   cd /home/traum/Hydrix
   git add -A
   git commit -m "Pre-migration state - all tests passed"
   ```

2. **Create rollback plan**:
   - Keep dotfiles untouched
   - Test boot into router mode from Hydrix
   - Verify you can rollback via bootloader

### Migration Steps

```bash
cd /home/traum/Hydrix

# 1. Build Hydrix for Zephyrus (staged to next boot)
sudo nixos-rebuild boot --flake .#zephyrus --impure --show-trace

# 2. Reboot (careful!)
sudo reboot

# 3. After reboot, verify system
hostnamectl  # Should still show: zeph

# 4. Test nixbuild.sh
./nixbuild.sh
# Should detect Zephyrus and build correctly

# 5. If in router mode, test VMs work
sudo virsh list --all

# 6. If everything works, you're on Hydrix!
```

### Rollback if Needed

```bash
# At bootloader menu:
# - Select "NixOS - Previous Configuration"
# - This boots back to dotfiles config

# Then rebuild dotfiles:
cd ~/dotfiles && ./nixbuild.sh
```

---

## Testing Checklist

Use this to track your progress:

- [ ] **Phase 1**: Hydrix builds for zephyrus (dry-run)
- [ ] **Phase 1**: nixbuild.sh detects zephyrus correctly
- [ ] **Phase 2**: Router VM image builds successfully
- [ ] **Phase 2**: Router VM deploys and boots
- [ ] **Phase 2**: nixbuild.sh works inside router VM
- [ ] **Phase 3**: Pentest base image builds
- [ ] **Phase 3**: Pentest VM deploys from base image
- [ ] **Phase 3**: Shaping service runs successfully
- [ ] **Phase 3**: nixbuild.sh works inside pentest VM
- [ ] **Phase 4** (optional): Full migration to Hydrix

---

## Troubleshooting

### Build Fails: "file not found"

```bash
# Check flake inputs are available
nix flake metadata

# Update flake lock
nix flake update

# Try build again
```

### VM Fails to Start

```bash
# Check libvirt is running
sudo systemctl status libvirtd

# Check VM logs
sudo virsh console <vm-name>

# Check qemu logs
sudo journalctl -u libvirtd | grep -i error
```

### Shaping Service Fails

```bash
# Inside VM, check service logs
sudo journalctl -u hydrix-shaping -xe

# Common issues:
# - Git not available: check if git is in base image
# - Network not ready: shaping service might start too early
# - Flake issues: /etc/nixos/hydrix might be incomplete
```

### nixbuild.sh Doesn't Detect Correctly

```bash
# Run detection test
./test-nixbuild-detection.sh

# Check hostnamectl output
hostnamectl

# Manually check detection variables
VENDOR=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
echo "Vendor: $VENDOR"
```

---

## Success Criteria

✅ **Minimum Success** (Ready for daily use):
- Phase 1 complete: Hydrix builds for Zephyrus
- Phase 2 complete: Router VM works
- nixbuild.sh detects all systems correctly

✅ **Full Success** (Complete automation):
- All phases complete including Phase 3
- Two-stage VM workflow proven
- Ready to replace dotfiles

---

## Notes

- **Don't delete dotfiles** until Hydrix is proven stable
- **Test incrementally** - one phase at a time
- **Git commit** after each successful phase
- **Keep backups** of working VM images

**Next Steps After Testing:**
1. Document any issues found
2. Create missing profiles (comms, browsing, dev) if needed
3. Refine shaping service based on findings
4. Consider migrating other machines (zenbook)

---

Good luck with testing! Take it slow and methodical. 🚀
