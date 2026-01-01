# VM Deploy Improvement - Worktree Context

**This is a dedicated worktree for improving VM deployment workflows.**
**All work here focuses exclusively on this goal.**

## Quick Start

```bash
# Jump here from anywhere:
cd ~/Hydrix-vm-deploy-improvement && claude

# Or add this fish function to your config:
# function vmdeploy; cd ~/Hydrix-vm-deploy-improvement && claude; end

# Check current progress:
cat VM-DEPLOY-IMPROVEMENT.md

# When done with a session, update the tracking doc before leaving
```

## Problem Statement

Current VM workflow inefficiencies:

| Phase | Current Approach | Pain Point |
|-------|------------------|------------|
| Host image build | `nix build .#pentest-vm-full` | 10-20 min first build |
| VM deployment | `cp` base image + `virt-install` | 1-2 min (acceptable) |
| VM updates | git pull → nixos-rebuild inside VM | 5-15 min, re-downloads packages |

## Key Constraints (MUST PRESERVE)

| Constraint | Reason |
|------------|--------|
| **Host cannot SSH to VMs** | Network isolation by design |
| **Host only reaches br-mgmt + br-shared** | Security model |
| **VMs isolated from each other** | Bridge separation |
| **Main interaction is virt-manager** | User preference, not SSH |
| **Must remain lightweight** | Don't waste host resources |

## Network Topology (Reference)

```
Host (zen)
├── br-mgmt (192.168.100.1) ──── Router VM only
├── br-shared (192.168.105.1) ── Host CAN reach
├── br-pentest (NO HOST IP) ──── ISOLATED
├── br-office (NO HOST IP) ───── ISOLATED
├── br-browse (NO HOST IP) ───── ISOLATED
└── br-dev (NO HOST IP) ──────── ISOLATED
```

## Viable Approaches

### 1. virtiofs Shared /nix/store (RECOMMENDED - No Network Needed)
- VMs mount host's `/nix/store` read-only via virtio
- Rebuilds in VM instant (packages already on host)
- **Preserves network isolation completely**
- Requires: libvirt XML changes, VM fstab config

### 2. Cache VM on br-shared
- Lightweight VM runs nix-serve (like router VM)
- All VMs reach it (br-shared allows crosstalk)
- Host pushes builds to cache VM
- VMs pull from cache instead of internet
- **Preserves isolation** (host only touches cache VM)

### 3. Host-side Optimizations Only
- Parallel nix settings (`max-jobs`, `cores`)
- Build multiple images at once
- Use `cp --reflink=auto` on btrfs
- Doesn't help VM updates, but faster initial builds

## Current Workflow (for reference)

```bash
# Build full image on host
nix build .#pentest-vm-full --out-link pentest-vm-image

# Deploy VM (copies image, creates libvirt domain)
./scripts/build-vm.sh --type pentest --name google

# Update VM (rare, manual, inside VM via virt-manager console)
cd ~/Hydrix && git pull && nb
```

## Session Workflow

1. **Start**: Read `VM-DEPLOY-IMPROVEMENT.md` for current state
2. **Work**: Implement/test the next item
3. **Document**: Update tracking doc with results
4. **End**: Commit progress, note next steps

## Files in This Worktree

| File | Purpose |
|------|---------|
| `CLAUDE.md` | This file - focused context |
| `VM-DEPLOY-IMPROVEMENT.md` | Progress tracking, tests, decisions |
| `test-results/` | Logs from testing (create as needed) |

## Do NOT Work On

- General Hydrix features (use main worktree)
- Theming, polybar, i3 config
- Firefox extensions
- Anything unrelated to VM deployment speed
