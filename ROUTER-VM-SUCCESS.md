# Router VM - Working Configuration

**Status**: ✅ WORKING - Internet connectivity confirmed
**Date**: 2025-11-30
**Commit**: 0807195

---

## Critical Success Milestone

The router VM now works exactly like the original splix setup. The VM boots automatically to a text console, provides internet connectivity to the host, and requires minimal resources.

## What Works

- ✅ Automatic boot (no boot menu)
- ✅ Text-only console (no graphics overhead)
- ✅ Internet connectivity from host through VM
- ✅ WiFi passthrough support
- ✅ 5 bridge networks (virbr1-virbr5)
- ✅ DHCP and DNS services
- ✅ Auto-login to console
- ✅ 2GB RAM footprint (minimal)

## Build Command

```bash
nix build '.#router-vm-qcow'
```

**Output**: `result/nixos.qcow2` (4.4GB image)

## Deploy Command

```bash
sudo ./deploy-router-vm.sh
```

**What it does**:
1. Checks for existing VM, offers to destroy/recreate
2. Copies image to `/var/lib/libvirt/images/router-vm-passthrough.qcow2`
3. Attempts WiFi passthrough (PCI device 00:14.3)
4. Falls back to non-passthrough if WiFi fails
5. Creates VM with 5 bridge networks

## VM Access

```bash
# Check status
sudo virsh --connect qemu:///system list --all

# Connect to console
sudo virsh --connect qemu:///system console router-vm-passthrough

# Start VM (if stopped)
sudo virsh --connect qemu:///system start router-vm-passthrough

# Stop VM
sudo virsh --connect qemu:///system destroy router-vm-passthrough
```

## Configuration Files

### Module: `modules/router-vm-config.nix`

Single-file configuration (exact copy from splix):
- Networking: 5 interfaces (enp1s0-enp5s0) with static IPs
- DHCP: dnsmasq serving 4 networks
- NAT: WiFi interface auto-detection and iptables rules
- Services: SSH, QEMU guest, SPICE
- User: traum (auto-login, password: ifEHbuuhSez9)

### Flake: `flake.nix`

```nix
packages.x86_64-linux = {
  router-vm-qcow = nixos-generators.nixosGenerate {
    system = "x86_64-linux";
    modules = [ ./modules/router-vm-config.nix ];
    format = "qcow";
  };
};
```

### Deploy Script: `deploy-router-vm.sh`

Key settings that make it work:
- `--boot hd` - Direct boot, no menu
- `--nographics` - Text console only
- `--memory 2048` - Minimal footprint
- `--connect qemu:///system` - System-level libvirt
- `--hostdev 00:14.3` - WiFi PCI passthrough

## Network Configuration

| Interface | IP Address        | Purpose              |
|-----------|-------------------|----------------------|
| enp1s0    | 192.168.100.253   | Management network   |
| enp2s0    | 192.168.101.253   | Guest network 1      |
| enp3s0    | 192.168.102.253   | Guest network 2      |
| enp4s0    | 192.168.103.253   | Guest network 3      |
| enp5s0    | 192.168.104.253   | Guest network 4      |
| wl*       | Auto-detected     | WiFi uplink (DHCP)   |

DHCP ranges:
- 192.168.101.10-100 (virbr2)
- 192.168.102.10-100 (virbr3)
- 192.168.103.10-100 (virbr4)
- 192.168.104.10-100 (virbr5)

## Key Learnings

### Why It Failed Before

1. **Overengineering**: Had modules/router/ directory with base/full split and shaping service
2. **Wrong boot method**: Used `--boot uefi` which shows boot menu
3. **Graphics overhead**: Used `--graphics spice` instead of text console
4. **Too much memory**: Used 4096MB instead of 2048MB
5. **Missing NVRAM cleanup**: UEFI VMs weren't being properly removed

### What Made It Work

1. **Exact splix replication**: Single module file, no abstractions
2. **Direct boot**: `--boot hd` for immediate console boot
3. **Text-only**: `--nographics` for minimal overhead
4. **Proper cleanup**: `--nvram` flag when undefining VMs
5. **Simple structure**: One config file, one flake target, one deploy script

## Differences from Original Splix

Minimal - only structural:
- File location: `modules/router-vm-config.nix` vs `splix/modules/router-vm-config.nix`
- Flake target name: `router-vm-qcow` vs `router-vm-qcow`
- Password: Different random password (security)

Functionally identical in every way that matters.

## Testing Checklist

- [x] VM builds successfully
- [x] VM deploys without errors
- [x] VM boots automatically to console
- [x] No boot menu or graphics window
- [x] Can log in as traum
- [x] All 5 network interfaces configured
- [x] WiFi interface detected
- [x] iptables NAT rules applied
- [x] dnsmasq running
- [x] DHCP serving addresses
- [x] Internet connectivity from host
- [x] SSH access works
- [x] Minimal resource usage (2GB RAM)

## Future Reference

If router VM breaks again:
1. Check this document
2. Compare against splix: `/home/traum/splix/modules/router-vm-config.nix`
3. Verify deploy script matches splix: `/home/traum/splix/generated/scripts/deploy-router-vm.sh`
4. Don't over-engineer - keep it simple like splix
5. Test with: `sudo ./deploy-router-vm.sh`

## Related Files

- Module: `modules/router-vm-config.nix`
- Deploy: `deploy-router-vm.sh`
- Flake: `flake.nix` (packages.x86_64-linux.router-vm-qcow)
- Original: `/home/traum/splix/modules/router-vm-config.nix`
- Original deploy: `/home/traum/splix/generated/scripts/deploy-router-vm.sh`

---

**This configuration is production-ready and should not be changed without testing.**
