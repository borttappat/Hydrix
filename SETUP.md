# Hydrix Setup Guide

## Current Status

✅ **Phase 1 Complete: Host Machine Foundation**
- Zephyrus profile created with dynamic /etc/nixos imports
- Intelligent nixbuild.sh with auto-detection
- Template system for adding new machines
- Flake structure ready for expansion

## Quick Start

### Building on Zephyrus

```bash
cd ~/Hydrix
./nixbuild.sh
```

The script will auto-detect your machine and build the appropriate configuration.

### Adding a New Machine

```bash
cd ~/Hydrix
./add-machine.sh
```

Follow the prompts to generate:
- Machine profile in `profiles/machines/{name}.nix`
- nixbuild.sh entry (manual addition required)
- flake.nix entry (manual addition required)

## How It Works

### Machine Detection

The `nixbuild.sh` script automatically detects:
- **Architecture**: x86_64, ARM/aarch64
- **Machine Type**: Physical or VM (QEMU/VMware)
- **Hardware**: Vendor and model via `hostnamectl`
- **VM Purpose**: Based on hostname pattern (pentest-*, comms-*, etc.)

### Configuration Import Strategy

All machine profiles import `/etc/nixos/configuration.nix`, which includes:
- Bootloader settings (from installation)
- Filesystem mounts and LUKS encryption
- Locale and timezone
- Basic system settings

This approach eliminates hardcoded hardware configurations and ensures compatibility with LUKS setups.

**Important**: Build with `--impure` flag to allow /etc/nixos imports.

### Current Zephyrus Configuration

Location: `profiles/machines/zephyrus.nix`

Features:
- Imports `/etc/nixos/configuration.nix` (includes hardware-configuration.nix)
- ASUS-specific power management (TLP, auto-cpufreq, thermald)
- NVIDIA Prime offload configuration
- Battery charge limiting (80% threshold)
- VM management tools
- Bluetooth support
- GRUB bootloader with os-prober

## Build Commands

### Standard Build
```bash
./nixbuild.sh
```

### Test Build (don't switch)
```bash
sudo nixos-rebuild build --flake .#zephyrus --impure
```

### Boot (apply on next reboot)
```bash
sudo nixos-rebuild boot --flake .#zephyrus --impure
```

## Specializations (Coming Soon)

The zephyrus profile will support multiple operating modes:

- **base-switch**: Normal laptop operation
- **router-switch**: WiFi passthrough to router VM
- **maximalism-switch**: Router + auto-started VMs

Usage:
```bash
./nixbuild.sh router-switch
./nixbuild.sh maximalism-switch
./nixbuild.sh base-switch
```

## Structure

```
Hydrix/
├── flake.nix                  # Main flake with all configurations
├── nixbuild.sh                # Intelligent rebuild script
├── add-machine.sh             # Template-based machine addition
├── modules/                   # Reusable NixOS modules
│   ├── base/                  # Core system modules
│   ├── wm/                    # Window manager (i3, polybar, etc.)
│   ├── shell/                 # Shell configuration (fish, etc.)
│   ├── theming/               # Theming system (pywal, colors)
│   ├── vm/                    # VM-specific modules
│   └── router/                # Router VM and VFIO modules
├── profiles/                  # Complete system profiles
│   ├── machines/              # Physical machine profiles
│   │   └── zephyrus.nix      # ASUS Zephyrus configuration
│   ├── pentest-base.nix      # Minimal pentest VM
│   ├── pentest-full.nix      # Full pentest system
│   └── router-base.nix       # Router VM
├── configs/                   # Configuration file templates
└── templates/                 # Templates for new machines
```

## Next Steps

1. **Test the current setup**: Run `./nixbuild.sh` to verify zephyrus builds
2. **Port desktop environment**: Copy i3, polybar, dunst configs
3. **Port scripts**: Copy autostart.sh, walrgb.sh, load-display-config.sh
4. **Create desktop modules**: xorg.nix, resolution-aware.nix, i3.nix
5. **Create theming modules**: pywal.nix, walrgb.nix
6. **Add router support**: VFIO passthrough, multi-bridge networking

## VM Workflow (Future)

### Building VM Base Images
```bash
nix build .#pentest-vm-base
nix build .#router-vm
nix build .#comms-vm-base
```

### Inside VMs
VMs will clone Hydrix repo and run:
```bash
cd /etc/nixos/hydrix
./nixbuild.sh  # Auto-detects VM type from hostname
```

## Troubleshooting

### Build fails with "cannot read /etc/nixos"
Make sure to use the `--impure` flag:
```bash
sudo nixos-rebuild switch --flake .#zephyrus --impure
```

### Unknown hardware
The script will show detected hardware and build the generic `host` configuration.
Add your machine using `./add-machine.sh`.

### LUKS/Encryption issues
Since we import `/etc/nixos/configuration.nix`, LUKS settings come directly from your installation. No manual configuration needed.

## Contributing Machines

To add support for your machine:

1. Run `./add-machine.sh` to generate templates
2. Edit the generated profile in `profiles/machines/{name}.nix`
3. Add the nixbuild.sh entry in the marked section
4. Add the flake.nix entry in nixosConfigurations
5. Test with `./nixbuild.sh`

---

**Status**: Foundation complete, ready for desktop environment porting
**Next**: Port essential configs and scripts from ~/dotfiles
