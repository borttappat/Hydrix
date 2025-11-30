# nixbuild.sh Fix Summary

**Date**: 2025-11-29
**Issue**: Critical mode-switching bug that attempted live specialisation switching (won't work for kernel params)

---

## What Was Broken

The original `nixbuild.sh` (lines 96-139) had commands that tried to switch specialisations live:

```bash
./nixbuild.sh router-switch      # ❌ Tried to activate router mode live
./nixbuild.sh maximalism-switch  # ❌ Tried to activate maximalism mode live
```

**Why this fails:**
- Router/maximalism modes change **kernel parameters** (`intel_iommu=on`, `vfio-pci.ids=...`)
- They **blacklist kernel modules** (WiFi driver for VFIO)
- **Kernel params require a REBOOT** to take effect

---

## What Was Fixed

### 1. Improved Machine Detection

**Added Chassis field detection:**
```bash
CHASSIS=$(hostnamectl | grep -i "Chassis" | awk -F': ' '{print $2}' | xargs)
```

**VM Detection now checks both:**
- `Chassis: vm` (most reliable)
- `Hardware Vendor: QEMU|VMware` (fallback)

**Physical Machine Detection:**
- Uses `Hardware Model` keywords (Zephyrus, Zenbook, etc.)
- Falls back to `Hardware Vendor` (Razer, Schenker, ASUS)

### 2. Created Reusable Functions

**`detect_specialisation()`**
- Checks `/run/current-system/configuration-name` for mode labels
- Fallback: inspects running VMs (virsh list)
- Returns: base-setup, router-setup, maximalism-setup, or fallback-setup

**`rebuild_with_specialisation()`**
- Smart rebuild strategy based on current mode:
  - **Router/Maximalism**: Use `nixos-rebuild boot` (requires reboot)
  - **Base/Fallback**: Use `nixos-rebuild switch` (applies live)
- Provides clear user feedback about reboot requirements
- Explains how to activate via bootloader menu

### 3. Removed Problematic Mode Switching

**Deleted:**
- `router-switch` command (lines 96-102)
- `maximalism-switch` command (lines 104-109)
- `base-switch` command (lines 111-114)

**Why:** These attempted to activate specialisations with kernel param changes, which cannot work without a reboot.

**New approach:** Mode switching happens **only via bootloader menu** at boot time.

### 4. Added Zenbook Support

```bash
# For ASUS Zenbook machines (with specialisations)
if echo "$MODEL" | grep -qi "zenbook"; then
    echo "Detected ASUS Zenbook"
    CURRENT_LABEL=$(detect_specialisation)
    rebuild_with_specialisation "zenbook" "$CURRENT_LABEL"
    exit $?
fi
```

Zenbook now has the same specialisation support as Zephyrus.

### 5. Updated Templates

Added comprehensive templates in comments:

**For simple machines (no specialisations):**
```bash
if echo "$MODEL" | grep -qi "{keyword}"; then
    echo "Detected {Machine Name}"
    sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#{machine-name}"
    exit $?
fi
```

**For advanced machines (with specialisations):**
```bash
if echo "$MODEL" | grep -qi "{keyword}"; then
    echo "Detected {Machine Name}"
    CURRENT_LABEL=$(detect_specialisation)
    rebuild_with_specialisation "{machine-name}" "$CURRENT_LABEL"
    exit $?
fi
```

---

## How It Works Now

### Correct Workflow

**1. Changing Modes (via bootloader):**
```bash
# 1. Reboot system
sudo reboot

# 2. In bootloader menu, select:
#    - "NixOS - Default" (base mode)
#    - "NixOS - Router" (router mode)
#    - "NixOS - Maximalism" (router + pentest VMs)
#    - "NixOS - Fallback" (clean config)

# 3. System boots into selected mode
```

**2. Rebuilding in Current Mode:**
```bash
# Run nixbuild.sh (no arguments)
./nixbuild.sh

# What happens:
# - Detects current specialisation automatically
# - For router/maximalism: builds new config, requires reboot
# - For base/fallback: applies changes live, no reboot needed
```

### Detection Flow

```
1. Get system info
   ├─ Architecture (x86_64, aarch64, etc.)
   ├─ Chassis (vm, laptop, desktop)
   ├─ Hardware Vendor (ASUS, QEMU, Razer, etc.)
   ├─ Hardware Model (Zephyrus M GU502GV, Zenbook S 14, etc.)
   └─ Hostname (zen, router-vm, pentest-grief, etc.)

2. Check if ARM
   └─ Yes → build armVM
   └─ No → continue

3. Check if VM
   ├─ Chassis == "vm" OR Vendor contains "QEMU|VMware"
   └─ Yes → Match hostname pattern
       ├─ pentest-* → vm-pentest
       ├─ comms-* → vm-comms
       ├─ browsing-* → vm-browsing
       ├─ dev-* → vm-dev
       └─ router-* → vm-router
   └─ No → continue

4. Check physical machine model
   ├─ Model contains "zephyrus"
   │   └─ Detect specialisation → rebuild_with_specialisation "zephyrus"
   ├─ Model contains "zenbook"
   │   └─ Detect specialisation → rebuild_with_specialisation "zenbook"
   ├─ Vendor == "Razer" → build razer
   ├─ Vendor == "Schenker" → build xmg
   ├─ Vendor == "ASUS" → build asus (generic)
   └─ Unknown → build host (fallback)
```

---

## Testing

**Created test script:**
```bash
./test-nixbuild-detection.sh
```

**Test results on Zephyrus:**
```
✓ Detected as: Physical Machine
✓ Would build: zephyrus (with specialisation support)
  Machine: ASUS Zephyrus
```

**Validation:**
- ✅ Bash syntax valid (`bash -n nixbuild.sh`)
- ✅ Detection works correctly on Zephyrus
- ✅ VM detection tested with router-vm hostnamectl output
- ✅ Zenbook detection verified with hostnamectl output

---

## Key Benefits

1. **No more failed live switches** - Can't accidentally try to switch modes that require reboot
2. **Clear user feedback** - Script tells you exactly when reboot is needed
3. **Extendable** - Easy templates for adding new machines
4. **Dual detection** - Uses both Chassis and Vendor for VM detection (more reliable)
5. **Smart rebuild strategy** - Automatically uses `boot` vs `switch` based on mode
6. **Reusable functions** - Any machine can use specialisation support easily

---

## Files Modified

- ✅ `/home/traum/Hydrix/nixbuild.sh` - Fixed detection and rebuild logic
- ✅ `/home/traum/Hydrix/CLAUDE.md` - Marked issue as resolved
- ✅ `/home/traum/Hydrix/test-nixbuild-detection.sh` - Created test script (new)
- ✅ `/home/traum/Hydrix/NIXBUILD-FIX-SUMMARY.md` - This document (new)

---

## Next Steps (Future Work)

These were documented as TODOs in the original CLAUDE.md but are not critical:

1. **Optional**: Update `templates/nixbuild-entry.sh.template` for consistency
2. **Optional**: Create specialized templates for different machine types
3. **When needed**: Add support for new machines as they're added to the fleet

The core issue (live mode switching) is now **completely resolved**.
