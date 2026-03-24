# NixOS Custom Installer with Btrfs & Disko

A streamlined, reproducible NixOS installation system with:
- 🚀 One-command installation process
- 💾 Btrfs with reflink support for instant VM cloning
- 🎯 Declarative disk management via disko
- 🔧 Interactive wizard for easy customization
- 🎮 Dual-boot support (tested with Bazzite)

## Quick Start

### For Users Installing NixOS

1. **Download the custom ISO** (or build it yourself - see below)
2. **Boot from the ISO**
3. **Run the installer**:
   ```fish
   sudo fish /etc/installer/install-wizard.fish
   ```
4. **Follow the prompts** - the wizard handles everything

### For Maintainers Building the ISO

```bash
# Clone your config repo
git clone <your-repo> ~/nixos-config
cd ~/nixos-config

# Build the custom ISO
nix build .#installer-iso

# Flash to USB
sudo dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress
```

## Repository Structure

```
.
├── flake.nix                          # Main flake configuration
├── installer/
│   ├── installer.nix                  # Custom installer ISO config
│   ├── install-wizard.fish            # Interactive wizard
│   └── disko-templates/
│       ├── single-disk.nix            # Full disk installation
│       ├── dual-boot.nix              # Dual-boot configuration
│       └── vm-optimized.nix           # VM workload optimization
├── hosts/
│   ├── common.nix                     # Shared configuration
│   └── <hostname>/
│       └── configuration.nix
└── modules/
    └── ...your modules...
```

## Installation Modes

### 1. Full Disk (Single OS)
- Wipes entire disk
- Ideal for: dedicated NixOS machines
- Disk layout: EFI + Swap + Btrfs root

### 2. Dual Boot
- Preserves existing partitions
- Ideal for: Gaming setups (Windows/Bazzite + NixOS)
- **Requires manual partitioning first** (see below)

### 3. VM Optimized
- Full disk with VM-specific optimizations
- Separate subvolumes for base images and instances
- CoW enabled for instant VM cloning
- Ideal for: Pentesting labs, development environments

## Dual-Boot Setup (Manual Steps)

Before running the installer for dual-boot:

1. **Boot into your existing OS** (Bazzite, Windows, etc.)

2. **Shrink the existing partition**:
   ```bash
   # On Bazzite/Linux
   sudo parted /dev/nvme0n1
   resizepart <number> <new_size>
   
   # On Windows
   # Use Disk Management to shrink partition
   ```

3. **Create space for NixOS** (leave it unallocated)

4. **Boot the NixOS installer** and select "Dual-boot" mode

5. **The wizard will ask for partition details**

6. **After install, GRUB will auto-detect other OSes** (via os-prober)

## VM Reflink Workflow

After installation with VM-optimized mode:

### Create a Base Image

```fish
# Using virt-install
virt-install --name base-kali \
  --disk path=/var/lib/libvirt/bases/kali-base.qcow2,size=20 \
  --cdrom /path/to/kali.iso \
  --memory 4096 --vcpus 2

# Or copy existing image
cp my-vm.qcow2 /var/lib/libvirt/bases/kali-base.qcow2
```

### Clone VMs Instantly

```fish
# Using the helper script
source ~/nixos-config/vm-manager.fish

# Clone a VM (instant, uses ~0 additional space initially)
vm_clone kali-base.qcow2 kali-pentest-01

# Clone multiple instances
for i in (seq 1 5)
  vm_clone kali-base.qcow2 kali-lab-0$i
end

# Check actual disk usage
vm_disk_usage
```

### How Reflinks Work

- **Initial clone**: ~0 bytes, instant
- **As VM diverges**: Only changed blocks use space
- **Example**: 20GB base → 5x 20GB clones = ~20-30GB total (not 120GB!)

## Post-Installation

### Enable Automatic Btrfs Scrubbing

Already configured if using the templates, but verify:

```nix
# In your configuration.nix
services.btrfs.autoScrub = {
  enable = true;
  interval = "weekly";
  fileSystems = [ "/" ];
};
```

### Monitor Disk Usage

```bash
# Overall filesystem usage
btrfs filesystem df /

# Actual space used (with compression)
sudo compsize /

# VM-specific usage
sudo compsize /var/lib/libvirt/images
```

### Take Snapshots

```fish
# Manual snapshot
sudo btrfs subvolume snapshot / /.snapshots/root-$(date +%Y%m%d)

# Using the VM manager
vm_snapshot kali-lab-01 before-exploit-test
```

## Customization

### Pre-Install Configuration

Create a `install-config.sh` users can source before running the wizard:

```bash
#!/usr/bin/env bash
# install-config.sh - Pre-set installation parameters

export NIXOS_DISK="/dev/nvme0n1"
export NIXOS_HOSTNAME="pentest-rig"
export NIXOS_USERNAME="hacker"
export NIXOS_TIMEZONE="America/New_York"
export NIXOS_SWAP_SIZE="16"
export NIXOS_GIT_REPO="https://github.com/yourusername/nixos-config"
export NIXOS_INSTALL_TYPE="vm-optimized"
```

Then users run:
```bash
source install-config.sh
sudo fish /etc/installer/install-wizard.fish
```

The wizard can be modified to check for these env vars.

### Adding Your Own Disko Templates

1. Create new template in `installer/disko-templates/`
2. Add option to wizard's install type selection
3. Reference in `install-wizard.fish`

### Custom Modules

Add your modules to `modules/` and import in `hosts/common.nix`:

```nix
# hosts/common.nix
{
  imports = [
    ../modules/pentest-tools.nix
    ../modules/i3-config.nix
    ../modules/fish-config.nix
  ];
}
```

## Building and Distributing

### Build ISO Locally

```bash
nix build .#installer-iso
```

### Build on GitHub Actions

```yaml
# .github/workflows/build-iso.yml
name: Build ISO
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: cachix/install-nix-action@v22
      - run: nix build .#installer-iso
      - uses: actions/upload-artifact@v3
        with:
          name: nixos-installer
          path: result/iso/*.iso
```

### Share with Team

1. Upload ISO to file server/GitHub releases
2. Share VM base images separately
3. Document any required secrets/tokens

## Troubleshooting

### Installer Won't Boot
- Verify secure boot is disabled
- Try different USB creation tool (Ventoy, Rufus, Etcher)

### Disko Fails
- Check disk isn't mounted: `lsblk`, `umount -R /dev/sdX*`
- Verify UEFI vs BIOS mode
- Check disko template syntax

### Dual-Boot Not Detecting Other OS
- Ensure `useOSProber = true` in configuration.nix
- Update GRUB: `sudo nixos-rebuild switch`
- Manually add entry if needed

### VMs Not Using Reflinks
- Verify btrfs: `df -T | grep btrfs`
- Check CoW is enabled: `lsattr /var/lib/libvirt/images`
- Use `cp --reflink=always` explicitly

### Out of Space Despite Reflinks
- Check compression: `compsize /`
- VMs have diverged significantly
- Run btrfs balance: `sudo btrfs balance start /`

## Performance Notes

### For Pentesting Workloads

- **VM-optimized template**: Best for multiple VMs
- **Separate /nix**: Faster package operations
- **Swap size**: Match your RAM for hibernation
- **Compression**: zstd:1 for speed, zstd:3 for space

### For Gaming (Dual-Boot)

- Keep games on separate partition (NTFS/ext4)
- Or use separate btrfs subvolume with `nodatacow`
- Wine/Proton work fine on btrfs

## License

[Your License Here]

## Credits

- Built with [disko](https://github.com/nix-community/disko)
- Inspired by NixOS community installers
