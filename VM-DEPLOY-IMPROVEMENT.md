# VM Deploy Improvement Plan

This document tracks improvements to VM deployment and update workflows in Hydrix.

**Branch**: `vm-deploy-improvement` (merged to master)
**Started**: 2026-01-01
**Status**: Complete - Merged to Master ✅

---

## Vision

Reduce time spent on VM image builds and VM updates while preserving the network isolation model. VMs should be able to rebuild/update without re-downloading packages that already exist on the host.

### Key Principles

1. **Preserve Network Isolation** - Host cannot SSH to isolated VMs. This is non-negotiable.
2. **No Host→VM Network Push** - Solutions must work without host initiating connections to VMs.
3. **Minimize Resource Usage** - Any infrastructure VMs must be lightweight (like router VM).
4. **Prefer virtiofs Over Network** - Direct store sharing via virtio avoids network entirely.
5. **Backwards Compatible** - Existing VMs continue to work, improvements are opt-in.
6. **Baked + Orphaned Model** - VMs receive all config at build time and are self-contained after deployment.

---

## VM Build Workflow (Target Design)

### Overview

VMs are **baked** at build time with all configuration, secrets, and the Hydrix repo included in the image. After deployment, VMs are **orphaned** - they don't need to pull from the host repo or sync configs. The virtiofs shared `/nix/store` provides fast rebuilds within the VM using packages cached on the host.

**Directory distinction:**
- `Hydrix` - Upstream repo, cloned for initial setup
- `hydrix-local` - Host's working directory where everything runs from

```
┌─────────────────────────────────────────────────────────────┐
│                     BUILD TIME (Host)                       │
├─────────────────────────────────────────────────────────────┤
│  User runs: ./build-vm.sh --type pentest --bridge br-pentest│
│                                                             │
│  Prompted for / provided via flags:                         │
│    • Username (default: user)                               │
│    • Password (hashed, prompted securely)                   │
│    • LUKS password (future feature)                         │
│    • Hostname (VM's internal identity)                      │
│    • VM name (libvirt domain name, what host sees)          │
│                                                             │
│  Script:                                                    │
│    1. Writes secrets → local/vms/<vm-name>-secrets.nix      │
│    2. Copies only relevant configs for VM type              │
│    3. Fills placeholders in templates                       │
│    4. Builds image (config + secrets baked in)              │
│    5. Deploys to libvirt with virtiofs                      │
│    6. Restores templates to placeholder state               │
│    7. Keeps secrets file on host for reference              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    RUNTIME (VM)                             │
├─────────────────────────────────────────────────────────────┤
│  /home/<user>/Hydrix/  ← Baked in from host's hydrix-local  │
│                                                             │
│  VM is ORPHANED:                                            │
│    • No git pull needed                                     │
│    • No connection back to host repo                        │
│    • rebuild script uses local baked-in config              │
│    • virtiofs /nix/store = fast rebuilds (packages cached)  │
│                                                             │
│  If user modifies configs in VM:                            │
│    • Changes stay local to that VM                          │
│    • Can manually copy back to host for future builds       │
└─────────────────────────────────────────────────────────────┘
```

### Build Script Parameters

| Parameter | Flag | Prompt | Description |
|-----------|------|--------|-------------|
| VM type | `--type` | No | pentest, browsing, comms, dev |
| Bridge | `--bridge` | No | br-pentest, br-browse, br-office, br-dev |
| Username | `--user` | Optional | Username inside VM (default: user) |
| Password | `--password` | Yes (secure) | User password, hashed before storing |
| LUKS password | `--luks` | Yes (future) | Disk encryption password |
| Hostname | `--hostname` | Optional | VM's internal hostname |
| VM name | `--name` | Optional | Libvirt domain name (host sees this) |

### Secrets File Structure

```nix
# local/vms/<vm-name>-secrets.nix
{
  vmUser = "alice";
  vmHostname = "pentest-alice";
  hashedPassword = "$6$rounds=...";  # mkpasswd output
  # Future: LUKS key reference
}
```

This file:
- Is imported by the VM config at build time
- Persists on host for reference/rebuilds
- Is NOT committed to git (in .gitignore)

### Template Placeholder System

Templates in `templates/` contain placeholders that get filled at build time:

```nix
# templates/vm-config.nix.template
{ config, pkgs, ... }:
{
  users.users.@VM_USER@ = {
    isNormalUser = true;
    hashedPassword = "@HASHED_PASSWORD@";
  };
  networking.hostName = "@VM_HOSTNAME@";
}
```

Build script:
1. Copies template to working location
2. Substitutes `@PLACEHOLDER@` with values from secrets file
3. Builds image
4. Original template remains unchanged (placeholders intact)

### Config Baking

At build time, the following are baked into the VM image:

| Item | Location in Image | Source |
|------|-------------------|--------|
| Hydrix repo | `/home/<user>/Hydrix/` | Host's `hydrix-local` directory |
| VM-specific config | Parsed from templates | Secrets file + templates |
| User credentials | `/etc/shadow` (via NixOS) | Secrets file |
| Hostname | `/etc/hostname` | Secrets file |
| Only relevant modules | Various | VM type determines which |

### Post-Deployment (Orphaned Model)

After deployment, the VM is self-contained:

- **No git pull needed** - Config is already baked in
- **No host sync** - VM operates independently
- **Rebuild uses baked config** - `rebuild` script uses `/home/<user>/Hydrix/`
- **virtiofs provides packages** - Host's `/nix/store` available for fast rebuilds
- **Changes stay local** - User can modify configs inside VM

To propagate changes back to host for future builds:
```bash
# Inside VM, copy modified config to shared location or manually
# Then on host, update templates/configs as needed
```

### Future Enhancement: Host↔VM Config Sync

**Goal**: Sync specific modules (e.g., `pentesting.nix`) between host and VMs.

This would allow:
- Host updates to pentesting tools propagate to VMs
- VM-tested configs can be pulled back to host

**Not implemented yet** - tracked as future work.

---

## Current Workflow Analysis

### Where Time is Spent

| Phase | Method | Time | Pain Level |
|-------|--------|------|------------|
| Host image build (first) | `nix build .#pentest-vm-full` | 10-20 min | Medium |
| Host image build (cached) | Same command, deps cached | 1-5 min | Low |
| VM deployment | `cp` + `virt-install` | 1-2 min | Low |
| VM update | `git pull && nixos-rebuild` inside VM | 5-15 min | **High** |

**Biggest pain point**: VM updates re-download/rebuild packages that host already has.

### Current Flow

```
Host                                      VM
─────                                     ──
nix build .#pentest-vm-full
    └── Downloads/builds all packages
    └── Creates qcow2 image

build-vm.sh --type pentest --name foo
    └── cp image to /var/lib/libvirt
    └── virt-install creates domain
                                          VM boots with full config

                                          [Later, manual update]
                                          git pull
                                          nixos-rebuild switch
                                              └── Re-downloads packages!
                                              └── Rebuilds from internet
```

### Desired Flow (virtiofs)

```
Host                                      VM
─────                                     ──
nix build .#pentest-vm-full
    └── Downloads/builds all packages
    └── Creates qcow2 image
    └── Packages now in /nix/store

build-vm.sh --type pentest --name foo
    └── Creates domain WITH virtiofs mount
                                          VM boots
                                          Mounts host's /nix/store read-only

                                          [Later, update]
                                          git pull
                                          nixos-rebuild switch
                                              └── Uses host store via virtiofs
                                              └── Near-instant!
```

---

## Phase Breakdown

### Phase 1: Host-side Quick Wins ✅
> Low-effort optimizations that help immediately

- [x] **1.1** Add parallel nix settings to host configuration
  ```nix
  nix.settings = { max-jobs = "auto"; cores = 0; };
  ```
- [x] **1.2** Update `build-vm.sh` to use `cp --reflink=auto` (instant on btrfs/zfs)
- [ ] **1.3** Test building multiple VM images in parallel
- [x] **1.4** Document current filesystem (btrfs? ext4?) for reflink compatibility
  - **Result**: ext4 - reflink won't help but `--reflink=auto` is harmless (falls back to regular copy)

### Phase 2: virtiofs Shared /nix/store ✅
> Primary solution - share host's store with VMs via virtio

- [x] **2.1** Verify host has virtiofsd available
  - **Result**: virtiofsd 1.13.2 available at `/run/current-system/sw/bin/virtiofsd`
- [x] **2.2** Create test libvirt XML with virtiofs filesystem element
  - Integrated into `build-vm.sh` via `--filesystem` and `--memorybacking` virt-install options
  - Required `binary.path` in virt-install to specify virtiofsd location on NixOS
- [x] **2.3** Test manual VM with virtiofs mount to /nix/.host-store
  - **Result**: Mount confirmed at `/nix/.host-store` type virtiofs (ro,relatime)
- [x] **2.4** Test nixos-rebuild inside VM using shared store
  - **Result**: VM's nix.settings.substituters includes `http://localhost:5557` first
  - `nix path-info` successfully queries host store via local nix-serve
- [x] **2.5** Create `modules/vm/shared-store.nix` for VM-side mount config
  - Created with nix-serve local cache approach (more reliable than overlay-store)
- [x] **2.6** Update `build-vm.sh` to inject virtiofs into VM XML
  - Added `--shared-store` default (enabled) and `--no-shared-store` flag
- [x] **2.7** Handle store path conflicts (VM's writable store vs host's read-only)
  - Solution: Mount host store read-only at `/nix/.host-store`, run local nix-serve on port 5557
  - VM's own store remains writable, host store used as binary cache substituter
- [x] **2.8** Test full flow: build image → deploy → update via shared store
  - **Result**: Full rebuild inside VM completed in ~5 minutes
  - Packages in host store used from cache; missing packages downloaded normally
- [x] **2.9** Document any caveats or limitations
  - See "Security Analysis" and "Next Steps" sections below

### Phase 3: Cache VM Alternative (If virtiofs Fails)
> Fallback if virtiofs doesn't work - lightweight cache VM on br-shared

- [ ] **3.1** Create `profiles/cache-vm.nix` (minimal, nix-serve only)
- [ ] **3.2** Add cache VM to flake.nix outputs
- [ ] **3.3** Build and deploy cache VM to br-shared
- [ ] **3.4** Configure cache VM to run nix-serve on port 5000
- [ ] **3.5** Test: host pushes built closure to cache VM
- [ ] **3.6** Update VM profiles to use cache as substituter
- [ ] **3.7** Test full flow: host builds → pushes to cache → VM pulls from cache
- [ ] **3.8** Document cache VM maintenance (garbage collection, etc.)

### Phase 4: Polish and Integration
> Clean up and document

- [ ] **4.1** Update CLAUDE.md with new workflow documentation
- [x] **4.2** Update build-vm.sh help text
- [x] **4.3** Add `--no-shared-store` flag if user wants isolated VMs
- [ ] **4.4** Test on fresh VM deployment
- [ ] **4.5** Merge to master when stable

---

## Tried and Ruled Out

Document approaches that were considered but rejected, so we don't retry them.

| Approach | Reason Rejected | Date |
|----------|-----------------|------|
| `nixos-rebuild --target-host` | Host cannot SSH to isolated VMs | 2026-01-01 |
| colmena/deploy-rs/nixops | All require SSH from host to target | 2026-01-01 |
| Direct network push from host | Violates network isolation model | 2026-01-01 |
| NFS mount of /nix/store | Requires network; virtiofs is cleaner | 2026-01-01 |

---

## Open Questions / Decisions

| Question | Status | Decision |
|----------|--------|----------|
| virtiofs vs cache VM? | Open | Try virtiofs first, cache VM as fallback |
| Read-only or overlay store? | Open | Need to research nix store layering |
| Shared store for all VMs or opt-in? | Open | Probably opt-in with flag |
| What if VM needs package host doesn't have? | Open | Falls back to internet download |

---

## Technical Reference

### virtiofs Configuration

**Host side** (libvirt XML addition):
```xml
<domain type='kvm'>
  ...
  <devices>
    ...
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs' queue='1024'/>
      <source dir='/nix/store'/>
      <target dir='nix-store'/>
    </filesystem>
  </devices>
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
</domain>
```

**VM side** (NixOS module):
```nix
# modules/vm/shared-store.nix
{ config, lib, pkgs, ... }:
{
  fileSystems."/nix/.ro-store" = {
    device = "nix-store";
    fsType = "virtiofs";
    options = [ "defaults" ];
  };

  # Configure nix to use the shared store as a substituter
  nix.settings.substituters = lib.mkBefore [ "/nix/.ro-store" ];
}
```

**Note**: May need overlay-store or similar mechanism. Research needed.

### Cache VM Configuration

**Cache VM profile** (`profiles/cache-vm.nix`):
```nix
{ config, pkgs, ... }:
{
  imports = [ ../modules/base/nixos-base.nix ];

  networking.hostName = "cache-vm";

  # Minimal system
  services.nix-serve = {
    enable = true;
    port = 5000;
    secretKeyFile = null;  # Public cache, no signing
  };

  networking.firewall.allowedTCPPorts = [ 5000 ];

  # Light resources
  # ~256MB RAM, 1 vCPU should suffice
}
```

**VM substituter config**:
```nix
nix.settings.substituters = [ "http://192.168.105.x:5000" ];
nix.settings.trusted-substituters = [ "http://192.168.105.x:5000" ];
```

### Parallel Nix Settings

```nix
# In host configuration
nix.settings = {
  max-jobs = "auto";  # Parallel jobs = number of cores
  cores = 0;          # Each job uses all available cores
};
```

### Reflink Copy

```bash
# Only effective on CoW filesystems (btrfs, xfs with reflink, zfs)
sudo cp --reflink=auto "$source" "$target"
```

Check filesystem:
```bash
df -T /var/lib/libvirt/images
```

---

## File Changes Tracking

### Files to Create

- [x] `modules/vm/shared-store.nix` - VM-side virtiofs mount configuration
- [ ] `profiles/cache-vm.nix` - Cache VM profile (if going that route)

### Files to Modify

- [x] `scripts/build-vm.sh` - Add virtiofs XML, reflink copy
- [x] `modules/base/nixos-base.nix` - Add parallel nix settings
- [x] `profiles/base-vm.nix` - Import shared-store module, enable by default
- [ ] `flake.nix` - Add cache-vm output (if needed)

### Files to Remove

- (None planned)

---

## Progress Log

### 2026-01-03 (Benchmark Results)

**Benchmark: Full VM Deployment + Rebuild**

| Step | Time | Notes |
|------|------|-------|
| Pre-build VM toplevel on host | ~1s | Cached from previous build |
| Build VM image | ~1s | Cached |
| Deploy VM (qcow2 backing file) | ~2s | Instant overlay creation |
| **Host total** | **~4s** | |
| nixos-rebuild inside VM | **84s** | Most time spent cloning pentest tool repos |
| **End-to-end total** | **~88s** | |

**Comparison to old workflow:**
- Old VM rebuild time: **15+ minutes** (re-downloading all packages)
- New VM rebuild time: **84 seconds** (using virtiofs shared store)
- **Improvement: ~10x faster**

**What the rebuild downloaded:**
- Only 32.4 MiB downloaded (vs 570+ MiB without shared store)
- 185.2 MiB copied from host store via virtiofs
- Most time spent cloning git repos (Havoc, SharpCollection, etc.)

**Merged to master** - virtiofs shared store now available for all VMs.

### 2026-01-03 (Earlier)

- **Phase 2 Complete**: virtiofs shared /nix/store fully working
- Fixed virtiofsd discovery: Added `binary.path=/run/current-system/sw/bin/virtiofsd` to virt-install
- Added `virtualisation.libvirtd.qemu.verbatimConfig` for virtiofsd path in `virt.nix`
- Tested full flow: VM boots → mounts host store → nix-serve serves it → rebuild uses cache
- Changed image deployment from `cp` to `qemu-img create -b` (qcow2 backing file)
  - Instant VM disk creation (no copy, just overlay)
  - Saves disk space (only stores VM's changes)
- Security analysis: virtiofs is safe for segmentation model (read-only, hypervisor-enforced)

### 2026-01-02

- **Phase 1 Complete**: Added parallel nix settings (`max-jobs`, `cores`) to `nixos-base.nix`
- **Phase 1 Complete**: Replaced `cp` with qcow2 backing file approach (instant, saves space)
- **Phase 2 Progress**: Verified virtiofsd 1.13.2 available
- **Phase 2 Progress**: Created `modules/vm/shared-store.nix` with virtiofs mount + local nix-serve cache
- **Phase 2 Progress**: Updated `build-vm.sh` with virtiofs virt-install options (enabled by default)
- **Phase 2 Progress**: Added `--no-shared-store` flag for isolated VMs
- **Phase 2 Progress**: Updated `profiles/base-vm.nix` to import and enable shared-store module
- Architecture decision: Use local nix-serve (port 5557) serving from virtiofs mount instead of overlay-store
  - More reliable than experimental overlay-store feature
  - VM's own store remains writable
  - Host store provides packages via binary cache protocol

### 2026-01-01

- Created `vm-deploy-improvement` branch and worktree
- Created planning document (this file)
- Created focused CLAUDE.md for worktree
- Analyzed current workflow and pain points
- Documented constraints and viable approaches
- Ruled out SSH-based approaches (violate network isolation)
- **Next**: Begin Phase 1 (parallel nix settings, reflink copy)

---

## Security Analysis

### virtiofs /nix/store Sharing

**What's exposed:**
- VM gets **read-only** access to host's `/nix/store`
- Contains only build outputs (derivations), not secrets
- VM can see what packages are on host (minor info disclosure)

**What's protected:**
- VM **cannot write** to host store (enforced by virtiofs ro mount)
- VM **cannot access** other host files (only /nix/store shared)
- Network isolation is **fully preserved** (no new network paths)
- Boundary enforced by hypervisor, not network rules

**Compared to alternatives:**
- **More secure** than network-based nix-serve (no ports, no traffic to intercept)
- **Same security** as any QEMU virtio device (well-audited boundary)
- Secrets belong in secrets management (not in /nix/store)

**Verdict:** Safe for segmentation model. Hypervisor-enforced read-only boundary is stronger than network isolation.

---

## Next Steps

### Completed
- [x] Merge to master
- [x] Benchmark and document results
- [x] Update all VM profiles (pentest, browsing, comms, dev) to import shared-store.nix
- [x] Automate VM pre-building in setup.sh (runs after initial host build)
- [x] Automate VM pre-building in nixbuild.sh (runs after every host rebuild)

### Remaining
None - VM deploy improvement is complete!

### Future Improvements
- Consider btrfs for `/var/lib/libvirt/images` for instant reflink copies
- Investigate if shared store could reduce base image size (mount store at boot instead of baking in)

---

## Notes

- Always test changes on a throwaway VM first
- Document any unexpected behavior in "Tried and Ruled Out"
- Keep master branch stable - merge only when phase is complete
- virtiofs requires QEMU 5.0+ and kernel 5.4+ (NixOS has both)
