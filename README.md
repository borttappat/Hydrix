  <pre>
    __  __          __     _
   / / / /_  ______/ /____(_)  __
  / /_/ / / / / __  / ___/ / |/_/
 / __  / /_/ / /_/ / /  / />  <
/_/ /_/\__, /\__,_/_/  /_/_/|_|
      /____/  
                An attempt at a somewhat secure workstation framework
                Based on NixOS and MicroVMs 
                Heavily inspired by Qubes OS
  </pre>

Discl **AI** mer - **AI** was used in setting this project up, do not use unless you feel comfortable with that piece of information

**Everything** seen here is still under development. Once I end up with a solid prototype that has been more battle-tested and ran on different hardware, I will try to make some sort of numbered release.

UPDATE 1 - 10/07
Setup with installer should now produce a working system, after testing on a different set of laptops(all Intel-based, still needs testing with AMD hardwar[testers needed]).  


Hydrix is an options-driven NixOS framework that provides complete network isolation through VM compartmentalization. Your WiFi hardware is passed directly to a router VM via VFIO, giving you granular control over network traffic while maintaining a hardened host. Qubes will always be a better setup, and from a security and segmentation standpoint, Hydrix makes(at least as of now) sacrifices such as a shared Host -> Guest shared /nix/store. Further development is neccessary to fully find ways of approximating Qubes, but expect manually reading through all of the code of this setup and tweaking things yourself to tailor settings to your security preferences. The heavy lifting here is all done with [MicroVMs](https://github.com/microvm-nix/microvm.nix), huge shoutout to Astro. 

For full documentation see [DOCUMENTATION.md](DOCUMENTATION.md).

---

## Status & Known Issues

Things being actively worked on or not yet verified. Checked off once resolved and tested.

**Blocking / in progress**

- [ ] **Dual-boot**: single-boot installs work; dual-boot broken
- [ ] **Router VM in VM installations**: works on real laptop hardware; breaks when Hydrix is running inside a VM (for testing purposes)
- [ ] **Desktop / USB WiFi**: designed for laptops with native WiFi cards; desktops without one are untested; USB WiFi card behaviour unknown
- [ ] **AMD hardware**: currently Intel/ASUS-specific (VFIO, ASUS driver, ZenBook audio); needs AMD parity and hardware testing
- [x] **LUKS encryption for profile VMs**: verified working for pentest and comms; the `encryption = true` flag in machine config is wired generically in `flake.nix`, so it extends to any profile without code changes. `microvm purge` deletes the LUKS container (`*.luks`) but leaves `encryption = true` in machine config; `microvm start` detects the built runner expects `/dev/mapper/vm-<name>-home` and the container is missing, and fails fast with a pointer to `microvm encrypt-setup <name>`.
- [x] **Encrypted VM launch via wofi**: `mod+d` on a stopped encrypted VM now detects the LUKS volume and prompts for the passphrase via `wofi --password` (same masked-input pattern as `vault-pick.nix`), unlocking before `microvm start` runs. No terminal needed.
- [x] **Builder build progress**: `microvm builder build X` now streams live status (`Building...` / `OK building ...` / `DONE`/`ERROR`) instead of going silent; errors are visible without socat'ing into the builder. Still coarse-grained: not the full per-derivation live stream `microvm build X` shows in administrative mode.
- [ ] **Setup script** (`setup-hydrix.sh`): not fully end-to-end tested
- [ ] **Installer post-reboot, gh auth**: persistence is implemented but untested; git config is not yet declarative (requires manual `git config` after reboot)
- [x] **Infra VM ephemerality**: router/router-stable/files/gitsync/hostsync/usb-sandbox/vault now wipe state on every restart, matching the lurking-profile pattern; `microvm purge` is no longer required after WiFi credential changes. See [DOCUMENTATION.md § Infra VM Persistence Model](#infra-vm-persistence-model).
- [x] **Clipboard isolation**: handled by the `hypr-clip-guard` Hyprland plugin - hooks all Wayland clipboard protocols to enforce per-VM isolation. See [DOCUMENTATION.md § Clipboard Isolation](#clipboard-isolation-hypr-clip-guard).

**Polish / lower priority**

- [ ] **Socat terminal output**: raw-mode attach/detach (`microvm console <name>`) verified working. Removed the `screen` fallback: it was broken since `console.sock` is a UNIX socket rather than a character device, so screen tried to exec the socket path as a command instead of connecting to it. Remaining known limitation: the console renders in a small, fixed geometry, inherent to qemu's serial-over-socket transport having no window-size negotiation with the guest, not fixable via socat or screen alone.
- [x] **Phase out xpra**: xpra, i3, and sway have been fully removed from the framework. Hyprland + waypipe is the only supported desktop stack.
- [x] **Live-switch edge cases** (`microvm update`): fixed two silent-failure paths: the host-side nix-store DB registration step now surfaces errors instead of swallowing them, and `vm-switch` no longer mislabels hard failures (e.g. exit 100, incompatible init requiring reboot) as "OK, some units failed". Other edge cases may still surface; report if found.

---

## Features


- **MicroVM compartmentalization** - profile VMs (browsing, pentest, dev, comms, lurking) and infrastructure VMs (router, builder, gitsync, files, vault, usb-sandbox, hostsync)
- **WiFi VFIO passthrough** - host has no direct internet in lockdown mode; all traffic routes through the router VM
- **wifi-sync** - manage WiFi networks encrypted in `secrets/wifi.yaml` via the router VM over vsock; supports admin mode (add/pull/list/remove via router NM) and fallback mode (capture current host connection)

- **Task pentest slots** - pre-declared isolated VM slots (task1-3) assignable to named engagements without a host rebuild

- **Per-VM Mullvad VPN** - each profile VM can exit through a different Mullvad server

- **Encrypted inter-VM file transfer** - files VM with per-bridge TAP access and vsock passphrase delivery

- **Builder VM** - builds host and VM closures from inside a locked-down nix environment with internet via router VM
- **Gitsync VM** - push and pull git repos from lockdown mode without host internet
- **Hostsync VM** - secure file inbox from VMs to host
- **Vault VM** - isolated KeepassXC credential store with launcher-based picker and vsock-only access
- **USB sandbox VM** - safe handling of untrusted USB storage inside an isolated VM

- **Declarative boot modes** - lockdown (default), administrative, fallback as NixOS specialisations
- **Stable fallback router** - immutable break-glass router VM for when the main router config breaks

Some more visual/graphical features:


- **Hyprland** - the only supported compositor. VM apps forwarded as native windows via waypipe over vsock. Set `hydrix.hyprland.enable = true` in your machine config.
- **VM metrics polling** - status bar pulls live CPU, RAM, disk, uptime from each running VM via vsock
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

The script partitions the disk via disko, auto-detects hardware (CPU, WiFi PCI address, ASUS features, and the live ISO's own NixOS release as this machine's `system.stateVersion`), prompts for username and colorscheme, generates `machines/<serial>.nix` + `modules/user.nix` + `modules/common.nix`, runs `nixos-install`, and pre-builds the router and builder VMs.

**If you already have a `hydrix-config` on another machine**, provide the repo URL when prompted. The installer enters **add** mode: it clones your repo and generates only `machines/<serial>.nix` for the new hardware. User identity, locale, and VM configs are already in the repo - no re-prompting.

### Migrate existing NixOS

```bash
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/setup-hydrix.sh | bash
```

The script detects your current system (user, locale, WiFi), creates `~/hydrix-config/`, generates your machine config, and handles multi-machine setups. `system.stateVersion` is read from your existing `/etc/nixos/configuration.nix` (or prompted for manually if not found) rather than re-detected, since it must reflect this machine's original install, not its current release. Same three modes apply: **fresh** (new config), **add** (new machine to existing repo), **use-existing** (serial already present).


# Start a profile VM (display tunnel starts automatically)
```bash
microvm start browsing
```

# Build and start all profile VMs at once
```bash
mvm rebuild browsing pentest dev comms lurking
```

### Router-only (no desktop, hand-written flake)

Hydrix doesn't require the full Hyprland desktop stack. An existing NixOS machine can
import it for just boot-mode specialisations and a VFIO-isolated router VM, calling
`hydrix.lib.mkHost`/`hydrix.lib.mkMicrovmRouter` directly instead of going through
`install-hydrix.sh`/`setup-hydrix.sh`:

```nix
hydrix.hardware.vfio.enable = true;
hydrix.hardware.vfio.pciIds = [ "8086:a840" ];   # from: lspci -nn | grep -i network
hydrix.hardware.vfio.wifiPciAddress = "00:14.3"; # from: lspci -D | grep -i wireless
hydrix.router.type = "microvm";                   # default, shown for clarity
hydrix.router.persistence.enable = true;           # keep nmcli-added WiFi across restarts
hydrix.graphical.enable = false;                   # no Hyprland/waybar/wofi/dunst/Alacritty
```

Bridges (`br-mgmt` and friends) and the router's management-LAN IP both have real
built-in defaults now — no `infra/router/meta.nix`-style convention has to be
replicated by hand for the router to be reachable from the host. The router VM itself is
still declared separately in your flake via `hydrix.lib.mkMicrovmRouter { ... }` (see
`lib/default.nix`); `pciIds` and `wifiPciAddress` both need to be set (one binds the
device to `vfio-pci`, the other tells the router VM which PCI slot to take) — they're not
derived from each other.

With no profile VMs declared and `hydrix.graphical.enable = false`, the host builds with
zero graphical packages. Three profile VMs (`browsing`, `comms`, `lurking`) ship with
real default CID/bridge/subnet/workspace metadata baked into the framework
(`hydrix.microvm.defaultProfiles`) — declare one with nothing but a profile name and
hostname and it's buildable and reachable through the router with no
`profiles/<name>/meta.nix`-equivalent required:

```nix
"microvm-browsing" = hydrix.lib.mkMicroVM {
  profile = "browsing";
  hostname = "microvm-browsing";
};
```

(`dev` and `pentest` are not zero-config defaults — `pentest` especially is meant to be
individually tweaked per engagement; use `setup-hydrix`/hand-write your own profile for
either.) Each is usable from a plain terminal with no window manager at all:
`microvm app <name> <cmd>` (e.g. `microvm app microvm-browsing firefox`) launches an app
inside it and forwards its window via waypipe to *any* running Wayland compositor — it
has no Hyprland dependency. `microvm console <name>` gives a real serial-console login
with no compositor required at all.

---

## Secrets Management

WiFi credentials and SSH keys are encrypted with [sops](https://github.com/getsops/sops) using an age key derived from each machine's SSH host key - encrypted files are safe to commit, only the machine that generated the key (or a portable key, see below) can decrypt them.

```bash
# machines/<serial>.nix: hydrix.secrets.enable = true;
rebuild
hydrix-sops-setup                  # writes secrets/.sops.yaml with this machine's key
sops secrets/wifi.yaml             # create/edit an encrypted secret
```

Both installers (`install-hydrix.sh`, `setup-hydrix.sh`) drive this automatically during install, including an optional password-protected master key (`hydrix-sops-setup --gen-master-key` / `--unlock`) that lets new machines and reinstalls decrypt existing secrets immediately - no re-keying round-trip to another machine required.

See [DOCUMENTATION.md § Secrets Management](DOCUMENTATION.md#secrets-management) for declaring secret files, per-VM delivery, and the full `hydrix-sops-setup` reference.

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
| pentest | 102 | 2 | br-pentest | persistent, optionally LUKS-encrypted |
| browsing | 103 | 3 | br-browse | 10GB home |
| comms | 104 | 4 | br-comms | persistent |
| dev | 105 | 5 | br-dev | 50GB + 20GB docker |
| lurking | 106 | 6 | br-lurking | ephemeral |

Each profile is actually built as its own per-machine nixosConfiguration
(`microvm-<profile>-<serial>`, the same pattern the router already uses), but you never
need to know or type that: `microvm <cmd> <profile>` always resolves to the current
machine's real VM name via `/etc/hydrix/vm-registry.json`. Infra VMs (router, builder,
files, gitsync, hostsync, usb-sandbox, vault) are the exception - they stay a single
shared name across every machine, since they hold no persistent state to differentiate.
See [DOCUMENTATION.md § VM Naming and Machine Identity](DOCUMENTATION.md#vm-naming-and-machine-identity).

Custom profiles start at CID 107+. Scaffold one with:

```bash
new-profile myvm   # auto-assigns next free CID and workspace
rebuild            # creates bridge, updates tap wiring and vm-registry.json
mvm rebuild router files   # pick up new bridge (router + files VM)
microvm build myvm
microvm start myvm
```

---

## Building and Rebuilding VMs


Build a VM image (evaluates config, writes runner to nix store)
```bash
microvm build browsing
```

Start a VM (polls readiness, then connects display tunnel)
```bash
microvm start browsing
```

Stop a VM
```bash
microvm stop browsing
```

Restart (required for kernel, initrd, or runner changes)
```bash
microvm restart browsing
```

Live switch (applies config changes without restart - no kernel/runner changes)
```bash
microvm update browsing
```

Check running vs built state
```bash
microvm switch-status browsing
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

## Display Stack

Hyprland is the only supported compositor. Enable it in `machines/<serial>.nix`:

```nix
# machines/<serial>.nix
hydrix.hyprland.enable = true;  # Wayland, VM apps forwarded via waypipe
```

On a VM workspace, pressing `Super+Return` launches the terminal in that VM as a native
Hyprland window via waypipe.

### Hyprland

| Component | Program |
|-----------|---------|
| Compositor | Hyprland |
| Status bar | waybar |
| Launcher | wofi |
| Lockscreen | hyprlock |
| VM forwarding | waypipe (vsock) |

```bash
hyprland-launch                # start Hyprland session from TTY
hypr-ws-app alacritty        # launch app in VM on current workspace
hypr-ws-app firefox
```

Keybindings live in `modules/hyprland.nix`.

Sway, i3, and xpra have been fully removed from the framework - there is no
`hydrix.sway.enable` or `hydrix.i3.enable` option anymore.

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
  The compositor border color when a VM window is focused.
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
microvm build pentest
microvm restart pentest
```

---

See [DOCUMENTATION.md](DOCUMENTATION.md) for full configuration reference, security model, secrets management, encrypted home volumes, Mullvad VPN, task pentest VMs, vsock port reference, and troubleshooting.
