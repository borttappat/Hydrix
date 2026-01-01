# VM Deploy Improvement Plan

This document tracks improvements to VM deployment and update workflows in Hydrix.

**Branch**: `vm-deploy-improvement`
**Started**: 2026-01-01
**Status**: Planning Phase

---

## Vision

Reduce time spent on VM image builds and VM updates while preserving the network isolation model. VMs should be able to rebuild/update without re-downloading packages that already exist on the host.

### Key Principles

1. **Preserve Network Isolation** - Host cannot SSH to isolated VMs. This is non-negotiable.
2. **No Host→VM Network Push** - Solutions must work without host initiating connections to VMs.
3. **Minimize Resource Usage** - Any infrastructure VMs must be lightweight (like router VM).
4. **Prefer virtiofs Over Network** - Direct store sharing via virtio avoids network entirely.
5. **Backwards Compatible** - Existing VMs continue to work, improvements are opt-in.

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

### Phase 1: Host-side Quick Wins
> Low-effort optimizations that help immediately

- [ ] **1.1** Add parallel nix settings to host configuration
  ```nix
  nix.settings = { max-jobs = "auto"; cores = 0; };
  ```
- [ ] **1.2** Update `build-vm.sh` to use `cp --reflink=auto` (instant on btrfs/zfs)
- [ ] **1.3** Test building multiple VM images in parallel
- [ ] **1.4** Document current filesystem (btrfs? ext4?) for reflink compatibility

### Phase 2: virtiofs Shared /nix/store
> Primary solution - share host's store with VMs via virtio

- [ ] **2.1** Verify host has virtiofsd available
- [ ] **2.2** Create test libvirt XML with virtiofs filesystem element
- [ ] **2.3** Test manual VM with virtiofs mount to /nix/.ro-store
- [ ] **2.4** Test nixos-rebuild inside VM using shared store
- [ ] **2.5** Create `modules/vm/shared-store.nix` for VM-side mount config
- [ ] **2.6** Update `build-vm.sh` to inject virtiofs into VM XML
- [ ] **2.7** Handle store path conflicts (VM's writable store vs host's read-only)
- [ ] **2.8** Test full flow: build image → deploy → update via shared store
- [ ] **2.9** Document any caveats or limitations

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
- [ ] **4.2** Update build-vm.sh help text
- [ ] **4.3** Add `--no-shared-store` flag if user wants isolated VMs
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

- [ ] `modules/vm/shared-store.nix` - VM-side virtiofs mount configuration
- [ ] `profiles/cache-vm.nix` - Cache VM profile (if going that route)

### Files to Modify

- [ ] `scripts/build-vm.sh` - Add virtiofs XML, reflink copy
- [ ] `modules/base/nixos-base.nix` - Add parallel nix settings
- [ ] `flake.nix` - Add cache-vm output (if needed)

### Files to Remove

- (None planned)

---

## Progress Log

### 2026-01-01

- Created `vm-deploy-improvement` branch and worktree
- Created planning document (this file)
- Created focused CLAUDE.md for worktree
- Analyzed current workflow and pain points
- Documented constraints and viable approaches
- Ruled out SSH-based approaches (violate network isolation)
- **Next**: Begin Phase 1 (parallel nix settings, reflink copy)

---

## Notes

- Always test changes on a throwaway VM first
- Document any unexpected behavior in "Tried and Ruled Out"
- Keep master branch stable - merge only when phase is complete
- virtiofs requires QEMU 5.0+ and kernel 5.4+ (NixOS has both)
