# Hydrix Templates

This directory contains templates used by `install-hydrix.sh` and `setup-hydrix.sh` to generate a new `~/hydrix-config/` repository.

## How Templates Are Used

```
┌─────────────────────────────────────────────────────────────────────┐
│  install-hydrix.sh / setup-hydrix.sh                                │
│                                                                     │
│  Fresh install:                                                     │
│    1. Auto-detect hardware (CPU, WiFi PCI, ASUS, serial)            │
│    2. Prompt for identity (username, colorscheme, disk, WiFi)       │
│    3. Copy templates/user-config/ → ~/hydrix-config/               │
│    4. Substitute @PLACEHOLDERS@ in user.nix, common.nix, machine    │
│    5. nixos-install → pre-build router, router-stable, builder     │
│                                                                     │
│  Add machine (existing hydrix-config detected):                     │
│    1. Clone existing repo                                           │
│    2. Auto-detect hardware only (no identity prompts)               │
│    3. Generate machines/<serial>.nix with detected hardware         │
│    4. nixos-install → pre-build router, router-stable, builder     │
└─────────────────────────────────────────────────────────────────────┘
```

Templates are **one-time provisioning**. After the initial install, `~/hydrix-config/` is a regular git repository owned by the user. Template files are never updated by Hydrix after installation.

## Directory Structure

```
templates/user-config/               # Becomes ~/hydrix-config/
├── flake.nix                        # Main flake (imports Hydrix, discovers all VMs)
├── .gitignore                       # Nix build output symlink (result)
├── machines/
│   └── installer.nix                # Machine config template (copied, @PLACEHOLDERS@ filled)
├── modules/                         # Shared settings (all machines + VMs)
│   ├── user.nix                     # Identity: username, colorscheme, WM, services
│   ├── common.nix                   # Locale, timezone, keyboard
│   ├── graphical.nix                # UI prefs: gaps, bar, opacity, lockscreen
│   ├── fonts.nix                    # Font package + per-app profiles
│   ├── fish.nix                     # Shell aliases, abbreviations, functions
│   ├── alacritty.nix                # Terminal cursor, keyboard overrides
│   ├── notifications.nix            # Notification popup size, sound, timeouts
│   ├── ranger.nix                   # File manager keybindings, rifle rules
│   ├── starship.nix                 # Prompt (TOML inlined as Nix string)
│   ├── vim.nix                      # Editor (vimrc inlined as Nix string)
│   ├── firefox.nix                  # Host Firefox toggle, user-agent spoofing
│   ├── obsidian.nix                 # Host Obsidian toggle, vault CSS deployment
│   ├── hyprland.nix                 # Hyprland keybindings and extra rules
│   ├── waybar.nix                   # Waybar module layout and styling
│   ├── helix.nix                    # Helix editor config
│   ├── eww.nix                      # eww widget daemon (exit-nodes, vm-status overlay)
│   ├── tor-hardening.nix            # Tor anonymity module (import in lurking profile)
│   ├── repos.nix                    # Declarative git repo clone list
│   ├── host-packages.nix            # Host-only packages beyond framework defaults
│   ├── shell-packages.nix           # Shell packages present on host and all VMs
│   └── vm-packages.nix              # Packages present in all profile VMs
├── profiles/                        # Graphical VM overrides
│   ├── browsing/
│   │   ├── meta.nix                 # CID 103, br-browse, ws 3, label BROWSING
│   │   ├── default.nix              # colorscheme, RAM/vCPU, extra packages
│   │   └── packages/default.nix    # vm-sync managed packages
│   ├── pentest/
│   ├── dev/
│   ├── comms/
│   └── lurking/
├── infra/                           # Headless infrastructure VM user configs
│   ├── router/
│   │   ├── meta.nix                 # CID 200, no workspace, builtinVm=true
│   │   └── default.nix              # DNS servers, extra packages, firewall overrides
│   ├── router-stable/               # Break-glass fallback router
│   ├── builder/                     # Lockdown-mode nix builder
│   ├── files/                       # Encrypted inter-VM file transfer
│   ├── gitsync/                     # Lockdown-mode git push/pull
│   ├── hostsync/                    # Secure host file inbox
│   ├── vault/                       # Offline KeePassXC password database (hydrix.vault.agent)
│   └── usb-sandbox/                 # Safe USB device handling
├── tasks/                           # Task slots, generated from one block
│   ├── default.nix                  # count, baseCid, base profile, secrets, shared module
│   └── slots.nix                    # expands default.nix: CID, bridge, subnet per slot
├── specialisations/
│   ├── _base.nix                    # Packages present in all boot modes
│   ├── lockdown.nix                 # Default: hardened, no host internet
│   ├── administrative.nix           # Full functionality, router VM gateway
│   ├── fallback.nix                 # Emergency: direct WiFi, no VMs
│   └── leisure.nix.example          # Example custom specialisation
├── colorschemes/
│   └── example-custom.json          # Custom pywal colorscheme example
├── fonts/
│   ├── default.nix                  # Font profile map (family → profile name)
│   ├── iosevka.nix                  # Iosevka per-app size relations
│   ├── tamzen.nix                   # Tamzen per-app size relations
│   └── cozette.nix                  # Cozette per-app size relations
├── vpn/
│   └── mullvad.nix                  # Per-bridge Mullvad exit node mapping
├── custom/                          # Your own modules (created empty)
└── templates/
    └── profiles/_template/          # Scaffold for new-profile command
        ├── meta.nix                 # __CID__, __BRIDGE__, __WORKSPACE__ placeholders
        ├── default.nix              # colorscheme, RAM, vCPU defaults
        └── packages/default.nix    # Empty package list
```

`secrets/` is not templated here - both installers generate `secrets/.sops.yaml` (and encrypt any WiFi/GitHub credentials collected during install) directly at install time via `init_sops_during_install`/`init_sops_and_wifi`. See [DOCUMENTATION.md § Secrets Management](../DOCUMENTATION.md#secrets-management) for the full `hydrix-sops-setup` reference and the master-key install/reinstall workflow.

---

## Module Reference

### modules/user.nix - Shared Identity

**Installer populates**: username, colorscheme, WM choice, services.  
**Applies to**: all machines via `lib.mkDefault` - override per-machine with plain assignment.

```nix
{
  hydrix.username    = lib.mkDefault "@USERNAME@";
  hydrix.hostname    = lib.mkDefault "hydrix";
  hydrix.colorscheme = lib.mkDefault "@COLORSCHEME@";

  hydrix.hyprland.enable = lib.mkDefault true;

  hydrix.services.tailscale.enable = lib.mkDefault false;
}
```

All values use `lib.mkDefault`, so a machine config can do `hydrix.username = "other"` without `lib.mkForce`.

### modules/common.nix - Shared Locale

**Installer populates**: timezone, locale, keyboard layout from the running system.  
**Applies to**: all machines and all VMs (VMs inherit host locale via `hostConfig`).

```nix
{
  time.timeZone            = lib.mkDefault "@TIMEZONE@";
  i18n.defaultLocale       = lib.mkDefault "@LOCALE@";
  console.keyMap           = lib.mkDefault "@CONSOLE_KEYMAP@";
  services.xserver.xkb.layout  = lib.mkDefault "@XKB_LAYOUT@";
  services.xserver.xkb.variant = lib.mkDefault "@XKB_VARIANT@";

  hydrix.graphical.keyboard.layout  = lib.mkDefault "@XKB_LAYOUT@";
  hydrix.graphical.keyboard.variant = lib.mkDefault "@XKB_VARIANT@";
}
```

Edit this file to change locale across all machines at once. Per-machine overrides use plain assignment in `machines/<serial>.nix`.

### modules/graphical.nix - Shared UI Preferences

Not populated by the installer. Copied from templates with all options commented out. Controls:
- Window gaps, border width, corner radius
- Bar height and position
- Window opacity (active, inactive, per-class rules)
- Bluelight filter (temperature, schedule)
- Lockscreen (timeout, text, blur)
- HiDPI scaling defaults

All options use `lib.mkDefault` so per-machine overrides work with plain assignment.

### WiFi Credentials (secrets/wifi.yaml)

Known networks live sops-encrypted in `secrets/wifi.yaml` and reach the router VM at boot
through `hydrix.secrets.wifiSecretsFile`; nothing is baked into the Nix store. The installer
creates the file from the WiFi used during installation; afterwards use `wifi-sync`, which
creates it on its first save if it does not exist:

```bash
wifi-sync add "NetworkName" "password"
wifi-sync pull                 # save networks added on the router at runtime
wifi-sync remove "OldNetwork"
```

An older config with a `modules/wifi.nix` network list migrates with `setup-wifi-secrets`
(`hydrix.router.wifi.networks` no longer exists).

### modules/fonts.nix - Font Configuration

Declares which font packages are installed and links them to font profiles:

```nix
{
  hydrix.graphical.font = {
    family = "Iosevka";
    vmPackages = with pkgs; [ iosevka tamzen cozette ];
    packageMap = {
      "Iosevka" = pkgs.iosevka;
      "Tamzen"  = pkgs.tamzen;
    };
  };
}
```

Per-app size relations live in `fonts/iosevka.nix` (etc.) and activate when `font.family` matches.

### modules/fish.nix - Shell Configuration

Extends the framework's fish config with user-specific abbreviations, functions, and environment:

```nix
{
  programs.fish.shellAbbrs = {
    ll = "ls -la";
    gp = "git push";
  };
  programs.fish.functions = {
    mkcd = "mkdir -p $argv[1]; cd $argv[1]";
  };
}
```

### modules/tor-hardening.nix - Tor Anonymity

Not imported by default. Import it in the lurking VM profile for Tor hardening:

```nix
# profiles/lurking/default.nix
imports = [ ../../modules/tor-hardening.nix ];
hydrix.tor.hardening = {
  enable = true;
  level = "moderate";
  bridgeType = "obfs4";
};
```

### Passwords (framework, `host/passwords.nix`)

Set `hydrix.passwords.backend` in your machine config: `"vm"` (KeePassXC in the offline vault
VM, `infra/vault`), `"host"` (keepassxc-cli on the host) or `"none"` (the default, no Hydrix
password frontend). With a backend set, `vault` is an fzf TUI and `vault-pick` (Mod+P) opens it
floating. The database is `~/vault/Passwords.kdbx`; the first `vault` creates it. See
DOCUMENTATION.md, "Passwords".

### modules/repos.nix - Git Repos

Each repo is declared once (Hydrix options `hydrix.repos`), imported by every machine and by
the git VM. The host holds the clones and makes every commit, with no GitHub credential; the
git VM (`infra/gitsync`) holds the key and clones (`ensure-repos`), pushes and pulls, also in
lockdown; a VM gets a repo only when the machine config
names it in `hydrix.microvmHost.vms.<vm>.repos` (editable working tree, `.git` read-only):

```nix
hydrix.repos = {
  enable = true;
  owner = "you";                          # url github.com/you/<name>, path ~/<name>
  entries = {
    notes = {};
    vault = { clone = false; };           # no remote yet
  };
};
```

### USB devices (framework, `host/usb.nix`)

The host never binds USB storage (`hydrix.usb.blockHostStorage`, default on; the fallback
specialisation turns it off). Plugging in a stick only notifies; `usb attach <busid> <vm>`
hands the whole device to a microVM whose `meta.nix` sets `usbPassthrough = true` (or a libvirt
domain) after a y/N prompt. Devices a VM should always have, such as a USB WiFi adapter for
pentest, go in its `meta.nix` as `usbDevices = [ "148f:5572" ];` (vendor:product from `lsusb`).

---

## Machine Template (`machines/installer.nix`)

**Copied to**: `~/hydrix-config/machines/<serial>.nix` with `@PLACEHOLDERS@` substituted.

The machine config is hardware-only. It sets values that differ per physical machine:
- VFIO WiFi passthrough (PCI address, vendor/device IDs)
- Disk layout (device, swap size, partition scheme)
- Platform (intel/amd/generic)
- Display scaling (Hyprland internal scale and output name)
- Keyboard remapping (optional custom xkb keymap)
- Boot mode specialisations

It does **not** set username, colorscheme, locale, or WM - those live in `modules/user.nix` and `modules/common.nix` and are shared across all machines.

**Substitutions made by the installer:**

| Placeholder | Source |
|-------------|--------|
| `@SERIAL@` | `/sys/class/dmi/id/product_serial` |
| `@USERNAME@` | Prompted or detected from current user |
| `@PASSWORD_HASH@` | Prompted (mkpasswd) or empty |
| `@COLORSCHEME@` | Prompted |
| `@PLATFORM@` | Detected: `intel` / `amd` / `generic` |
| `@IS_ASUS@` | Detected: `true` / `false` |
| `@VFIO_ENABLE@` | Detected: `true` / `false` |
| `@WIFI_PCI_ID@` | Detected from `lspci` |
| `@WIFI_PCI_ADDRESS@` | Detected from `lspci` |
| `@DEVICE@` | Selected disk (e.g. `/dev/nvme0n1`) |
| `@SWAP_SIZE@` | Detected from available RAM |
| `@LAYOUT@` | Disk layout type |
| `@GRUB_GFXMODE@` | Detected display resolution |
| `@TIMEZONE@` | Detected from running system |
| `@LOCALE@` | Detected from running system |
| `@XKB_LAYOUT@` | Detected from running system |
| `@XKB_VARIANT@` | Detected from running system |
| `@CONSOLE_KEYMAP@` | Detected from running system |

---

## VM Profile Templates

### profiles/ - Graphical VM Overrides

Each profile directory has the same structure:

```
profiles/browsing/
├── meta.nix           # Identity data (read by flake at eval time, NOT a NixOS module)
├── default.nix        # NixOS module: colorscheme, RAM, vCPUs, packages, extra hosts
└── packages/
    └── default.nix   # Managed by vm-sync - do not edit manually
```

**meta.nix** is a plain Nix attribute set (no `{ config, lib, ... }:` header). It is imported directly by the flake to build `vm-registry.json` without evaluating any NixOS configuration:

```nix
{
  vsockCid  = 103;
  bridge    = "br-browse";
  tapId     = "mv-browse";
  routerTap = "mv-router-brow";
  subnet    = "192.168.103";
  workspace = 3;
  label     = "BROWSING";
  focusBorder = "yellow";
}
```

**Convention: CID = subnet last octet = workspace number.** Custom profiles start at CID 107+.

**default.nix** is a standard NixOS module:

```nix
{ config, lib, pkgs, ... }: let meta = import ./meta.nix; in {
  imports = [ ./packages ];
  hydrix.networking.vmSubnet = meta.subnet;  # drives static IP derivation
  hydrix.colorscheme = "hydrix";
  environment.systemPackages = with pkgs; [ gobuster ffuf ];
}
```

### infra/ - Infrastructure VM Configs

Each infra directory has `meta.nix` and `default.nix`. The `default.nix` is a NixOS module that sets user options for that VM. The framework provides the base VM config; the user only needs to declare what differs.

**meta.nix for infra VMs** has additional fields:

```nix
{
  vsockCid   = 200;
  workspace  = 10;        # null for VMs with no workspace
  label      = "ROUTER";
  hasDisplay = false;     # headless - shard start won't wait for display
  builtinVm  = true;      # uses mkMicrovmRouter, not mkInfraVm
}
```

`builtinVm = true` means the VM is declared via a specialized framework function (`mkMicrovmRouter`, `mkMicrovmBuilder`, etc.) rather than the generic `mkInfraVm`. The user config is still imported but the framework owns the base structure.

### tasks/ - Task Slots

Task slots are generic VMs that engagements are bound to at runtime, without a host rebuild.
All slots come from one block in `tasks/default.nix`:

```nix
{
  count = 3;           # task1..task3, max 9
  baseCid = 115;       # task1 = 115, task2 = 116, task3 = 117
  profile = "pentest"; # base profile every slot builds on
  secrets = [];        # hydrix secrets delivered to every slot, e.g. ["burp"]
  module = {lib, ...}: {
    hydrix.microvm.persistence.homeSize = 20480;
    hydrix.microvm.encryption.enable = true;
  };
  overrides = {};      # per-slot additions, e.g. task2 = {...};
}
```

`tasks/slots.nix` expands it: slot N gets CID = subnet octet = `baseCid + N - 1` and its own
bridge `br-taskN`, subnet `192.168.<cid>.0/24` and router TAP `mv-router-taskN`, so the
router isolates every slot from every other VM network. Engagements are bound with
`shard pentest task1 <name>` and released with `shard pentest end <name>` (see
`shard pentest help`); bindings are kept outside the flake.

---

## new-profile Template

`templates/profiles/_template/` is the source used by the `new-profile` script when scaffolding a new profile VM. It contains `__CID__`, `__BRIDGE__`, `__WORKSPACE__`, `__LABEL__` placeholders that are substituted at scaffold time.

```bash
new-profile myvm    # auto-discovers next free CID (107+), fills all placeholders
```

After scaffolding, no manual wiring in `flake.nix` is needed - the flake auto-discovers any directory under `profiles/` that contains `meta.nix`.
