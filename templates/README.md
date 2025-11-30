# Hydrix Templates

This directory contains templates used by setup.sh and other scripts to generate machine-specific configurations.

## nixbuild.sh Templates

### nixbuild-entry.sh.template
**Use for**: Simple machines without specialisations
- Generic laptops
- Machines that don't need router/VM modes
- Basic NixOS configurations

**Variables**:
- `{{MACHINE_NAME}}` - Human-readable name (e.g., "ASUS Zenbook")
- `{{MODEL_PATTERN}}` - Grep pattern to detect model (e.g., "zenbook")
- `{{FLAKE_NAME}}` - Flake configuration name (e.g., "zenbook")

**Example**:
```nix
# For ASUS Zenbook machines
if echo "$MODEL" | grep -qi "zenbook"; then
    echo "Detected ASUS Zenbook"
    sudo nixos-rebuild switch --impure --flake "$FLAKE_DIR#zenbook"
    exit $?
fi
```

### nixbuild-specialisation-entry.sh.template
**Use for**: Machines with specialisations (router/maximalism modes)
- Machines with VFIO passthrough
- Machines that run router VMs
- Machines with multiple boot modes

**Variables**:
- Same as above

**Behavior**:
- Detects current specialisation (base/router/maximalism)
- Rebuilds in SAME mode (no live switching)
- Shows instructions for changing modes via bootloader

**Example**:
```nix
# For ASUS Zephyrus machines
if echo "$MODEL" | grep -qi "zephyrus"; then
    echo "Detected ASUS Zephyrus"

    # Detect current specialisation
    CURRENT_SPEC="base"
    if [[ -L /run/current-system/specialisation ]]; then
        CURRENT_SPEC=$(readlink /run/current-system/specialisation | xargs basename 2>/dev/null || echo "base")
    fi

    # Rebuild in current mode
    case "$CURRENT_SPEC" in
        "router")
            sudo nixos-rebuild switch --flake "$FLAKE_DIR#zephyrus" --specialisation router
            ;;
        "maximalism")
            sudo nixos-rebuild switch --flake "$FLAKE_DIR#zephyrus" --specialisation maximalism
            ;;
        *)
            sudo nixos-rebuild switch --flake "$FLAKE_DIR#zephyrus"
            ;;
    esac

    exit $?
fi
```

## Other Templates

### flake-entry.nix.template
Template for adding new machine configurations to flake.nix

### machine-profile.nix.template
Template for creating machine-specific profile files in `profiles/machines/`

### router-vm-config.nix.template
Template for router VM configuration (generated dynamically by setup.sh)

## Critical Rule: Mode Switching

**⚠️ IMPORTANT**: Machines with specialisations that change kernel parameters or blacklist modules:
- **CANNOT switch modes live** (requires reboot)
- nixbuild.sh should **detect and maintain current mode**
- Mode changes happen via **bootloader menu selection**

**Why?**
- Kernel parameters (`intel_iommu=on`, `vfio-pci.ids=...`) require reboot
- Kernel module blacklists require reboot
- Attempting to switch live will appear to work but won't actually apply changes

**Correct flow**:
1. Boot into desired mode via bootloader
2. Run `./nixbuild.sh` - rebuilds in current mode
3. To change modes: reboot and select different specialisation in bootloader
