  <pre>
    __  __          __     _
   / / / /_  ______/ /____(_)  __
  / /_/ / / / / __  / ___/ / |/_/
 / __  / /_/ / /_/ / /  / />  <
/_/ /_/\__, /\__,_/_/  /_/_/|_|
      /____/  
                An attempt at a somewhat secure workstation framework
                Based on NixOS, MicroVMs and compartmentalization
  </pre>

Discl **AI** mer - **AI** was used in setting this project up, do not use unless you feel comfortable with that piece of information

**Everything** seen here is still under development. Once I end up with a solid prototype that has been more battle-tested and ran on different hardware, I will try to make some sort of numbered release.

Hydrix is an options-driven NixOS framework that provides complete network isolation through VM compartmentalization. Your WiFi hardware is passed directly to a router VM via VFIO, giving you granular control over network traffic while maintaining a hardened host. Qubes will always be a better setup, and from a security and segmentation standpoint, Hydrix makes(at least as of now) sacrifices such as a shared Host -> Guest shared /nix/store. Further development is neccessary to fully find ways of approximating Qubes, but expect manually reading through all of the code of this setup and tweaking things yourself to tailor settings to your security preferences. The heavy lifting here is all done with [MicroVMs](https://github.com/microvm-nix/microvm.nix), huge shoutout to Astro. 

For full documentation see [DOCUMENTATION.md](DOCUMENTATION.md).

---

## Features


- **MicroVM compartmentalization** - profile VMs (browsing, pentest, dev, comms, lurking) and infrastructure VMs (router, builder, gitsync, files, vault, usb-sandbox, hostsync)
- **WiFi VFIO passthrough** - host has no direct internet in lockdown mode; all traffic routes through the router VM

- **Task pentest slots** - pre-declared isolated VM slots (task1-3) assignable to named engagements without a host rebuild

- **Per-VM Mullvad VPN** - each profile VM can exit through a different Mullvad server

- **Encrypted inter-VM file transfer** - files VM with per-bridge TAP access and vsock passphrase delivery

- **Builder VM** - builds host and VM closures from inside a locked-down nix environment with internet via router VM
- **Gitsync VM** - push and pull git repos from lockdown mode without host internet
- **Hostsync VM** - secure file inbox from VMs to host
- **Vault VM** - isolated KeepassXC credential store with wofi picker and vsock-only access
- **USB sandbox VM** - safe handling of untrusted USB storage inside an isolated VM

- **Declarative boot modes** - lockdown (default), administrative, fallback as NixOS specialisations
- **Stable fallback router** - immutable break-glass router VM for when the main router config breaks

Some more visual/graphical features:


- **Sway/Hyprland (Wayland) and i3 (X11)** - Started out with i3, migrated to Wayland for Waypipe suppoert over Xpra - VM apps forwarded as native windows via waypipe or xpra over vsock. Currently mainly set up with Hyprland in mind.
- **VM metrics polling** - polybar bottom bar pulls live CPU, RAM, disk, uptime from each running VM via vsock
- **Pywal colorscheme system** - three independent color layers per VM: declarative base scheme, live host wal-cache sync via virtiofs, and per-VM focus border color on the host

---

## Boot Modes (Specialisations)

The host has three boot modes, each a NixOS specialisation:

| Mode | Internet | Host bridge presence | Use Case |
|------|----------|---------------------|----------|
| lockdown (default) | None | No L3 addresses on any bridge | Daily secure use; nix builds via builder VM |
| administrative | Via router VM | `192.168.100.1` on `br-mgmt` only | Full functionality, VM management, package installs |
| fallback | Direct WiFi, no router VM | No bridges | Emergency recovery, initial setup |


Specialisation files live in `hydrix-config/specialisations/`. Add extra packages per mode there:

```nix
# specialisations/administrative.nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ wireshark ];
}
```

---

## Getting Started

### Fresh install (NixOS live environment)

```bash
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
```

The script partitions the disk via disko, auto-detects hardware (CPU, WiFi PCI address, ASUS features), generates `machines/<serial>.nix`, runs `nixos-install`, and pre-builds the router and builder VMs.

### Migrate existing NixOS

```bash
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/setup-hydrix.sh | bash
```

The script detects your current system (user, locale, WiFi), creates `~/hydrix-config/`, generates your machine config, and handles multi-machine setups.


# Start a profile VM (waypipe or xpra tunnel starts automatically)
```bash
microvm start microvm-browsing
```

# Build and start all profile VMs at once
```bash
mvm rebuild browsing pentest dev comms lurking
```

---

## VM Profiles

Profile VMs each have a directory in `hydrix-config/profiles/` with three files:

```
profiles/browsing/
├── meta.nix       # CID, bridge, subnet, workspace, label, focusBorder
├── default.nix    # NixOS config: colorscheme, RAM, vCPUs, extra packages, hosts
└── packages/
    └── default.nix   # managed by vm-sync, do not edit manually
```

Built-in profiles and their defaults:

| VM | CID | WS | Bridge | Persistence |
|----|-----|----|--------|-------------|
| microvm-pentest | 102 | 2 | br-pentest | persistent, optionally LUKS-encrypted |
| microvm-browsing | 103 | 3 | br-browse | 10GB home |
| microvm-comms | 104 | 4 | br-comms | persistent |
| microvm-dev | 105 | 5 | br-dev | 50GB + 20GB docker |
| microvm-lurking | 106 | 6 | br-lurking | ephemeral |

Custom profiles start at CID 107+. Scaffold one with:

```bash
new-profile myvm   # auto-assigns next free CID and workspace
rebuild            # creates bridge, updates tap wiring and vm-registry.json
mvm rebuild router files   # pick up new bridge (router + files VM)
microvm build microvm-myvm
microvm start microvm-myvm
```

---

## Building and Rebuilding VMs


Build a VM image (evaluates config, writes runner to nix store)
```bash
microvm build microvm-browsing
```

Start a VM (polls readiness, then connects waypipe/xpra tunnel)
```bash
microvm start microvm-browsing
```

Stop a VM
```bash
microvm stop microvm-browsing
```

Restart (required for kernel, initrd, or runner changes)
```bash
microvm restart microvm-browsing
```

Live switch (applies config changes without restart - no kernel/runner changes)
```bash
microvm update microvm-browsing
```

Check running vs built state
```bash
microvm switch-status microvm-browsing
```

Operate on multiple VMs at once
```bash
mvm rebuild browsing pentest dev
mvm stop files pentest browsing router builder gitsync
mvm build files pentest browsing
```

In lockdown mode (no host internet), use the builder VM to fetch and build:

```bash
microvm builder build browsing    # fetches deps via router VM, writes to host store
microvm builder switch            # build + switch host config
```

---

## Display Stack: Hyprland(actively maintaine), Sway and i3(both somewhat deprecated)


```nix
# machines/<serial>.nix
hydrix.sway.enable = true;      # Wayland - VM apps forwarded via waypipe
hydrix.hyprland.enable = true;  # Wayland - VM apps forwared via waypipe
hydrix.i3.enable   = true;      # X11     - VM apps forwarded via xpra
```

Under Hyprland/Sway, pressing `Super+Return` on a VM workspace launches the terminal in that VM via waypipe. The window appears as a native Sway window. Under i3 the same key uses xpra.

```bash
sway-session       # start Sway 
hyprland-session   # start Hyprland  
sway-ws-app alacritty          # launch app in the VM on current workspace, naming convention due to Sway being approached first
sway-ws-app firefox
```

User keybindings live in `modules/hyprland.nix`, `modules/sway.nix` and `modules/i3.nix` in your `hydrix-config`.

---

## Colorscheme System

Three independent color layers per VM:

```
Layer 1 - VM internal colorscheme
  hydrix.colorscheme = "hydrix"
  Drives pywal inside the VM: alacritty, dunst, GTK

Layer 2 - Host wal cache via virtiofs
  Host ~/.cache/wal shared read-only into VMs at boot.
  Running walrgb/randomwalrgb on the host sends a REFRESH
  signal to all running VMs, updating their terminals and
  pywalfox in real time.

Layer 3 - Focus border (host-side)
  focusBorder = "yellow"   # in profiles/<name>/meta.nix
  The Hyprland/Sway window border color when a VM window is focused.
  Fully independent from the VM's internal colors. Lives in meta.nix
  (plain attrset) so the host flake can read it without evaluating
  any VM NixOS configuration - avoids OOM on memory-constrained hosts.
```

```bash
walrgb /path/to/image.jpg    # generate + apply colors, syncs to all running VMs
randomwalrgb                 # random wallpaper from configured directory
```

Declarative colorschemes in `profiles/<name>/default.nix`:

```nix
hydrix.colorscheme = "nord";   # nord, hydrix, ... add more with `save-colorscheme xyz` 
```

User-defined colorschemes in `hydrix-config/colorschemes/` (pywal JSON format) take priority over framework ones with the same name.

---

## Adding Packages

### modules system packages (all machines and VMs)

Add to `modules/common.nix`:

```nix
environment.systemPackages = with pkgs; [ ripgrep fd ];
```

### Host-only packages

Add to `machines/<serial>.nix` or `specialisations/administrative.nix` for mode-specific installs:

```nix
environment.systemPackages = with pkgs; [ wireshark ];
```

### Packages for a specific VM profile

Add to `profiles/<name>/default.nix`:

```nix
environment.systemPackages = with pkgs; [ gobuster ffuf ];
```

Or use the vm-dev workflow to build and test a package inside the VM first, then pull it to the profile:

```bash
# Inside the VM
vm-dev build https://github.com/owner/repo
vm-dev run repo
vm-sync push --name repo

# On the host
vm-sync pull repo --target pentest
microvm build microvm-pentest
microvm restart microvm-pentest
```

---

See [DOCUMENTATION.md](DOCUMENTATION.md) for full configuration reference, security model, secrets management, Mullvad VPN, task pentest VMs, vsock port reference, and troubleshooting.
