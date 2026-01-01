# Hydrix Mk2 - Rework Plan

This document tracks the migration from the current Hydrix architecture to a template-driven, local-spawning repository model.

**Branch**: `rework`
**Started**: 2026-01-01
**Status**: In Progress

---

## Vision

Hydrix becomes **pure infrastructure** - a collection of templates, modules, and scripts with zero personal data. Running `setup.sh` creates a **local-only repository** (`~/local-hydrix/`) on each machine, which contains the actual working configuration with secrets and machine-specific settings.

### Key Principles

1. **Hydrix = Public Infrastructure** - Templates, modules, scripts. No secrets, no usernames, no personal data.
2. **Local Repo = Private Configuration** - Machine-specific settings, secrets, credentials. Never pushed anywhere.
3. **Symlink Bridge** - Public files symlinked from Hydrix → local repo. Changes to Hydrix propagate automatically.
4. **Secrets Stay Local** - Private files exist only in local repo, never symlinked.
5. **Template-Driven Builds** - Placeholders populated at build time from local secrets.
6. **VMs Are Self-Contained** - Local repo state baked into VMs at build time. No post-install cloning.

---

## Architecture Overview

### Directory Structure

```
~/Hydrix/                              # PUBLIC - pushed to GitHub
├── modules/                           # NixOS modules (symlinked to local)
├── configs/                           # Config files (symlinked to local)
├── scripts/                           # Build/setup scripts (symlinked to local)
├── templates/                         # Used by setup, NOT symlinked
│   ├── flake.nix.template
│   ├── machine.nix.template
│   └── secrets/
│       ├── host.nix.template
│       ├── router.nix.template
│       └── vm.nix.template
├── colorschemes/                      # Symlinked to local
├── wallpapers/                        # Symlinked to local
├── setup.sh                           # Entry point - creates local repo
├── REWORK.md                          # This document
└── README.md                          # Public documentation

~/local-hydrix/                        # PRIVATE - git init locally, never pushed
├── modules/ → ~/Hydrix/modules/       # Symlink
├── configs/ → ~/Hydrix/configs/       # Symlink
├── scripts/ → ~/Hydrix/scripts/       # Symlink
├── colorschemes/ → ~/Hydrix/colorschemes/  # Symlink
├── wallpapers/ → ~/Hydrix/wallpapers/      # Symlink
├── flake.nix                          # LOCAL - generated from template
├── machines/                          # LOCAL - host machine configs
│   └── <hostname>.nix
├── secrets/                           # LOCAL - never symlinked
│   ├── host.nix                       # Host username, password hash, SSH keys
│   ├── router.nix                     # Router VM credentials
│   └── vms/                           # Per-VM secrets
│       └── <vm-name>.nix
├── credentials/                       # LOCAL - VM credential log
│   └── <vm-name>.json                 # Timestamp, username, password
└── display/                           # LOCAL - display configurations
    └── config.json                    # Current display settings
```

### Symlink Strategy

**Symlinked (public, shared):**
- `modules/` - All NixOS modules
- `configs/` - All config templates (i3, polybar, fish, etc.)
- `scripts/` - All scripts
- `colorschemes/` - Color scheme JSONs
- `wallpapers/` - Wallpaper images

**Local only (private, machine-specific):**
- `flake.nix` - Contains machine-specific entries
- `machines/` - Generated machine profiles
- `secrets/` - All sensitive data
- `credentials/` - VM credential log
- `display/` - Display configuration

### Specialisation Naming

| New Name | Old Name | Purpose |
|----------|----------|---------|
| `secure` | lockdown | Host isolated, VMs have internet (production default) |
| `full` | default/router | Full functionality, host has internet via router |
| `emergency` | fallback | WiFi on host, VFIO disabled, for recovery |

**Default boot**: `secure` (once setup is complete and tested)

### VM Build Flow

```
build-vm.sh runs
    │
    ├── Generate VM config from templates
    │   └── Populate: username, password, hostname, display-name
    │
    ├── Build VM image (existing quick build)
    │
    ├── Bake snapshot into VM
    │   └── Copy relevant configs to /home/user/hydrix-snapshot/
    │   └── VM can rebuild from this frozen state
    │
    ├── Log credentials
    │   └── Write to ~/local-hydrix/credentials/<vm-name>.json
    │
    └── Register with libvirt
        └── Display name: <vm-name> (e.g., "pentest-google")
        └── Hostname: separate, can differ (e.g., "WinPC-XYZ")
```

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

### Phase 1: Prepare Hydrix as Pure Infrastructure
> Convert existing Hydrix repo to template-only, removing all personal data

- [ ] **1.1** Audit all files for personal data (usernames, paths, secrets)
- [ ] **1.2** Create `templates/` directory structure
- [ ] **1.3** Convert `flake.nix` → `templates/flake.nix.template` with placeholders
- [ ] **1.4** Convert machine profiles → `templates/machine.nix.template`
- [ ] **1.5** Create `templates/secrets/` with all secret templates
- [ ] **1.6** Remove current `local/` directory handling (will be replaced)
- [ ] **1.7** Update modules to use placeholder paths instead of hardcoded usernames
- [ ] **1.8** Ensure all modules work with template variables

### Phase 2: Setup Script - Local Repo Creation
> Rewrite setup.sh to create ~/local-hydrix/ with proper structure

- [ ] **2.1** Create local repo directory structure
- [ ] **2.2** Implement symlink creation for public directories
- [ ] **2.3** Generate `flake.nix` from template with machine entry
- [ ] **2.4** Prompt for host secrets (username, password)
- [ ] **2.5** Detect system settings (locale, timezone, keyboard, LUKS)
- [ ] **2.6** Generate `secrets/host.nix` from template
- [ ] **2.7** Generate machine profile from template
- [ ] **2.8** Initialize git repo in local directory
- [ ] **2.9** Prompt for router credentials
- [ ] **2.10** Generate `secrets/router.nix` from template

### Phase 3: Host Build Integration
> Make host build from ~/local-hydrix/

- [ ] **3.1** Update `nixbuild.sh` to use local repo path
- [ ] **3.2** Implement specialisation detection with new names (secure/full/emergency)
- [ ] **3.3** Test host rebuild from local repo
- [ ] **3.4** Update router VM build to use local secrets
- [ ] **3.5** Test full host setup flow end-to-end

### Phase 4: VM Build Integration
> Update VM builds to use local repo and bake configs

- [ ] **4.1** Update `build-vm.sh` to read from local repo
- [ ] **4.2** Add `--hostname` flag separate from `--name` (display name)
- [ ] **4.3** Generate per-VM secrets file
- [ ] **4.4** Implement config baking (copy snapshot to VM image)
- [ ] **4.5** Implement credential logging to `credentials/<vm-name>.json`
- [ ] **4.6** Remove hydrix-clone.nix (no longer needed)
- [ ] **4.7** Create simple per-VM rebuild script (baked into VM)
- [ ] **4.8** Test VM build flow end-to-end

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
- [ ] **6.4** Create `templates/local/README.md` with setup instructions
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
| `@@VM_USERNAME@@` | Prompted or default | `user` |
| `@@VM_PASSWORD_HASH@@` | Generated | `$6$...` |
| `@@VM_HOSTNAME@@` | `--hostname` flag | `WinPC-XYZ` |
| `@@VM_DISPLAY_NAME@@` | `--name` flag | `pentest-google` |
| `@@VM_TYPE@@` | `--type` flag | `pentest` |
| `@@VM_BRIDGE@@` | `--bridge` flag | `br-pentest` |

### Router Placeholders

| Placeholder | Source | Example |
|-------------|--------|---------|
| `@@ROUTER_USERNAME@@` | Prompted | `user` |
| `@@ROUTER_PASSWORD_HASH@@` | Generated from prompt | `$6$...` |

---

## Credential Storage Format

`~/local-hydrix/credentials/<vm-name>.json`:

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
   - Create `~/local-hydrix/` with migrated settings
4. Rebuild host from new location
5. Existing VMs continue to work (they're self-contained)
6. New VMs built from new setup

---

## Tried and Ruled Out

This section documents approaches that were considered but rejected.

| Approach | Reason Rejected | Date |
|----------|-----------------|------|
| *None yet* | - | - |

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

- [ ] `setup.sh` - Complete rewrite
- [ ] `scripts/nixbuild.sh` - Update paths, specialisation names
- [ ] `scripts/build-vm.sh` - Add hostname flag, credential logging, config baking
- [ ] `flake.nix` - Convert to template
- [ ] All modules with hardcoded usernames/paths

### Files to Remove

- [ ] `local/` directory structure (replaced by ~/local-hydrix/)
- [ ] `templates/local/` examples (new template system)
- [ ] `modules/vm/hydrix-clone.nix` (no longer needed)

---

## Progress Log

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
