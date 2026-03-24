# Hydrix User Configuration

This is your personal Hydrix configuration repository. It manages ALL your machines from a single location.

## Directory Structure

```
~/hydrix-config/
├── flake.nix              # Main flake - imports Hydrix, defines machines
├── machines/              # One .nix file per machine (named by hardware serial)
│   ├── ABC123XYZ.nix      # Your laptop config
│   └── DEF456UVW.nix      # Your desktop config
├── profiles/              # VM profile customizations (overlay on Hydrix base)
│   ├── browsing/
│   ├── pentest/
│   ├── dev/
│   ├── comms/
│   └── lurking/
├── specialisations/       # Boot mode modules
│   ├── _base.nix          # Minimal packages (all modes)
│   ├── lockdown.nix       # DEFAULT - hardened, no internet
│   ├── administrative.nix # Full functionality, router VM
│   ├── fallback.nix       # Emergency direct WiFi
│   └── leisure.nix        # Custom mode (optional)
├── shared/                # Settings shared across machines
│   └── common.nix         # Common config (optional)
└── README.md
```

## Machine Config Naming

Machine configs are named by **hardware serial number**, not hostname. This allows automatic detection during reinstalls — the same hardware always finds its config.

The serial is auto-detected during setup. To find your serial manually:
```bash
cat /sys/class/dmi/id/product_serial 2>/dev/null || cat /sys/class/dmi/id/board_serial 2>/dev/null
```

## Boot Modes

| Mode | Internet | VMs | Use Case |
|------|----------|-----|----------|
| **Lockdown** (default) | Disabled | Yes | Daily secure use, nix builds via builder VM |
| **Administrative** | Via router VM | Yes | Full functionality, VM management |
| **Fallback** | Direct WiFi | No | Emergency recovery, initial setup |

### Switching Modes

```bash
# From GRUB menu at boot, or runtime:
rebuild                  # Lockdown (default)
rebuild administrative   # Full functionality
rebuild fallback         # Emergency mode
```

### Adding Custom Modes

Create a new file in `specialisations/`:
```bash
cp specialisations/leisure.nix.example specialisations/leisure.nix
# Edit leisure.nix, then add to your machine config
```

## Quick Start

The setup scripts generate your machine config automatically. If you need to add a machine manually:

1. **Copy the example machine config:**
   ```bash
   SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || cat /sys/class/dmi/id/board_serial 2>/dev/null)
   cp machines/example-serial.nix "machines/${SERIAL}.nix"
   ```

2. **Edit your machine config:**
   ```bash
   $EDITOR "machines/${SERIAL}.nix"
   ```
   - Set `hydrix.username` and `hydrix.hostname`
   - Configure hardware (WiFi PCI address, platform, etc.)
   - Set your password hash: `mkpasswd -m sha-512`

3. **Rebuild:**
   ```bash
   rebuild
   ```

## Adding Another Machine

1. On the new machine, run the setup script and select "Clone existing repo" or "Add this machine to existing config"
2. The serial is auto-detected and a new `machines/<serial>.nix` is created
3. Rebuild:
   ```bash
   rebuild
   ```

## Key Settings

| Setting | Description |
|---------|-------------|
| `hydrix.username` | Your username |
| `hydrix.hostname` | Machine hostname |
| `hydrix.hardware.platform` | "intel", "amd", or "generic" |
| `hydrix.hardware.vfio.wifiPciAddress` | WiFi card PCI address (run `lspci`) |
| `hydrix.router.type` | "microvm" (default), "libvirt", or "none" |
| `hydrix.router.wifi.ssid/password` | WiFi credentials for router VM |
| `hydrix.router.libvirt.*` | Libvirt router settings (vmName, memory, vcpus, wan) |
| `hydrix.graphical.*` | Font, colors, UI settings |

## Using Local Hydrix Clone

For development, point to a local Hydrix clone:

```nix
# In flake.nix, change:
hydrix.url = "github:borttappat/Hydrix";
# To:
hydrix.url = "path:/home/USER/Hydrix";
```

Then run `nix flake update` after making Hydrix changes.

## MicroVMs

MicroVMs are shared across all machines (same images work everywhere).

| VM | Purpose | vsock CID |
|----|---------|-----------|
| `microbrowse` | Web browsing | 101 |
| `microhack` | Pentesting | 102 |
| `microdev` | Development | 103 |
| `microcomms` | Communications | 104 |
| `microlurk` | Monitoring | 105 |
| `microrouter` | Network routing | 200 |
| `microbuild` | Lockdown builds | 210 |

**Commands:**
- List VMs: `microvm list`
- Build: `microvm build microbrowse`
- Start: `microvm start microbrowse`
- Launch app: `microvm app microbrowse firefox`

## Version Control

This is YOUR personal repo - commit it to your own GitHub/GitLab:

```bash
git init
git add .
git commit -m "Initial Hydrix config"
git remote add origin git@github.com:YOUR_USER/hydrix-config.git
git push -u origin main
```

## Updating Hydrix

To get the latest Hydrix version:

```bash
nix flake update
rebuild
```
