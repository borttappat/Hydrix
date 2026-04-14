# Hydrix User Configuration

This is your personal Hydrix configuration repository. It manages ALL your machines from a single location.

## Directory Structure

```
~/hydrix-config/
├── flake.nix              # Main flake - imports Hydrix, defines machines and VMs
├── machines/              # One .nix file per machine (named by hardware serial)
│   └── <serial>.nix       # Your machine config
├── profiles/              # VM profile customizations (overlay on Hydrix base)
│   ├── pentest/           # CID 102, WS 2, subnet .102
│   ├── browsing/          # CID 103, WS 3, subnet .103
│   ├── comms/             # CID 104, WS 4, subnet .104
│   ├── dev/               # CID 105, WS 5, subnet .105
│   └── lurking/           # CID 106, WS 6, subnet .106
├── shared/                # Settings shared across host machines and VMs
│   ├── common.nix         # Locale, shared packages
│   ├── wifi.nix           # WiFi credentials
│   ├── fonts.nix          # Font packages and profiles
│   ├── graphical.nix      # UI preferences (opacity, bluelight, DPI)
│   ├── polybar.nix        # Bar style, workspace labels, module layout
│   ├── i3.nix             # i3 keybindings
│   ├── fish.nix           # Shell abbreviations and functions
│   ├── alacritty.nix      # Terminal cursor, keyboard overrides
│   ├── dunst.nix          # Notification preferences
│   ├── ranger.nix         # File manager keybindings and rifle rules
│   ├── rofi.nix           # Launcher keybindings and extraConfig
│   ├── zathura.nix        # PDF viewer settings
│   ├── starship.nix       # Prompt configuration
│   ├── vim.nix            # Editor configuration
│   ├── firefox.nix        # Host Firefox toggle and user-agent
│   └── obsidian.nix       # Host Obsidian toggle and vault paths
├── colorschemes/          # Custom colorschemes (pywal JSON format)
├── specialisations/       # Boot mode modules
│   ├── _base.nix          # Minimal packages (all modes)
│   ├── lockdown.nix       # DEFAULT - hardened, no internet
│   ├── administrative.nix # Full functionality, router VM
│   └── fallback.nix       # Emergency direct WiFi
├── modules/               # Local NixOS modules
└── tasks/                 # Pentest task VM slots (task1.nix, task2.nix, ...)
```

## Machine Config Naming

Machine configs are named by **hardware serial number**, not hostname. This allows automatic detection during reinstalls — the same hardware always finds its config.

The serial is auto-detected during setup. To find it manually:
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
rebuild                  # Lockdown (default)
rebuild administrative   # Full functionality
rebuild fallback         # Emergency mode
```

## Shared Modules

All program configuration lives in `shared/`. Each file is imported by every machine in `flake.nix`. Settings use `lib.mkDefault` so machine configs can override them with plain assignment.

### graphical.nix

UI preferences shared by all machines:

```nix
hydrix.graphical.opacity.overlay       = lib.mkDefault 0.92;
hydrix.graphical.bluelight.enable      = lib.mkDefault true;
hydrix.graphical.bluelight.defaultTemp = lib.mkDefault 4500;
hydrix.graphical.scaling.auto          = lib.mkDefault true;
```

### polybar.nix

Bar style and layout:

```nix
hydrix.graphical.ui.polybarStyle = lib.mkDefault "modular";  # or "unibar"
hydrix.graphical.ui.floatingBar  = lib.mkDefault true;
hydrix.graphical.ui.bottomBar    = lib.mkDefault true;

hydrix.graphical.ui.workspaceLabels = lib.mkDefault {
  "1" = "I"; "2" = "II"; ... "10" = "X";
};
```

Available modules for the modular style:
```
pomo-dynamic  sync-dynamic  git-dynamic  mvms-dynamic  vms-dynamic
volume-dynamic  temp-dynamic  ram-dynamic  cpu-dynamic  fs-dynamic
uptime-dynamic  date-dynamic  battery-dynamic  battery-time-dynamic
focus-dynamic  xworkspaces  workspace-desc  spacer  power-profile-dynamic

(bottom bar)
rproc-bottom  cproc-bottom  vm-ram-bottom  vm-cpu-bottom
vm-sync-dev-bottom  vm-sync-stg-bottom  vm-fs-bottom
vm-tun-bottom  vm-up-bottom
```

Override module layout:
```nix
hydrix.graphical.ui.bar.top.right  = "pomo-dynamic git-dynamic battery-dynamic date-dynamic";
hydrix.graphical.ui.bar.bottom.right = "rproc-bottom vm-ram-bottom vm-cpu-bottom";
```

### fish.nix

Shell abbreviations and functions via `programs.fish.shellAbbrs` and `programs.fish.functions`.

Common abbreviations provided by Hydrix:

| Abbreviation | Expands to | Purpose |
|--------------|------------|---------|
| `mvm` | `microvm mvm` | Multi-VM command runner |
| `za` | `zenaudio` | Audio device switcher (ASUS ZenBook) |
| `zas` | `zenaudio speakers` | Enable internal speakers |
| `zah` | `zenaudio headphones` | Enable headphones |
| `zab` | `zenaudio bluetooth` | Enable Bluetooth headset |

**Multi-VM commands** - The `mvm` abbreviation is built into the framework:

```fish
# Build multiple VMs at once
mvm build files pentest browsing

# Restart multiple VMs
mvm restart files pentest browsing dev

# Rebuild (build + restart) multiple VMs
mvm rebuild vault files pentest browsing

# Same as: microvm mvm build files pentest browsing
```

### alacritty.nix

Terminal cursor shape and keyboard overrides via `programs.alacritty.settings`.

### dunst.nix

Notification dimensions and urgency settings via `services.dunst.settings`.

### ranger.nix

File manager keybindings (`rc.conf`) and MIME launch rules (`rifle.conf`) via `programs.ranger`.

### rofi.nix

Launcher dimensions and key bindings:

```nix
hydrix.graphical.ui.rofiWidth  = lib.mkDefault 500;
hydrix.graphical.ui.rofiHeight = lib.mkDefault 400;

# Full extraConfig block with fuzzy matching, vim keys, etc.
programs.rofi.extraConfig = { ... };
```

### zathura.nix

PDF viewer options via `programs.zathura.options`.

### starship.nix

Full prompt configuration inlined as a TOML string via `xdg.configFile."starship.toml".text`.

### vim.nix

Editor configuration inlined as a vimrc string via `home.file.".vimrc".text`.

### firefox.nix

```nix
# Install Firefox on the host (always on in VMs)
hydrix.graphical.firefox.hostEnable = lib.mkDefault false;

# User-agent preset: "edge-windows", "chrome-windows", "chrome-mac",
#                    "safari-mac", "firefox-windows", or null (real UA)
# hydrix.graphical.firefox.userAgent = lib.mkDefault "edge-windows";
```

Extensions are managed per VM profile. To add one, run inside the VM:
```bash
firefox-extension-add <slug>
# slug = last part of addons.mozilla.org/en-US/firefox/addon/<slug>/
```

### obsidian.nix

```nix
# Install Obsidian on the host
hydrix.graphical.obsidian.hostEnable = lib.mkDefault false;

# Vaults to deploy the Hydrix CSS theme snippet to (paths relative to $HOME)
# hydrix.graphical.obsidian.vaultPaths = lib.mkDefault [
#   "notes"
#   "hack_the_world"
# ];
```

The framework auto-generates a CSS snippet from the active colorscheme and font settings, deploying it to each vault's `.obsidian/snippets/` directory.

## MicroVMs

| VM | Purpose | CID | WS | Subnet |
|----|---------|-----|----|--------|
| `microvm-pentest` | Penetration testing | 102 | 2 | 192.168.102 |
| `microvm-browsing` | Web browsing (isolated) | 103 | 3 | 192.168.103 |
| `microvm-comms` | Communications | 104 | 4 | 192.168.104 |
| `microvm-dev` | Development | 105 | 5 | 192.168.105 |
| `microvm-lurking` | Darknet/Tor | 106 | 6 | 192.168.106 |
| `microvm-router` | WiFi VFIO passthrough | 200 | — | — |
| `microvm-builder` | Lockdown-mode builds | 210 | — | — |
| `microvm-gitsync` | Lockdown-mode git | 211 | — | — |
| `microvm-files` | Encrypted inter-VM transfer | 212 | — | — |

Custom profiles start at CID 107+. Use `new-profile <name>` to scaffold one.

**Commands:**
```bash
microvm list                          # List all declared VMs
microvm build microvm-browsing        # Build VM image
microvm start microvm-browsing        # Start VM
microvm stop microvm-browsing         # Stop VM
microvm update microvm-browsing       # Live config switch (no restart)
microvm app microvm-browsing firefox  # Launch app via xpra
microvm status                        # Show all VM status
```

## Adding a New VM Profile

```bash
new-profile myvm   # Scaffolds profiles/myvm/ with next free CID/workspace
rebuild            # Auto-discovers and wires the new profile
```

## Version Control

This is YOUR personal repo — commit it to your own GitHub/GitLab:

```bash
git add .
git commit -m "Initial Hydrix config"
git remote add origin git@github.com:YOUR_USER/hydrix-config.git
git push -u origin main
```

## Updating Hydrix

```bash
nix flake update
rebuild
```

## Using a Local Hydrix Clone

For development, point to a local clone:

```nix
# In flake.nix, change:
hydrix.url = "github:borttappat/Hydrix";
# To:
hydrix.url = "path:/home/USER/Hydrix";
```

Then run `nix flake update` after making Hydrix changes.
