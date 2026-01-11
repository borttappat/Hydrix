# Hydrix Mk2 - Rework Plan

This document tracks the migration from the current Hydrix architecture to a template-driven, local-spawning repository model.

**Branch**: `rework`
**Started**: 2026-01-01
**Status**: In Progress

---

## Vision

Hydrix is a **single working directory** with all infrastructure, templates, and a gitignored `local/` directory for machine-specific data. Running `setup.sh` populates `local/` with the machine's configuration. No separate repos, no symlinks.

### Key Principles

1. **Single Directory** - Work entirely from `~/Hydrix`, run all scripts from here
2. **Gitignored `local/`** - All machine-specific and sensitive data lives in `local/`
3. **No Password for Host** - System password set at NixOS install, not tracked
4. **Baked Credentials for VMs** - VMs get credentials at build time, baked into image
5. **Templates + Placeholders** - Configs use templates, values substituted at build
6. **External VM Rebuilds** - VMs rebuilt from host via build-vm.sh, not internally

---

## Architecture Overview

### Directory Structure

```
~/Hydrix/                              # PUBLIC - pushed to GitHub
├── flake.nix                          # Main flake, imports from local/
├── modules/                           # All NixOS modules
├── profiles/                          # VM profiles (pentest, comms, browsing, dev)
├── configs/                           # Config files (i3, polybar, fish, etc.)
├── scripts/
│   ├── setup.sh                       # Initial machine setup → creates local/
│   ├── nixbuild.sh                    # Host rebuild (reads local/)
│   └── build-vm.sh                    # VM build with bake-and-restore
├── templates/                         # Templates with @@PLACEHOLDERS@@
│   ├── host.nix.template
│   ├── machine.nix.template
│   ├── router.nix.template
│   └── vm.nix.template
├── colorschemes/
├── wallpapers/
├── local/                             # GITIGNORED - all local/sensitive data
│   ├── host.nix                       # { username = "traum"; }
│   ├── machines/
│   │   └── host.nix                   # Hardware, VFIO, bridges, specialisations (hostname set inside)
│   ├── router.nix                     # Router credentials (username, hashedPassword)
│   ├── vms/
│   │   └── <vm-name>.nix              # VM credentials (username, hashedPassword, bridge)
│   ├── vm-instance.nix                # TEMP: current VM build (deleted after)
│   └── credentials/                   # Credential reference logs
│       └── <vm-name>.json
├── REWORK.md                          # This document
└── README.md                          # Public documentation
```

### What Goes Where

| Data Type | Location | Committed? |
|-----------|----------|------------|
| NixOS modules | `modules/` | Yes |
| VM profiles | `profiles/` | Yes |
| Scripts | `scripts/` | Yes |
| Templates | `templates/` | Yes |
| Username | `local/host.nix` | No (staged with -f) |
| Machine hardware config | `local/machines/host.nix` | No (staged with -f) |
| Router credentials | `local/router.nix` | No |
| VM credentials | `local/vms/<name>.nix` | No |

### Host Configuration Architecture

The flake has ONE generic `host` entry that imports `./local/machines/host.nix`:

```nix
# flake.nix - single host entry for ALL machines
nixosConfigurations.host = nixpkgs.lib.nixosSystem {
  modules = [
    ./modules/base/hydrix-options.nix
    ./modules/base/nixos-base.nix
    # ... other modules ...
    ./local/machines/host.nix  # Machine-specific config (hostname set inside)
  ];
};
```

**Key points**:
- `setup.sh` generates `local/machines/host.nix` with detected hostname inside the file
- `nixbuild.sh` always builds `#host` with `--impure`
- No per-machine entries in flake.nix - no modification needed when setting up a new machine
- Local files must be staged with `git add -f` for nix visibility (gitignored directory)

### Specialisation Naming

| New Name | Old Name | Purpose |
|----------|----------|---------|
| `secure` | lockdown | Host isolated, VMs have internet (production default) |
| `full` | default/router | Full functionality, host has internet via router |
| `emergency` | fallback | WiFi on host, VFIO disabled, for recovery |

**Default boot**: `secure` (once setup is complete and tested)

### VM Build Flow (Bake-and-Restore)

With virtiofs shared `/nix/store`, builds are fast (packages already on host). The flow:

```
build-vm.sh runs
    │
    ├── 1. Prompt for VM password
    │   └── User enters password (masked input)
    │   └── Generate hash via mkpasswd -m sha-512
    │
    ├── 2. Generate VM-specific config
    │   └── ~/local-hydrix/vms/<vm-name>.nix
    │   └── Contains: username (default: host user), password hash, hostname
    │   └── This file is VM-specific and stays in local repo
    │
    ├── 3. Build full VM image
    │   └── Uses virtiofs shared /nix/store (instant, no downloads)
    │   └── Image contains complete system with password hash
    │   └── No post-install shaping needed
    │
    ├── 4. Bake config snapshot into VM
    │   └── Copy symlinked content (modules, scripts, configs) to VM
    │   └── Copy VM-specific config to /home/<user>/hydrix/
    │   └── VM has everything needed to rebuild itself
    │
    ├── 5. Log credentials (for user reference)
    │   └── Write to ~/local-hydrix/credentials/<vm-name>.json
    │   └── Contains plaintext password (600 permissions)
    │   └── Hash is in VM config, plaintext logged for convenience
    │
    └── 6. Register with libvirt
        └── Display name: <vm-name> (e.g., "pentest-google")
        └── Hostname: separate, can differ (e.g., "WinPC-XYZ")

VM rebuilds (inside VM):
    └── cd ~/hydrix && nixos-rebuild switch --flake .#vm-<type>
    └── Uses baked-in config, no network needed for packages
```

**Key insight**: No more base images, shaping, or hydrix-clone. VMs are complete at build time.

### Per-Font Display Configs

```
configs/display/
├── tamzen.json          # Tuned for Tamzen font
├── cozette.json         # Tuned for Cozette font
├── iosevka.json         # Tuned for Iosevka font
└── custom.json          # User overrides (optional)

Each contains:
{
  "font_size": 12,
  "bar_height": 24,
  "i3_gaps_inner": 5,
  "i3_gaps_outer": 0,
  "polybar_dpi": 96,
  ...
}
```

---

## Phase Breakdown

### Phase 1: Prepare Hydrix as Pure Infrastructure ✅
> Convert existing Hydrix repo to template-only, removing all personal data

- [x] **1.1** Audit all files for personal data (usernames, paths, secrets)
- [x] **1.2** Create `templates/` directory structure
- [x] **1.3** Convert `flake.nix` → `templates/flake.nix.template` with placeholders
- [x] **1.4** Machine profile template already exists (machine-profile-full.nix.template)
- [x] **1.5** Create `templates/secrets/` with all secret templates
- [x] **1.6** Remove obsolete modules (hydrix-clone, hydrix-embed, shaping, hardware-setup)
- [x] **1.7** Remove base/minimal image entries from flake (keep only full images)
- [x] **1.8** Rename image outputs to simpler names (pentest, comms, browsing, dev, router)
- [x] **1.9** Update modules to use "user" as fallback instead of "traum"

### Phase 1.5: Centralize VM Modules + Local Directory Structure ✅
> Move machine config to local/, create central VM base module, eliminate duplication

- [x] **1.5.1** Create `local/` directory structure (machines/, vms/, credentials/)
- [x] **1.5.2** Move `profiles/machines/zen.nix` → `local/machines/zen.nix`
- [x] **1.5.3** Create `local/host.nix` with username
- [x] **1.5.4** Create `local/shared.nix` with locale settings (timezone, keyboard, etc.)
- [x] **1.5.5** Create `modules/vm/vm-base.nix` - central module with all common VM config:
  - Hardware configuration (kernel modules, boot loader, filesystem)
  - Instance config loading from `local/vm-instance.nix`
  - Shared locale loading from `local/shared.nix`
  - Common imports (qemu-guest, shared-store, bake-config, etc.)
  - Parameterized rebuild script via `hydrix.vm.rebuildTarget` option
- [x] **1.5.6** Simplify VM profiles to only profile-specific config:
  - pentest.nix: 31 lines (was 128) - identity + pentesting modules
  - comms.nix: 60 lines (was 130) - identity + packages + tor
  - browsing.nix: 45 lines (was 141) - identity + packages + pipewire
  - dev.nix: 99 lines (was 170) - identity + packages + docker + postgresql
- [x] **1.5.7** Update `nixos-base.nix` to use `lib.mkDefault` for locale settings
- [x] **1.5.8** Delete obsolete `profiles/machines/` directory
- [x] **1.5.9** Test all VM and host builds

**Note**: Since `local/` is gitignored, files must be staged with `git add -f` before builds.
The `build-vm.sh` script should handle this automatically.

### Phase 2: Setup Script - Local Directory Creation ✅
> Rewrite setup.sh to create local/ with proper structure

- [x] **2.1** Detect: hostname, CPU, current user
- [x] **2.2** Detect: timezone, locale, keyboard from system
- [x] **2.3** Generate `local/host.nix` with username
- [x] **2.4** Generate `local/shared.nix` with locale settings
- [x] **2.5** Generate `local/machines/host.nix` from template (hostname set inside file)
- [x] **2.6** Prompt for router password → generate `local/router.nix`
- [x] **2.7** Stage local files with `git add -f` for nix visibility

### Phase 3: Host Build Integration ✅
> Make host build from ~/Hydrix with local/ configs

- [x] **3.1** Update `nixbuild.sh` to stage local files before build
- [x] **3.2** Implement specialisation detection (lockdown/fallback - kept original names)
- [x] **3.3** Test host rebuild end-to-end
- [x] **3.4** Update router VM build to use `local/router.nix`
- [x] **3.5** Test full host setup flow
- [x] **3.6** Simplify flake.nix to single `host` entry (no per-machine entries)
- [x] **3.7** Remove `update_flake()` from setup.sh (flake.nix never modified)

### Phase 4: VM Build Integration
> Update build-vm.sh to use local/ and bake configs

- [ ] **4.1** Update `build-vm.sh` to stage local files before build
- [ ] **4.2** Add `--hostname` flag separate from `--name` (display name)
- [ ] **4.3** Generate `local/vm-instance.nix` with hostname
- [ ] **4.4** Generate per-VM credentials file in `local/vms/`
- [ ] **4.5** Implement credential logging to `local/credentials/<vm-name>.json`
- [ ] **4.6** Test VM build flow end-to-end

### Phase 5: Display Configuration System
> Implement per-font display configs

- [ ] **5.1** Create `configs/display/` with font-specific JSONs
- [ ] **5.2** Update config templates to read from display config
- [ ] **5.3** Add font selection to setup flow
- [ ] **5.4** Test with multiple fonts (Tamzen, Cozette, Iosevka)

### Phase 6: Polish and Documentation
> Finalize and document

- [ ] **6.1** Rename specialisations (lockdown→secure, default→full, fallback→emergency)
- [ ] **6.2** Update CLAUDE.md for new architecture
- [ ] **6.3** Update README.md for public users
- [ ] **6.4** Create setup instructions in templates/
- [ ] **6.5** Test complete flow on fresh NixOS install
- [ ] **6.6** Clean up obsolete files from old architecture

---

## Placeholder Syntax

Templates use the following placeholder format:

```
@@PLACEHOLDER_NAME@@
```

### Host Placeholders

| Placeholder | Source | Example |
|-------------|--------|---------|
| `@@USERNAME@@` | User prompt | `traum` |
| `@@PASSWORD_HASH@@` | Generated from prompt | `$6$...` |
| `@@HOSTNAME@@` | Detected or prompted | `zen` |
| `@@TIMEZONE@@` | Detected from system | `Europe/Stockholm` |
| `@@LOCALE@@` | Detected from system | `en_US.UTF-8` |
| `@@KEYBOARD_LAYOUT@@` | Detected from system | `us` |
| `@@LUKS_DEVICE@@` | Detected from /etc/nixos | `/dev/nvme0n1p2` |
| `@@SSH_PUBLIC_KEY@@` | Prompted or generated | `ssh-ed25519 ...` |
| `@@COLORSCHEME@@` | Prompted or default | `nvid` |
| `@@DISPLAY_CONFIG@@` | Prompted or default | `tamzen` |

### VM Placeholders

| Placeholder | Source | Example |
|-------------|--------|---------|
| `@@VM_USERNAME@@` | Default: host username, or `--user` flag | `traum` |
| `@@VM_PASSWORD_HASH@@` | Generated from prompted password | `$6$...` |
| `@@VM_HOSTNAME@@` | `--hostname` flag | `WinPC-XYZ` |
| `@@VM_DISPLAY_NAME@@` | `--name` flag | `pentest-google` |
| `@@VM_TYPE@@` | `--type` flag | `pentest` |
| `@@VM_BRIDGE@@` | `--bridge` flag | `br-pentest` |

**Password handling**:
- User is ALWAYS prompted for password during VM build
- Password is hashed via `mkpasswd -m sha-512`
- Hash is included in VM config (required by NixOS for declarative password)
- Plaintext password is logged to `credentials/<vm-name>.json` for user reference
- VM configs in local repo contain the hash (they're local-only anyway)

### Router Placeholders

| Placeholder | Source | Example |
|-------------|--------|---------|
| `@@ROUTER_USERNAME@@` | Default: `user`, or prompted | `user` |
| `@@ROUTER_PASSWORD_HASH@@` | Generated from prompted password | `$6$...` |

**Note**: Same password handling as VMs - prompted, hashed, logged to credentials.

---

## Credential Storage Format

`local/credentials/<vm-name>.json`:

```json
{
  "display_name": "pentest-google",
  "hostname": "WinPC-XYZ",
  "vm_type": "pentest",
  "bridge": "br-pentest",
  "username": "user",
  "password": "generated-password-here",
  "created": "2026-01-01T14:30:00Z",
  "image_path": "/var/lib/libvirt/images/pentest-google.qcow2"
}
```

Password is stored in plaintext for convenience. File permissions: `600` (user read/write only).

---

## Migration Path for Existing Users

For users with current Hydrix setup:

1. Backup current `local/` directory
2. Pull latest Hydrix with rework changes
3. Run new `setup.sh` - it will:
   - Detect existing configuration where possible
   - Prompt for any missing information
   - Populate `local/` directory with config files
4. Stage local files: `git add -f local/*.nix local/machines/*.nix`
5. Rebuild host: `./scripts/nixbuild.sh`
6. Existing VMs continue to work (they're self-contained)
7. New VMs built from new setup

---

## Tried and Ruled Out

This section documents approaches that were considered but rejected.

| Approach | Reason Rejected | Date |
|----------|-----------------|------|
| Symlinks from local-hydrix to Hydrix | Nix flakes in pure mode don't follow symlinks to outside directories | 2026-01-08 |
| Separate `~/local-hydrix/` repository | Added complexity, flake input management, no clear benefit over gitignored `local/` | 2026-01-10 |

---

## Open Questions / Decisions

Track decisions that need to be made or questions that arise.

| Question | Status | Decision |
|----------|--------|----------|
| Should display configs be per-machine or global? | Decided | Per-local-repo (in `~/local-hydrix/display/`) |
| Root ownership for credentials? | Decided | No, regular user permissions with 600 mode |
| Password manager integration? | Deferred | Start with file-based, add later if needed |
| Base image caching for VMs? | Deferred | Separate branch, not part of this rework |

---

## File Changes Tracking

### New Files to Create

- [ ] `templates/flake.nix.template`
- [ ] `templates/machine.nix.template`
- [ ] `templates/secrets/host.nix.template`
- [ ] `templates/secrets/router.nix.template`
- [ ] `templates/secrets/vm.nix.template`
- [ ] `configs/display/tamzen.json`
- [ ] `configs/display/cozette.json`
- [ ] `configs/display/iosevka.json`

### Files to Modify

- [x] `setup.sh` - Rewritten: no flake modification, outputs to `local/machines/host.nix`
- [x] `scripts/nixbuild.sh` - Rewritten: always builds `#host`, stages local files
- [ ] `scripts/build-vm.sh` - Add hostname flag, credential logging, config baking
- [x] `flake.nix` - Simplified to single `host` entry (no template needed)
- [x] `modules/base/users.nix` - Added `virtualisation.mainUser` setting

### Files to Remove

- [x] `modules/vm/hydrix-clone.nix` (removed - configs baked at build)
- [x] `modules/vm/hydrix-embed.nix` (removed - no more shaping)
- [x] `modules/vm/shaping.nix` (removed - no more post-install shaping)
- [x] `modules/vm/hardware-setup.nix` (removed)
- [x] All `*-vm-base` and `*-vm-base-minimal` entries in flake.nix (removed)
- [x] `profiles/pentest-base-minimal.nix` (removed)
- [x] `profiles/base-vm.nix` (removed)
- [x] `profiles/machines/zen.nix` (moved to `local/machines/host.nix`)
- [x] Per-machine flake entries like `zen` (replaced by single `host` entry)

### Flake Cleanup - Simplified Naming

**Remove** (obsolete base/minimal images):
- `pentest-vm-base-minimal`, `pentest-vm-base`
- `comms-vm-base`, `browsing-vm-base`, `dev-vm-base`
- `pentest-vm-full`, `browsing-vm-full`, etc. (rename to simpler names)

**Keep** (renamed for simplicity):
- `pentest` (was `pentest-vm-full`)
- `comms` (was `comms-vm-full`)
- `browsing` (was `browsing-vm-full`)
- `dev` (was `dev-vm-full`)
- `router` (was `router-vm`)

**Build commands become**:
```bash
nix build .#pentest    # Build pentest VM image
nix build .#browsing   # Build browsing VM image
nix build .#router     # Build router VM image
```

---

## Progress Log

### 2026-01-10 - Router VM Credentials from local/router.nix

**Problem**: Router VM had hardcoded credentials (`user`/`router`) which other VMs on the network could use to SSH into the router.

**Solution**: Router VM now reads credentials from `local/router.nix` (like other local configs).

**Files changed**:

| File | Change |
|------|--------|
| `modules/router-vm-unified.nix` | Added import of `../local/router.nix`, uses `routerUser` and `routerHashedPassword` |
| `scripts/setup.sh` | Added `generate_router_config()` - prompts for password, generates hash, creates `local/router.nix` |
| `scripts/nixbuild.sh` | Added `local/router.nix` to staged files list |

**Testing**:
```bash
git add -f local/router.nix
nix build .#router --dry-run  # SUCCESS
```

**Router access after setup**:
```bash
ssh <username>@192.168.100.253
```

---

### 2026-01-10 - Simplified Host Configuration (Single Generic Entry)

**Goal**: Remove per-machine flake entries in favor of ONE generic `host` entry.

**Problem solved**: Previously, `setup.sh` would add new machine entries to `flake.nix` for each hostname (zen, laptop, etc.). This modified committed files and accumulated cruft.

**Solution**:
- `flake.nix` has ONE `host` entry that imports `./local/machines/host.nix`
- `local/machines/host.nix` contains all machine-specific config INCLUDING the hostname
- `setup.sh` generates to `local/machines/host.nix`, never modifies `flake.nix`
- `nixbuild.sh` always builds `#host` with `--impure`

**Files changed**:

| File | Change |
|------|--------|
| `flake.nix` | Removed `zen` entry, simplified `host` entry to import `./local/machines/host.nix` directly |
| `local/machines/zen.nix` → `host.nix` | Renamed (hostname "zen" set inside file) |
| `scripts/nixbuild.sh` | Rewritten to always build `#host`, stages local files, detects specialisation |
| `scripts/setup.sh` | Removed `update_flake()`, outputs to `local/machines/host.nix`, updated help |
| `modules/base/users.nix` | Added `virtualisation.mainUser = username;` to fix user config |

**Testing**:
```bash
git add -f local/machines/host.nix local/host.nix local/shared.nix
nix eval .#nixosConfigurations.host.config.networking.hostName --impure  # "zen"
nix eval .#nixosConfigurations.host.config.virtualisation.mainUser --impure  # "traum"
nix eval .#nixosConfigurations.host.config.system.build.toplevel --impure  # SUCCESS
```

**Architecture now**:
```
flake.nix
└── nixosConfigurations.host    # ONE entry for ALL host machines
    └── imports ./local/machines/host.nix

local/                          # GITIGNORED - staged with git add -f
├── host.nix                    # { username = "traum"; }
├── shared.nix                  # { timezone, locale, keyboard }
└── machines/
    └── host.nix                # Hardware, VFIO, bridges, specialisations
                                # Sets networking.hostName inside this file
```

---

### 2026-01-06 - Pure Evaluation Mode Fix

**Problem**: VM builds failing with:
```
error: access to absolute path '/home' is forbidden in pure evaluation mode (use '--impure' to override)
```

This was caused by multiple modules having duplicated username detection logic that tried to access absolute paths like `/home/${effectiveUser}/local-hydrix/secrets/host.nix`. Even with `if isVM then null else ...` guards, Nix evaluates string expressions in all branches.

**Solution**: Created centralized `modules/base/hydrix-options.nix` - the **Single Source of Truth** for:
- `hydrix.vmType` - pentest, comms, browsing, dev, host, or null
- `hydrix.colorscheme` - name of colorscheme from colorschemes/*.json
- `hydrix.username` - computed once, used everywhere
- `hydrix.vm.user` - alias for backwards compatibility

**How it works**:
1. For VMs (pure mode): reads username from `local/vms/<hostname>.nix` via RELATIVE path
2. For hosts (impure mode): reads from `secrets/host.nix` or detects from environment
3. Never constructs absolute paths when building VMs

**Files changed**:

| File | Change |
|------|--------|
| `modules/base/hydrix-options.nix` | **NEW** - Centralized options and username detection |
| `flake.nix` | Added hydrix-options.nix import to host configs (zen, host) |
| `templates/flake.nix.template` | Added hydrix-options.nix import to host config |
| `profiles/pentest.nix` | Added hydrix-options.nix as FIRST import |
| `profiles/comms.nix` | Added hydrix-options.nix as FIRST import |
| `profiles/browsing.nix` | Added hydrix-options.nix as FIRST import |
| `profiles/dev.nix` | Added hydrix-options.nix as FIRST import, use `config.hydrix.username` |
| `modules/core.nix` | Simplified to use `config.hydrix.username` |
| `modules/theming/static-colors.nix` | Simplified, removed duplicate option definitions |
| `modules/theming/base.nix` | Simplified to use `config.hydrix.username` |
| `modules/desktop/xinitrc.nix` | Simplified to use `config.hydrix.username` |
| `modules/desktop/firefox.nix` | Simplified to use `config.hydrix.username` |
| `modules/pentesting/pentesting.nix` | Updated to use `config.hydrix.username` |
| `modules/base/users-vm.nix` | Simplified, removed duplicate option definition |
| `modules/vm/bake-config.nix` | Updated to use `config.hydrix.username` |

**Import order matters**: `hydrix-options.nix` MUST be imported BEFORE other modules that use `config.hydrix.*`. In profiles, it's the FIRST import. In flake.nix host configs, it comes right after home-manager.

**Testing**: After making these changes:
1. `git add` all modified files (including the new hydrix-options.nix)
2. Run from `~/local-hydrix/`: `./scripts/build-vm.sh --type pentest --name test1`
3. The pure evaluation mode error should be resolved

**Additional fix needed**: `modules/shell/fish-home.nix` WAS in the VM import chain (via `core.nix → fish.nix → fish-home.nix`) and was updated to use `config.hydrix.username`.

**Modules NOT yet updated** (used by hosts only, not VMs):
- `modules/base/system-config.nix`
- `modules/base/users.nix`
- `modules/base/local-config.nix`
- `modules/theming/dynamic.nix`

These modules are only imported by host configurations which use `--impure`, so they don't need the fix.

---

### 2026-01-10 - Centralize VM Modules + Single Repo Architecture

**Decision**: Abandoned the separate `~/local-hydrix/` repo approach in favor of a gitignored `local/` directory within the main Hydrix repo. Simpler, less complexity.

**Key changes**:

1. **Moved machine config to local/**
   - `profiles/machines/zen.nix` → `local/machines/zen.nix`
   - Created `local/host.nix` with `{ username = "traum"; }`
   - Created `local/shared.nix` with locale settings

2. **Created central VM base module** (`modules/vm/vm-base.nix`)
   - All common hardware config (kernel modules, boot loader, filesystem)
   - Instance config loading from `local/vm-instance.nix`
   - Shared locale loading from `local/shared.nix`
   - Common imports (qemu-guest, shared-store, bake-config, core, theming, firefox)
   - Parameterized rebuild script via `hydrix.vm.rebuildTarget` option
   - New options: `hydrix.vm.defaultHostname`, `hydrix.vm.rebuildTarget`

3. **Simplified all VM profiles**
   - pentest.nix: 128 → 31 lines (just imports + identity + pentesting modules)
   - comms.nix: 130 → 60 lines (identity + packages + tor)
   - browsing.nix: 141 → 45 lines (identity + packages + pipewire)
   - dev.nix: 170 → 99 lines (identity + packages + docker + postgresql)

4. **Updated nixos-base.nix** to use `lib.mkDefault` for locale settings so VMs can override

**Important discovery**: Since `local/` is gitignored, files must be staged with `git add -f` before nix can see them. The build scripts need to handle this.

**Testing**:
```bash
git add -f local/shared.nix local/host.nix
nix eval .#nixosConfigurations.vm-pentest.config.networking.hostName  # "pentest-vm"
nix eval .#nixosConfigurations.vm-comms.config.networking.hostName    # "comms-vm"
nix eval .#nixosConfigurations.zen.config.networking.hostName --impure # "zen"
nix build .#pentest --dry-run  # SUCCESS
```

---

### 2026-01-08 - Symlink Architecture Attempted (SUPERSEDED)

Attempted separate `~/local-hydrix/` repo with flake inputs. This worked but added unnecessary complexity. Superseded by simpler gitignored `local/` approach on 2026-01-10.

---

### 2026-01-04

- Merged master branch changes (virtiofs shared /nix/store, etc.)
- Updated architecture based on decisions:
  - Simplified to full images only (no base/shaping)
  - VM passwords prompted at build, hash in config, plaintext in credentials
  - VM username defaults to host user
  - Simpler naming: `pentest`, `comms`, `browsing`, `dev`, `router`
- **Phase 1 COMPLETE**:
  - Created `templates/secrets/` with host.nix.template, router.nix.template, vm.nix.template
  - Created `templates/flake.nix.template` with simplified structure
  - Removed obsolete modules: hydrix-clone.nix, hydrix-embed.nix, shaping.nix, hardware-setup.nix
  - Removed obsolete profiles: base-vm.nix, pentest-base.nix, pentest-base-minimal.nix, nixos-base-minimal.nix
  - Cleaned flake.nix: removed all base/minimal images, renamed to simple names
  - Updated all modules to use "user" as fallback instead of "traum"
  - Updated router VM configs to use "user" as default username
  - Updated profiles to remove hydrix-clone.nix import

### 2026-01-01

- Created `rework` branch from master
- Created this planning document (REWORK.md)
- Established architecture and phase breakdown

---

## Notes

- Always test on fresh NixOS install before considering phase complete
- Keep master branch stable - only merge when phase is fully tested
- Document any "tried and ruled out" approaches immediately
- Update this document as decisions are made
