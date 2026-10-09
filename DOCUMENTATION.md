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


Hydrix is an options-driven NixOS framework that provides complete network isolation through VM compartmentalization. Your WiFi hardware is passed directly to a router VM via VFIO, giving you granular control over network traffic while maintaining a hardened host.

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture Overview](#architecture-overview)
- [Security Model](#security-model)
- [Installation](#installation)
  - [Installer Modes](#installer-modes)
  - [Fresh Install](#fresh-install-from-live-environment)
  - [Migration from Existing NixOS](#migration-from-existing-nixos)
  - [Adding a Machine to an Existing Config](#adding-a-machine-to-an-existing-config)
- [Configuration](#configuration)
- [Colorscheme System](#colorscheme-system)
- [VM Theme Sync](#vm-theme-sync)
- [Stylix (Opt-in Theming)](#stylix-opt-in-theming)
- [Notifications](#notifications)
- [Font System](#font-system)
- [MicroVM Management](#microvm-management)
  - [Task Slots](#task-slots-per-engagement-vms)
  - [Files VM (Encrypted Inter-VM Transfer)](#files-vm-encrypted-inter-vm-transfer)
  - [Hostsync VM (Host File Inbox)](#hostsync-vm-host-file-inbox)
  - [USB Sandbox](#usb-sandbox-microvm-usb-sandbox)
  - [Passwords (vault VM)](#passwords-hydrixpasswords-vault-vm)
  - [Builder VM](#builder-vm-lockdown-mode-builds)
- [Vsock Communication](#vsock-communication)
- [VM Store Sharing](#vm-store-sharing)
- [Build System](#build-system)
- [Shell](#shell)
- [Workspace Integration](#workspace-integration)
- [Lockscreen](#lockscreen)
- [Keybindings](#keybindings)
- [Scripts Reference](#scripts-reference)
- [Quality of Life](#quality-of-life)
  - [Monitor Layout](#monitor-layout)
- [Troubleshooting](#troubleshooting)
- [Pentesting VM](#pentesting-vm)

---

## Quick Start

Fresh install from NixOS live environment
```bash
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
```

After installation, your configuration lives at `~/hydrix-config/`.

---

## Architecture Overview

### Network Stack

```
+---------------------------------------------------------------------+
|                         HOST (Lockdown Mode)                        |
|   - No direct internet access                                       |
|   - WiFi hardware passed to router VM via VFIO                      |
|   - No L3 presence on any bridge (no IPv4 or IPv6 addresses)        |
|   - Bridges exist as L2 plumbing only; host is invisible to VMs     |
|   - Bridges: br-mgmt, br-pentest, br-browse, br-comms, br-dev,      |
|              br-lurking, br-builder, br-files, plus one per         |
|              custom profile, infra VM with routerTap, or task slot  |
+---------------------------------------------------------------------+
                            |
     Router VM NICs (one QEMU TAP per bridge, router is .253 on each)
                            |
         +---- br-mgmt     (192.168.100.0/24) ---+
         |         ^ mv-router-mgmt              |
         +---- br-pentest  (192.168.102.0/24) ---+
         |         ^ mv-router-pent              |
         +---- br-browse   (192.168.103.0/24) ---+
         |         ^ mv-router-brow              |--- Router VM (WiFi)
         +---- br-comms    (192.168.104.0/24) ---+
         |         ^ mv-router-comm              |    CID: 200
         +---- br-dev      (192.168.105.0/24) ---+
         |         ^ mv-router-dev               |
         +---- br-lurking  (192.168.106.0/24) ---+
         |         ^ mv-router-lurk              |
         +---- br-files    (192.168.108.0/24) ---+
         |         ^ mv-router-file              |
         +---- br-builder  (192.168.210.0/24) ---+
                   ^ mv-router-bldr              |
                         |                       |
              +----------+----------+------------+-----------+
              |          |          |            |           |
         +--------+  +--------+  +--------+  +--------+  +--------+
         |Pentest |  |Browsing|  |  Comms |  |  Dev   |  |Lurking |
         |   VM   |  |   VM   |  |   VM   |  |   VM   |  |   VM   |
         |CID:102 |  |CID:103 |  |CID:104 |  |CID:105 |  |CID:106 |
         +--------+  +--------+  +--------+  +--------+  +--------+

         +--------+  +--------+  +--------+
         |Builder |  |Gitsync |  | Files  |
         |   VM   |  |   VM   |  |   VM   |
         |CID:210 |  |CID:211 |  |CID:212 |
         +--------+  +--------+  +--------+
```

Subnets shown are the template defaults from each `meta.nix`; gitsync shares `br-builder`.

### Router VM TAP Interfaces

The router VM has **one NIC per bridge**, acting as the DHCP/DNS gateway (`.253`) for each subnet. With the template defaults:

| Router TAP | Bridge | Router IP | Subnet | Purpose |
|------------|--------|-----------|--------|---------|
| `mv-router-mgmt` | `br-mgmt` | 192.168.100.253 | 192.168.100.0/24 | Host management |
| `mv-router-pent` | `br-pentest` | 192.168.102.253 | 192.168.102.0/24 | Pentest VM |
| `mv-router-brow` | `br-browse` | 192.168.103.253 | 192.168.103.0/24 | Browsing VM |
| `mv-router-comm` | `br-comms` | 192.168.104.253 | 192.168.104.0/24 | Comms VM |
| `mv-router-dev` | `br-dev` | 192.168.105.253 | 192.168.105.0/24 | Dev VM |
| `mv-router-lurk` | `br-lurking` | 192.168.106.253 | 192.168.106.0/24 | Lurking VM |
| `mv-router-file` | `br-files` | 192.168.108.253 | 192.168.108.0/24 | Files VM |
| `mv-router-bldr` | `br-builder` | 192.168.210.253 | 192.168.210.0/24 | Builder and gitsync VMs |

Custom profiles, infra VMs with a `routerTap`, and task slots each add a row the same way.

#### Router NIC table (`vm/microvm/infra/router-nics.nix`)

Every router NIC is described three times in different layers, and the three must agree:

1. **QEMU (host)** creates the NIC: a host-side TAP (`mv-router-file`) plus a MAC address.
2. **The QEMU tap script (host)** attaches that TAP to its bridge (`br-files`).
3. **systemd `.link` files (guest)** rename the NIC. Inside the VM the kernel only sees a generic name like `ens5`; the MAC is the one thing both sides share, so each `.link` file says "the NIC with MAC X is `mv-router-file`". networkd, dnsmasq, nftables and the VPN scripts then match on that name.

Each router module builds **one list** of NIC records, `{ tap, subnet, bridge, mac }`, and generates all three layers from it with helpers in `router-nics.nix`, so they cannot drift apart:

| Helper | Produces |
|--------|----------|
| `mkNic role { tap, subnet, bridge }` | One record; derives the MAC from the subnet |
| `qemuArgs script nics` | `-netdev tap,...` and `-device virtio-net-pci,mac=...` per NIC |
| `bridgeCases nics` | `<tap>) BRIDGE="<bridge>" ;;` arms for the tap script (`bridge = null` leaves the TAP to the udev catch-all) |
| `links nics` | One `.link` file per NIC, MAC -> TAP name |
| `assertions nics` | Eval-time checks: unique MACs, unique TAP names, TAP names <= 15 chars, well-formed subnets |
| `checkService pkgs nics` | `router-nic-check` unit: at boot, fails if a declared NIC is missing or a virtio NIC kept a kernel name |

**MAC plan** (`02:00:00:<role>:<id>:<n>`, locally administered):

| Role byte | Used by | `<id>` |
|-----------|---------|--------|
| `00`, `02` | VM NICs (profile VMs hash-based, infra VMs from `meta.nix` `tapMac`) | per VM |
| `06` | Main router LAN NICs (WAN NIC, when ethernet: `02:00:00:06:ff:02`) | third octet of the LAN's subnet, in hex |
| `07` | Router-stable LAN NICs | third octet of the LAN's subnet, in hex |

For example `br-files` (`192.168.108`) gets router NIC `02:00:00:06:6c:01`. Because the router owns `.253` on every LAN, subnets are unique per LAN and so are router MACs; adding or removing a network never changes another NIC's MAC, and the router role bytes never collide with a VM on the same bridge. Two LANs declared with the same subnet fail the build with `Router NICs share MAC(s) ...`.

**Unknown NICs fail closed.** NetworkManager in the router manages only the WiFi device (and the ethernet WAN, when used) and never auto-creates wired DHCP profiles. A NIC that somehow misses its rename stays down instead of running a DHCP client on whatever bridge it is plugged into, and `router-nic-check` reports it:

```bash
# inside the router (shard -c router)
systemctl status router-nic-check
journalctl -u router-nic-check
```

TAPs are created by QEMU itself (TUNSETIFF), then bridged by the tap script QEMU runs once it holds the fd; the udev rule described below is a catch-all for any TAP the script does not name.

**LAN IPs are assigned at VM boot via `systemd.network.networks`**, not after WiFi connects. `ConfigureWithoutCarrier = "yes"` means every LAN interface gets its static IP immediately when the VM starts, before any WiFi interaction. `dnsmasq` then provides DHCP and DNS to all subnets simultaneously.

**WAN (WiFi) is independent of LAN setup.** NetworkManager connects to WiFi in the background. In **administrative mode** (where the host routes through the router VM), internet access on the host is available the moment NM establishes the WiFi connection, there is no sequential dependency on LAN configuration. In lockdown mode the host has no default gateway regardless; VMs always get internet through the router as soon as WiFi connects.

**Custom profiles** with `routerTap` defined automatically get new TAP interfaces and `systemd.network.networks` entries added (e.g., `mv-router-<name>` -> `br-<name>`). No manual wiring needed after a host rebuild.

### TAP-to-Bridge Assignment

All `mv-*` TAP interfaces are assigned to their correct bridge by two complementary mechanisms, both defined in `modules/base/microvm-host.nix`:

**1. udev catch-all rule (primary)**

A single udev rule fires whenever any `mv-*` interface is created:

```
ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-*", RUN+="tap-assign %k"
```

`tap-assign` calls a generated `tap-bridge-lookup` script that contains every known TAP→bridge mapping as a shell `case` statement. The lookup is built at Nix evaluation time from:
- Static router TAPs (`mv-router-*`, `mv-rts-*`)
- `infraTapBridges` from each infra VM's `meta.nix` (e.g. the files VM's per-bridge TAPs)
- `extraNetworks` from auto-discovered profile `meta.nix` files

This means a new profile added via `new-profile` is automatically included after a host rebuild, no manual rule editing required.

**2. `microvm-tap-bridges` repair service (safety net)**

Runs on every `nixos-rebuild switch` (`restartIfChanged = true`) and whenever bridges are recreated (`partOf = network.target`). Iterates all currently-existing `mv-*` interfaces and calls `tap-assign` on each. Corrects any TAP that was created before the current rules took effect (e.g. VMs that were running during a rebuild).

**Debugging wrong bridge assignments:**

```bash
# Check what bridge a TAP is on
bridge link show | grep mv-

# Manually trigger the repair service
sudo systemctl restart microvm-tap-bridges

# Inspect the generated lookup script (path shown in udev rules)
cat /etc/udev/rules.d/99-local.rules | grep mv-\*
# Then: cat /nix/store/...-tap-assign  and  cat /nix/store/...-tap-bridge-lookup
```

### Stable Fallback Router (`microvm-router-stable`)

A second router VM is always declared alongside the main router. It is a manual "break glass" router that never auto-starts. Use it when a rebuild breaks the main router and you need network access restored quickly.

**Design goals:** the stable router is intentionally never casually modified. Rebuild it explicitly when you want to promote a known-good config as the new baseline. The main router is where you tune and experiment.

| Property | Main router | Stable router |
|----------|-------------|---------------|
| Name | `microvm-router` | `microvm-router-stable` |
| CID | 200 | 201 |
| TAP prefix | `mv-router-*` | `mv-rts-*` |
| NIC MACs | `02:00:00:06:<subnet octet>:01` | `02:00:00:07:<subnet octet>:01` |
| Autostart | configurable | `false` (manual only) |
| VPN support | yes | no (intentionally minimal) |
| LAN IP assignment | systemd-networkd at boot (build-time) | systemd-networkd at boot (build-time) |
| WAN detection | runtime bash (`router-network-setup`) | none needed (LAN negation) |
| VPN routing | runtime bash (`vpn-boot-assign`) | not supported |
| dnsmasq config | runtime generated from build-time names | fully declarative (build-time) |

**How it works:**

```
Main router broken (bad config, crash, etc.)
  -> manually start stable: shard start router-stable
  -> Conflicts= stops the main router if still running (VFIO can't be shared)

Done with stable, back to main router:
  -> shard stop router-stable
  -> shard start router
```

**TAP naming:** the stable router uses a separate `mv-rts-*` TAP prefix so both VMs can coexist in config without conflicting. Both sets of TAPs attach to the **same bridges** the bridges are shared infrastructure, only the router connected to them changes during failover.

**Declarative networking:** because `systemd.network.links` renames interfaces by MAC at boot, all interface names are known at build time. The stable router uses declarative `systemd.network.networks` (static IPs), `services.dnsmasq.settings` (DHCP/DNS), and `networking.nftables.tables` (firewall), no runtime bash config generation.

**WAN identification without runtime detection:** the firewall identifies the WAN interface by negating all known LAN interfaces:
```nft
oifname != { "lo", "mv-rts-mgmt", "mv-rts-pent", ... } masquerade
```
Any interface not in the LAN set (i.e., the WiFi or VPN interface) is masqueraded.

**Manual control:**
```bash
shard build router-stable      # build the golden image
shard start router-stable      # start manually (stops main router via Conflicts=)
shard stop router-stable       # stop (main router can then be started)
shard console router-stable    # serial console access
```

Short names accepted: `router-stable`, `stable-router`, `stable`.

> **CIDs and subnets are user-configurable.** Built-in profiles (browsing, pentest, dev, comms, lurking) ship with default CIDs/subnets but these are declared in each profile's `meta.nix` in your `hydrix-config/profiles/<name>/meta.nix`. The host module writes all profile metadata to `/etc/hydrix/vm-registry.json` at activation, all scripts, the status bar, and the WM read from there at runtime, never from hardcoded maps. Adding a new VM type requires only `profiles/<name>/meta.nix` + `profiles/<name>/default.nix` in your config.

### VM Registry (`/etc/hydrix/vm-registry.json`)

Generated at NixOS activation from all profile `meta.nix` files. Every runtime tool reads from here, no hardcoded CID or workspace maps anywhere in scripts or modules.

```json
{
  "pentest":  { "vmName": "microvm-pentest-mb-ux5406sa",  "cid": 102, "bridge": "br-pentest",  "subnet": "192.168.102", "workspace": 2, "label": "PENTEST",  "focusBorder": "orange" },
  "browsing": { "vmName": "microvm-browsing-mb-ux5406sa", "cid": 103, "bridge": "br-browse",   "subnet": "192.168.103", "workspace": 3, "label": "BROWSING", "focusBorder": "yellow" },
  "comms":    { "vmName": "microvm-comms-mb-ux5406sa",    "cid": 104, "bridge": "br-comms",    "subnet": "192.168.104", "workspace": 4, "label": "COMMS",    "focusBorder": "green"  },
  "office":   { "vmName": "microvm-office-mb-ux5406sa",   "cid": 107, "bridge": "br-office",   "subnet": "192.168.107", "workspace": 7, "label": "OFFICE",   "focusBorder": null     }
}
```

The registry **key** (`"pentest"`, `"browsing"`, ...) is the stable, short profile name -
always the same regardless of machine. The `vmName` field is that machine's real, current
`nixosConfiguration` name (`microvm-<profile>-<serial>`, one per machine - see
[§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)); it's what every tool
resolves at runtime, and it's the only field here that varies by machine.

**Convention: `vsockCid` = subnet last octet = workspace number.** All three use the same number. Custom profiles start at CID 107+. Reserved: 200 (router), 201 (router-stable), 209 (usb-sandbox), 210 (builder), 211 (gitsync), 212 (files), 213 (vault), 214 (hostsync).

Task slot entries (keyed `<profile>-task<N>`, e.g. `"pentest-task1"`) also carry a
`taskSlot` field (`"task1"`); it is `null` for every other VM. `shard` finds task slots by
this field, not by name pattern.

Each entry drives: compositor border rules, workspace-desc label, `hypr-ws-app`/`vm-select` workspace -> VM routing, focus menu, `vm-sync` profile targeting, and file transfer IP resolution.

Profile entries also carry `memCeilingMb`/`vcpuCeiling`/`memLowFloorMb`/`memFloorMb`/
`cpuLowFloorPct`/`cpuFloorPct` (null for VMs without these fields in their `meta.nix`) -
see [§ Elastic CPU/RAM](#elastic-cpuram-hydrixvmelastic). `new-profile` reads these back
out of the live registry to suggest ceiling/floor values consistent with the rest of the
fleet when scaffolding a new profile.

### VM Naming and Machine Identity

Every profile VM (browsing, pentest, dev, comms, lurking, and any custom profile) and every
task VM (task1-3) is its own **per-machine** `nixosConfiguration` - `microvm-<profile>-<serial>`
(e.g. `microvm-browsing-mb-ux5406sa`), the same pattern the router VM has always used
(`microvm-router-<serial>`). A machine with two profiles and the router therefore has three
independent nixosConfigurations under the hood, not one shared across every machine declared
in your flake.

**You never need to know or type `<serial>`.** The `shard` CLI (and `shard builder`)
resolve short names - `browsing`, `pentest`, `task1`, ... - dynamically against
`/etc/hydrix/vm-registry.json`'s `vmName` field for *this* machine, every time. `shard start
browsing` on one machine and the same command on a different machine each correctly resolve
to that machine's own VM - the short form is not a shortcut for a fixed name, it's the actual
stable interface. Typing the raw `nixosConfigurations` attribute directly (`.#nixosConfigurations
.microvm-browsing...`) still works if you need it (e.g. scripting, `nix build`), but requires
knowing the current machine's serial, which the short form exists specifically to avoid.

Resolution works by checking whether the target name is a key present in
`vm-registry.json`, not by matching against a fixed list of built-in profile names.
A custom profile scaffolded with `new-profile` resolves exactly the same way as
`browsing` or `pentest`, with no changes needed anywhere in the `shard` CLI.

**Why per-machine at all:** each profile VM's `system.stateVersion` (see
[§ System State Version](#system-state-version)) and any machine-specific
`hydrix.microvmHost.profileOverrides`/`vms.<name>.encryption` setting must apply to *that
machine's* build only - a second machine with a different `stateVersion` or a different
webcam passthrough VID/PID must not affect the first machine's VMs. Making each profile VM a
real per-machine `nixosConfiguration` is what makes that isolation actual rather than
accidental (with a single shared name across machines, one machine's overrides would leak
into every other machine's build of the same profile).

**Infra VMs are the exception, deliberately.** Router/router-stable are per-machine for a
different, older reason (VFIO WiFi PCI address is inherently per-machine hardware). Builder,
files, gitsync, hostsync, usb-sandbox, and vault stay a single name shared across every
machine - they hold no persistent state (see
[§ Infra VM Persistence Model](#infra-vm-persistence-model)), so there is nothing
machine-specific to isolate.

### VM Static IP Scheme

Profile VMs use a static `<subnet>.<CID>` IP on their bridge (e.g. `192.168.102.102`). Using the CID rather than a fixed last octet keeps VMs that share a subnet (pentest and its task slots) on distinct addresses. The IP is **automatically derived** from `hydrix.networking.vmSubnet`, which every profile sets from its own `meta.nix`:

```nix
# In profiles/<name>/default.nix, this one line drives everything
hydrix.networking.vmSubnet = meta.subnet;  # e.g. "192.168.102"
# -> staticIp auto-set to "192.168.102.102" by microvm-profile-base.nix
```

`microvm-profile-base.nix` sets `hydrix.microvm.staticIp = lib.mkDefault "${vmSubnet}.${vsockCid}"` whenever `vmSubnet` is non-empty. No explicit `staticIp` declaration is needed in profile modules - the template includes the `vmSubnet` line and that is sufficient.

The table below shows the Hydrix built-in profile **defaults**, your `meta.nix` values take precedence automatically:

| VM | Default Bridge | Default Static IP |
|----|---------------|------------------|
| `pentest` | `br-pentest` | `<subnet>.<CID>` |
| `browsing` | `br-browse` | `<subnet>.<CID>` |
| `comms` | `br-comms` | `<subnet>.<CID>` |
| `dev` | `br-dev` | `<subnet>.<CID>` |
| `lurking` | `br-lurking` | `<subnet>.<CID>` |

Each VM configures this IP on its main TAP interface via systemd-networkd, with the router (`<subnet>.253`) as gateway and DNS server. `pentest-lan forward` targets this address.

### Files VM Cross-Bridge Wiring

The Files VM (`microvm-files`, CID 212) has **multiple TAP interfaces**, one per profile bridge, task slot and file-capable infra VM, for direct L2 access during encrypted file transfers:

```
Files VM (192.168.108.10 on br-files)
├── mv-files      (-> br-files, home)
├── mv-files-pent (-> br-pentest)
├── mv-files-brow (-> br-browse)
├── mv-files-comm (-> br-comms)
├── mv-files-dev  (-> br-dev)
├── mv-files-task1..N (-> br-taskN)
├── mv-files-usb  (-> br-usb-sandbox)
└── mv-files-hsy  (-> br-hostsync)
```

`br-files` also carries the router's own NIC for this subnet (`mv-router-file`, `192.168.108.253`); that TAP belongs to the router VM, not the Files VM.

**Opting a profile out.** Every discovered profile gets a TAP unless its `meta.nix` says otherwise:

```nix
# profiles/<name>/meta.nix
filesAccess = false;   # no files VM interface on this bridge, no transfers in or out
```

Both sides read the same flag: `infra/files/meta.nix` (host-side TAP to bridge wiring) and `infra/files/default.nix` (the VM's own interfaces). The lurking template sets it. Use it for any VM that should only be reachable through the router, then `rebuild` and `shard -bR files`.

Per-bridge IPs: the Files VM gets `.2` on each bridge (e.g. `192.168.103.2` on `br-browse`). It communicates directly over these TAPs, bypassing router forwarding rules, and does not forward between them (`ip_forward = 0`, forward chain drops everything), so it is not a path between VM networks. While it runs, though, it can reach every VM whose bridge it sits on.

---

### Boot Modes (Specialisations)

| Mode | Purpose | Internet | Bridges | WiFi | VMs |
|------|---------|----------|---------|------|-----|
| **Lockdown** (default) | Hardened, isolated host | No (via builder VM) | Active | Passthrough to router | Enabled |
| **Administrative** | Full functionality | Via router VM | Active | Passthrough to router | Enabled |
| **Fallback** | Emergency direct WiFi | Direct | Removed | Host access | Disabled |

**Lockdown** (base config):
- Host has **no default gateway** - no internet access
- WiFi card passed to router VM via VFIO
- All bridges active, router VM running
- Builder VM available for nix builds (fetches via router, writes to host store)
- Gitsync VM for git operations

**Administrative** specialisation:
- Adds default gateway through router VM (`192.168.100.253` on `br-mgmt`)
- Host DNS through router (`dnsmasq` forwards to 1.1.1.1, 8.8.8.8)
- Full package availability, libvirtd for libvirt pentest VMs
- All VM isolation properties unchanged

**Fallback** specialisation (**requires reboot**):
- Releases WiFi card from VFIO (`kernelParams` restored)
- Re-enables NetworkManager for direct WiFi connection
- Removes all bridges and routing
- Disables router VM and all microVMs
- Use for emergency debugging or when VM isolation not needed

Switch modes live (lockdown <-> administrative, no reboot):

```bash
hydrix-switch administrative    # Add gateway via router VM
hydrix-switch lockdown          # Remove gateway, isolate host
hydrix-mode                     # Show current mode
rebuild fallback                # Requires reboot (kernel params change)
```

**Builder VM workflow** (lockdown mode):
1. Host nix-daemon stops (builder needs R/W store)
2. Builder VM starts with virtiofs `/nix/store` access
3. Builder fetches via router VM (has internet)
4. Build outputs written directly to host's store
5. Builder stops, host nix-daemon restarts
6. Host builds instant (all deps cached in store)

```bash
shard builder build browsing   # Fetch/build in builder VM
shard builder build host       # Build host config
shard builder status           # Check builder state
```

### Builder VM (Lockdown Mode Builds)

The Builder VM enables nix package builds in lockdown mode when the host has no internet access. It fetches dependencies through the router VM and writes build outputs directly to the host's `/nix/store`.

**Architecture:**

```
Host (Lockdown Mode)                     Builder VM                     Router VM

 /nix/store (R/O)       <-virtiofs->     /nix/store       --vsock-->    WiFi (WAN)  
 nix-daemon: STOPPED     (mounted)      (host store, R/W) internet               

                                                                            
                            nix build outputs 
```

**Setup** in your `machines/<serial>.nix`:

```nix
hydrix.builder.enable = true;      # Enables Builder VM support
```

The Builder VM (`microvm-builder`, CID 210) is automatically declared by the framework - no manual VM declaration needed.

**Commands:**

```bash
# Full workflow (build target, then switch to host)
shard builder build browsing      # Build microVM in builder
shard builder build host          # Build host config

# Build AND apply host config (preserves current specialisation)
shard builder switch
shard builder switch administrative  # Switch to specific specialisation

# Prefetch only (keep builder running for batch operations)
shard builder fetch browsing
shard builder fetch pentest
shard builder fetch host
shard builder stop               # Stop when done

# Manual control
shard builder start       # Start builder (stops host nix-daemon)
shard builder shell       # Attach to builder console
shard builder status      # Check builder state
shard builder stop        # Stop builder (restarts host nix-daemon)
```

**Named targets:**

| Target | Resolves To | Purpose |
|--------|-------------|---------|
| `browsing` | `microvm-browsing-<serial>` (this machine, resolved from vm-registry.json) | Browsing VM |
| `pentest` | `microvm-pentest-<serial>` | Pentest VM |
| `dev` | `microvm-dev-<serial>` | Dev VM |
| `comms` | `microvm-comms-<serial>` | Comms VM |
| `lurking` | `microvm-lurking-<serial>` | Lurking VM |
| `task1` / `task2` / `task3` | `microvm-pentest-task<N>-<serial>` | Task pentest slots |
| `router` | `microvm-router-<serial>` | Router VM |
| `builder` | `microvm-builder` | Builder VM itself (shared, not per-machine) |
| `host` | Host system | Host NixOS configuration |
| `.#path` | Raw flake path | e.g., `.#nixosConfigurations.microvm-dev-<serial>` |

`<serial>` is your current machine's hardware serial - you never type it yourself, these
targets resolve it automatically. See
[§ VM Naming and Machine Identity](#vm-naming-and-machine-identity).

**How it works:**

1. **Start**: Host nix-daemon stops, `/nix/store` remounted R/W
2. **Build**: Builder evaluates flake from `/mnt/hydrix` (your config)
3. **Fetch**: Dependencies fetched via router VM (has internet)
4. **Build**: Compilation happens in Builder with virtiofs store access, every build in Nix's
   sandbox (see below)
5. **Stop**: Outputs written to host's `/nix/store`, Builder stops
6. **Switch**: Host nix-daemon restarts, host builds instant (all deps cached)

**Sandboxed builds.** The builder holds the host's `/nix/store` and `/nix/var/nix`
read-write, so root inside it would reach the host. Every build therefore runs in Nix's
sandbox (`sandbox = true`, `sandbox-fallback = false`): only its declared inputs, no network
except fixed-output fetches, no view of `/mnt/hydrix` or of other builds. Only root is a
trusted Nix user, so nothing can request `--option sandbox false`. The host builds with the
same settings, so anything that builds on the host builds in the builder.

**Builder shell access:**

```bash
shard builder shell

# Inside builder shell:
nix flake metadata                        # Check flake inputs
nix build .#microvm-browsing-<serial>     # Manual build (use your machine's serial)
exit                                       # Return to host
```

**Builder status:**

```bash
shard builder status

# Output:
# Builder state: running
# Process ID: 12345
# Target: browsing
# Progress: fetching...
```

**Recovery if builder crashes:**

```bash
# Manual recovery if builder is stuck
shard stop microvm-builder  # This also restores host nix-daemon

# If store is still rw after builder crash
sudo mount -o remount,ro,bind /nix/store
sudo systemctl start nix-daemon
```

---

### Infra VM Persistence Model

Infra VMs (router, router-stable, builder, files, gitsync, hostsync, usb-sandbox, vault) are
**ephemeral by default** - same pattern as the `lurking` profile VM. Nothing is special about
how this works: no volume is declared for a given path, so it lives on microvm.nix's default
tmpfs root and is wiped on every restart. Data that legitimately needs to survive is either an
explicit, documented exception, or lives on the host (delivered via a virtiofs share) rather
than inside the VM at all.

| VM | Persistent state | Why |
|---|---|---|
| router / router-stable | None - `/var/lib` is fully ephemeral | NetworkManager connections, dnsmasq leases, and VPN pin state all reset to declared config on every restart. This also means `shard purge` is no longer required after WiFi credential changes - a plain restart now gives the same clean state. |
| builder | `/root/.cache/nix` (8GB, eval cache) | The only intentional exception. The builder doesn't keep its own nix store at all - it mounts the host's real `/nix/store` R/W via virtiofs and writes straight into it, so nothing built here is ever at risk of being lost. This one volume is pure performance (avoids 2+ min cold eval per builder start) with zero security/secrets sensitivity. |
| files | `/storage` (opt-in, off by default) | `hydrix.files.persistence.enable` (default `false`). In-flight transfer payloads are ephemeral by design - FETCH/DELIVER/STORE are meant to be re-triggered on demand, not treated as durable storage. Set the option to `true` if you want transfers to survive a files-VM restart. |
| gitsync | None by default | SSH keys re-derive fresh from host secrets every boot (no need to persist) - push/pull works with no persistent state at all. `hydrix.gitsync.gh.enable` (default `false`) opts into the `gh` CLI plus a small `/var/lib/gitsync/gh-config` volume for its OAuth token, for users who'd rather authenticate with gh than manage an SSH deploy key. |
| hostsync, usb-sandbox, vault | None | Inbox data (hostsync) and the KeepassXC database (vault) already live on the host via virtiofs, not inside the VM - the VM itself holds nothing that needs to survive a restart. |

The shared base (`vm/microvm/infra/microvm-infra-base.nix`) declares no volumes at all - each
infra VM's own module is responsible for declaring only the specific, intentional exceptions
listed above.

---

### VM Types

**MicroVM** (Recommended):
- Uses QEMU with virtiofs for shared /nix/store
- Display via waypipe over vsock

**Libvirt** (Alternative):
- Traditional qcow2 images
- Good for encrypted VMs and known, traditional workflows

---

## Security Model

### Router VM Trust Boundary

The router VM is **untrusted infrastructure** it handles WiFi and NAT but has no privileged access to anything on the host or in other VMs. Its security properties:

| Property | Detail |
|----------|--------|
| SSH | Disabled (`services.openssh.enable = false`) |
| Console access | vsock (CID 200) + unix socket, host-only, not reachable from any VM or LAN |
| Default firewall policy | `input: DROP`, `forward: DROP` |
| What VMs can reach on the router | DNS (53), DHCP (67), ICMP (rate-limited)  |
| WAN side (WiFi/ethernet) | No new inbound connections; only DHCP replies for the router's own lease and replies to connections the router made |
| Source addresses | Each LAN interface only accepts its own subnet as source (anti-spoofing); isolation and VPN routing both rely on it |
| Firewall load order | `router-firewall` runs before `network-pre.target`, so no interface is up without rules; a reload atomically replaces only `table inet router` |
| Autologin | Safe, getty console is local-only, no network auth surface exists |

The `router.hashedPassword` option exists only to lock down vsock console access from the host side (e.g., shared-host scenarios). It is not a network security control, VMs cannot reach the router console regardless.

### Router Console

```bash
shard -c router            # serial console (router-stable: shard -c router-stable)
```

| | |
|---|---|
| User | `hydrix.router.username`, default: your main `hydrix.username` |
| Login | Automatic on the console (getty autologin) |
| Password | `hydrix.router.hashedPassword` if set, otherwise the literal `router` |
| Root | `sudo` without a password (the user is in `wheel`, `wheelNeedsPassword = false`) |

Use `sudo` for anything privileged: `sudo systemctl restart router-firewall`, `sudo nft list ruleset`. A plain `systemctl restart ...` asks polkit for the user's password instead, which is `router` unless you set one. `vpn-assign` re-runs itself under `sudo`.

Useful checks from the console:

```bash
vpn-assign status                                    # assignments, tunnels, per-network tables
ip rule                                              # 10: to <LAN> main, 20: DNAT replies, <octet>: per network
sudo nft list table inet router                      # firewall, lan_access set, vpn_dns map
sudo nft list table ip hydrix-lan                    # port forwards (pentest-lan, lanControl.forwards)
systemctl status router-firewall vpn-policy-init router-nic-check router-lan-forwards
```

To set a real password: `mkpasswd -m sha-512`, then `hydrix.router.hashedPassword = "<hash>";` in the machine config, `rebuild`.

### VM-to-VM Isolation

Each VM subnet is isolated from all others at the router's `forward` chain. A compromised browsing VM cannot reach the pentest or dev VM's subnet, and vice versa. Because each router LAN interface drops packets whose source is outside its own subnet, a VM also cannot pose as another network to get past these rules or to pick another network's VPN exit.

```
pentest  -> browse:  BLOCKED
pentest  -> comms:   BLOCKED
browse   -> dev:     BLOCKED
any VM   -> WAN:     ALLOWED  (via NAT through router, per-network route, see Mullvad VPN)
```

Exceptions are explicit: `hydrix.router.microvm.firewall.sharedSubnets` (subnets open to all), `firewall.allowedAccessTo` (scoped IP/port pairs), and connections redirected by a DNAT rule on the router itself (`ct status dnat`, e.g. `router-lan-control` port forwards), which only root on the router can create.

The files VM (`microvm-files`) bypasses this intentionally by connecting directly to bridges via dedicated TAP interfaces explicitly granted per-bridge via `microvmFiles.accessFrom`. Passphrases for encrypted file transfer travel exclusively over vsock, never over bridge networks.

### Uplink LAN Access (`pentest-lan`)

VM networks cannot reach the physical LAN the router's uplink is on (the home, hotel or office network): the router drops traffic from a VM network to private addresses (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`) leaving through the uplink. Tunnels and the internet are unaffected, and the host's management network is always allowed (captive portals, local printers in administrative mode).

Access is granted per network at runtime from the host, through `router-lan-control` on the router (vsock 14516). Names are vm-registry keys:

```bash
pentest-lan enable pentest            # pentest's network may reach the uplink LAN
pentest-lan disable pentest           # isolate it again
pentest-lan forward add 8080 pentest  # uplink TCP 8080 -> pentest VM (<subnet>.<CID>):8080
pentest-lan forward remove 8080 pentest
pentest-lan status
```

- Grants are a firewall set (`lan_access`); `enable` also adds a policy rule so a tunnelled network's LAN traffic bypasses its tunnel. Grants survive a firewall reload (`router-lan-control.service` re-applies them), not a router restart.
- Forwards are DNAT rules in the router's own `ip hydrix-lan` table. Replies to any connection the router DNATed are routed back via the main table, so forwards also work for VPN-routed VMs and without LAN access.
- Standing forwards (e.g. a media server for a TV on the LAN) are declared in the router config instead, and applied the same way once the uplink is up:

  ```nix
  # infra/router/default.nix
  hydrix.router.lanControl.forwards = [ { cid = 107; port = 8096; } ];
  ```

### Host Isolation

The host has no L3 presence on VM bridges. All bridges exist as pure L2 plumbing:
- No IPv4 addresses on any bridge in any mode
- IPv6 link-local auto-assignment is disabled on all VM bridges via sysctl (`net.ipv6.conf.<br>.disable_ipv6`)
- The host never routes: `net.ipv4.ip_forward = 0`. libvirt's `default` network (`virbr0`) is isolated (no `<forward>`), so libvirt never switches forwarding back on; standalone libvirt VMs attach to router-served bridges (`deploy-vm` picks one per type) and get internet from the router

The one exception is `br-mgmt` in **Administrative** mode, where the host needs `192.168.100.1/24` to route through the router VM as a gateway. That address is absent in Lockdown.

| Bridge | Lockdown | Administrative |
|--------|----------|----------------|
| br-mgmt | no address | `192.168.100.1/24` (gateway route) |
| br-shared | no address | no address |
| all others | no address | no address |

In **Lockdown** mode (default boot):
- No bridge addresses - host is invisible to all VMs at L3
- No default gateway - host has no internet access
- Host builds happen via the builder VM, which has internet through the router
- Git push/pull happens via the gitsync VM, which mounts repos from the host R/W
- All VM communication uses vsock, which is independent of bridge networking

In **Administrative** mode:
- `192.168.100.1/24` assigned to `br-mgmt` for the gateway route
- Host gains internet via the router VM (`192.168.100.253` as default gateway)
- All VM isolation properties remain unchanged; VMs still cannot reach the host on any other bridge

### WiFi Credentials and the Nix Store

All VMs share the host's `/nix/store` read-only via virtiofs, so anything baked into a VM's closure is readable by every VM, including a compromised browsing or pentest VM. WiFi credentials are therefore never part of a build: they live sops-encrypted in `secrets/wifi.yaml` and are delivered only to the router VM at boot via virtiofs. There is no Nix option for declaring networks (`hydrix.router.wifi.networks` was removed). See [Secrets Management](#secrets-management) for setup, and [WiFi Credential Management](#wifi-credential-management-wifi-sync) for the `wifi-sync` workflow.

---

## Installation

### Installer Modes

Both installer scripts (`install-hydrix.sh` for fresh installs, `setup-hydrix.sh` for migrations) support three modes:

| Mode | When it triggers | What it does |
|------|-----------------|--------------|
| **fresh** | No existing `hydrix-config` found | Prompts for everything: username, colorscheme, disk layout, WiFi. Generates the full config tree from templates. |
| **add** | Existing repo detected, hardware serial not in it | Skips user/locale prompts - they're already in `modules/user.nix` and `modules/common.nix`. Only generates `machines/<serial>.nix` for the new hardware. |
| **use-existing** | Hardware serial already in the repo | Re-runs hardware detection and regenerates the machine config. No prompts. |

The **add** mode is the normal path when bringing a second (or third) machine into an existing `hydrix-config`. User identity, locale, colorscheme, and WM choice are already shared across machines - only hardware-specific values need to be generated.

### Fresh Install (From Live Environment)

```bash
# Download and run installer
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
```

The installer will:
1. **Auto-detect hardware**: CPU (Intel/AMD), WiFi PCI address, ASUS features, hardware serial
2. **Detect `system.stateVersion`**: read from the live ISO's own running NixOS release (`nixos-version`) - see [§ System State Version](#system-state-version)
3. **Prompt for identity**: Username, colorscheme, disk, WiFi credentials - written to `modules/user.nix` and `modules/common.nix`
4. **Detect locale**: Timezone, keyboard layout, and locale read from the running system - written into `modules/common.nix`
5. **Partition disk**: GPT with EFI, optional LUKS encryption via disko
6. **Generate config** in `~/hydrix-config/`:
   - `flake.nix` - Main flake importing Hydrix
   - `machines/<serial>.nix` - Hardware config (platform, VFIO, disko, display scaling, `system.stateVersion`)
   - `modules/user.nix` - Shared identity: username, colorscheme, WM choice, services
   - `modules/common.nix` - Shared locale, timezone, keyboard (applies to host and all VMs)
   - `specialisations/` - Boot mode configurations
   - `profiles/`, `infra/`, `tasks/` - VM configs copied from templates
7. **Pre-build infrastructure VMs**: `microvm-router-<serial>`, `microvm-router-stable-<serial>`, `microvm-builder`
8. **Initialize secrets** (`init_sops_during_install` in the installer, chrooted into `/mnt`): on a fresh repo it generates the [master key](#secrets-management), the one sops key for every secret on every machine, asks for its passphrase, activates it in `/mnt/var/lib/sops-nix/` so secrets decrypt on the very first boot, and writes `secrets/.sops.yaml` with the master key as the only recipient. It then encrypts any WiFi credentials collected in step 3 to `secrets/wifi.yaml`, wires `hydrix.secrets` + the router's `secrets = [ "wifi" ]` into `machines/<serial>.nix`, offers (interactive `[Y/n]`, defaults yes) an SSH deploy key for gitsync, and commits everything as a standalone `feat(secrets): initialize sops for <serial>` commit. On an **add**-mode install (existing repo cloned in), it wires the machine config to the secrets already in the repo and offers to unlock the committed `secrets/master-age-key.age` right away; `.sops.yaml` is left untouched, since there is no per-machine key to add. If the master key cannot be created, it warns and leaves secrets to `hydrix-sops-setup` after first boot.

Profile VMs (browsing, pentest, dev, comms, lurking) are **not** built during install. Build them on demand after first boot:

```bash
shard build browsing
shard build pentest
# etc.
```

On first boot:
- **Router starts automatically** (controlled by `router.autostart = true`)
- **Other VMs are declared but not started** - build them on demand

To customize VMs per-machine, edit `machines/<serial>.nix`. Profile/task VMs are per-machine
nixosConfigurations (see [§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)),
so `byName` resolves the name to this machine's VM:

```nix
{ config, ... }: {
  hydrix.microvmHost.byName.pentest.enable = false;  # Disable if not needed
}
```

To apply NixOS options to a specific VM only on this machine (without affecting other machines in the flake), use `profileOverrides`:

```nix
hydrix.microvmHost.profileOverrides = {
  # Cap virtiofsd threads on lower-spec machines
  browsing = { lib, ... }: {
    microvm.virtiofsd.threadPoolSize = lib.mkForce 1;
  };
  # Pass through a webcam to the comms VM
  comms = { ... }: {
    microvm.qemu.extraArgs = [
      "-device" "qemu-xhci,id=usb-ctrl"
      "-device" "usb-host,vendorid=0x046d,productid=0x0825"
    ];
  };
};
```

### Migration from Existing NixOS

```bash
# Run the setup script
./scripts/setup-hydrix.sh
```

This auto-detects your current system configuration and generates a minimal Hydrix config preserving your existing disk layout. Same three installer modes apply - if `~/hydrix-config/` already exists, it detects the serial and selects add or use-existing automatically. `system.stateVersion` is read from your existing `/etc/nixos/configuration.nix` (prompting for manual entry if that line isn't found), never re-detected from the currently running release - see [§ System State Version](#system-state-version).

Secrets are initialized the same way as `install-hydrix.sh` (master key generation and `.sops.yaml` on a fresh repo, WiFi/deploy-key encryption, master-key unlock in add mode), via `init_sops_and_wifi` - adapted to run against the live system with `sudo` instead of a chroot. One difference: it does not auto-commit the result, it prints the `git add secrets/ ... && git commit` command to run yourself afterward.

### Adding a Machine to an Existing Config

When you have a working `hydrix-config` on one machine and want to bring a second machine in without repeating all the setup steps:

1. **Boot the new machine** from the NixOS ISO

2. **Run the installer** - it detects the existing repo and enters **add** mode automatically:

   ```bash
   curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
   # When prompted: provide your hydrix-config git URL
   ```

   The installer clones your repo, detects the hardware serial, and generates only `machines/<serial>.nix`. It does **not** prompt for username, colorscheme, or locale - those are already in `modules/user.nix` and `modules/common.nix`.

   Secrets need nothing per machine: every secret is encrypted to the repo's master key only, so the installer just offers to unlock `secrets/master-age-key.age` with its passphrase. Say yes, and secrets decrypt on the very first boot. If you skip it, run `hydrix-sops-setup --unlock` after first boot; until then decrypt services warn and VMs start without secrets.

**What the installer skips in add mode:**
- Username, hostname, colorscheme prompts (already in `modules/user.nix`)
- Locale, timezone, keyboard prompts (already in `modules/common.nix`)
- Template provisioning (profiles/, infra/, tasks/ already exist in the repo)

**What it generates:**
- `machines/<new-serial>.nix` - hardware config: VFIO WiFi passthrough, platform, disko layout, display scaling

### Generated Configuration Structure

```
~/hydrix-config/
├── flake.nix                    # Imports Hydrix, auto-discovers all VMs
├── machines/
│   └── <serial>.nix             # Hardware config (one per machine, named by serial)
├── modules/                     # Settings shared across all machines
│   ├── user.nix                 # Identity: username, colorscheme, WM, services
│   ├── common.nix               # Locale, timezone, keyboard (host + all VMs)
│   ├── graphical.nix            # UI: gaps, bar height, opacity, lockscreen
│   ├── fonts.nix                # Font packages and per-app profiles
│   ├── fish.nix                 # Shell abbreviations and functions
│   ├── alacritty.nix            # Terminal cursor, keyboard overrides
│   ├── notifications.nix        # Notification popups: size, sound, timeouts
│   ├── ranger.nix               # File manager keybindings and rifle rules
│   ├── starship.nix             # Prompt configuration
│   ├── vim.nix                  # Editor configuration
│   ├── firefox.nix              # Host Firefox toggle and user-agent
│   └── obsidian.nix             # Host Obsidian toggle and vault paths
├── profiles/                    # Graphical VM customizations (overlay on Hydrix base)
│   ├── browsing/
│   │   ├── meta.nix             # CID, bridge, subnet, workspace, label, focusBorder
│   │   ├── default.nix          # NixOS config: colorscheme, RAM, vCPUs, packages
│   │   └── packages/            # vm-sync managed packages
│   ├── pentest/
│   ├── dev/
│   ├── comms/
│   └── lurking/
├── infra/                       # Headless infrastructure VM configs
│   ├── router/default.nix       # Router: DNS servers, firewall, extra packages
│   ├── builder/default.nix      # Builder: lockdown-mode nix build settings
│   ├── files/default.nix        # Files VM: accessFrom list, storage size
│   ├── gitsync/default.nix      # Gitsync: repo paths and remote URLs
│   ├── hostsync/default.nix     # Hostsync: inbox path
│   ├── vault/default.nix        # Vault: KeePassXC database path
│   └── usb-sandbox/default.nix  # USB sandbox settings
├── tasks/                       # Task slots, generated from one block
│   ├── default.nix              # count, baseCid, base profile, secrets, shared module
│   └── slots.nix                # expands default.nix: CID, bridge, subnet per slot
├── colorschemes/                # Custom pywal colorschemes (JSON)
├── specialisations/
│   ├── _base.nix                # Packages present in all modes
│   ├── lockdown.nix             # Default: hardened, no host internet
│   ├── administrative.nix       # Full functionality, router VM gateway
│   └── fallback.nix             # Emergency: direct WiFi, no VMs
├── secrets/                     # sops-encrypted credentials
│   ├── .sops.yaml               # Recipient list (age keys per machine + personal key)
│   ├── wifi.yaml                # WiFi credentials (encrypted)
│   └── github.yaml              # GitHub SSH key (encrypted)
└── vpn/
    └── mullvad.nix              # Per-bridge Mullvad exit node mapping
```

### Profile Customization

User profiles are layered ON TOP of Hydrix base profiles. You get all base functionality plus your customizations:

```nix
# profiles/pentest/default.nix
{ config, lib, pkgs, ... }:
{
  imports = [ ./packages ];

  # Override colorscheme (base uses nvid)
  hydrix.colorscheme = "nord";

  # Add extra packages
  environment.systemPackages = with pkgs; [ gobuster ffuf ];

  # Add CTF hosts
  networking.extraHosts = ''
    10.10.10.1  target.htb
  '';
}
```

### Flake Location Detection

Hydrix auto-detects your config with this priority:
1. `$HYDRIX_FLAKE_DIR` environment variable
2. `~/hydrix-config/` (user mode - imports from GitHub)
3. `~/Hydrix/` (developer mode - local clone)

### User Flake Example

```nix
{
  inputs.hydrix.url = "github:borttappat/Hydrix";
  inputs.nixpkgs.follows = "hydrix/nixpkgs";

  outputs = { hydrix, ... }:
  let
    machineName = "ABC123XYZ";  # this machine's hardware serial
    userProfiles = ./profiles;  # Your profile customizations
    machineConfig = hydrix.lib.mkHost {
      modules = [ ./machines/${machineName}.nix ];
    };
    # Every VM belonging to this machine inherits its system.stateVersion directly -
    # see § System State Version. Never set stateVersion per-VM.
    stateVersionModule = { system.stateVersion = machineConfig.config.system.stateVersion; };
  in {
    nixosConfigurations."${machineName}" = machineConfig;

    # MicroVMs with user profiles overlaid on Hydrix base.
    # Profile VMs are per-machine nixosConfigurations, named "microvm-<profile>-<machineName>"
    # (the router follows the same pattern below) - see § VM Naming and Machine Identity.
    # hostname = the nixosConfiguration key; sets hydrix.vm.storeName (structural, do not change)
    # To customise the in-VM hostname, set hydrix.vm.hostname in profiles/<name>/default.nix
    nixosConfigurations."microvm-browsing-${machineName}" = hydrix.lib.mkMicroVM {
      profile = "browsing";
      hostname = "microvm-browsing-${machineName}";
      modules = [ stateVersionModule ];
      inherit userProfiles;  # Your customizations in ./profiles/browsing/
    };

    nixosConfigurations."microvm-pentest-${machineName}" = hydrix.lib.mkMicroVM {
      profile = "pentest";
      hostname = "microvm-pentest-${machineName}";
      modules = [ stateVersionModule ];
      inherit userProfiles;
    };

    # Infrastructure VMs. Router is per-machine too (VFIO WiFi PCI address is inherently
    # per-machine hardware); the rest are shared across every machine in the flake since
    # they hold no state that would need isolating (not user-configurable either way).
    nixosConfigurations."microvm-router-${machineName}"        = hydrix.lib.mkMicrovmRouter { inherit wifiPciAddress; };
    nixosConfigurations."microvm-router-stable-${machineName}" = hydrix.lib.mkMicrovmRouterStable { inherit wifiPciAddress; };
    nixosConfigurations."microvm-builder"                      = hydrix.lib.mkMicrovmBuilder {};
  };
}
```

This single-machine example spells names out directly for clarity. The real generated
`flake.nix` (see [§ Generated Configuration Structure](#generated-configuration-structure))
auto-discovers every machine under `machines/*.nix` and loops profile/task VM generation over
`machine × profile`, so adding a second machine to a real Hydrix config needs no changes to
this wiring at all - just a new `machines/<serial>.nix` file.

### Library Functions

| Function | Purpose |
|----------|---------|
| `hydrix.lib.mkHost` | Create host configuration |
| `hydrix.lib.mkMicroVM` | Create MicroVM configuration |
| `hydrix.lib.mkMicrovmRouter` | Create MicroVM router (main, tunable) |
| `hydrix.lib.mkMicrovmRouterStable` | Create stable fallback router (manual "break glass", never auto-starts) |
| `hydrix.lib.mkMicrovmBuilder` | Create builder VM for lockdown mode |
| `hydrix.lib.mkVM` | Create libvirt VM (for images) |
| `hydrix.lib.mkLibvirtRouter` | Create libvirt router (fallback) |

---

## Configuration

All configuration is done through `hydrix.*` options in your machine config file (`machines/<hostname>.nix`).

### Identity & User

```nix
{
  hydrix = {
    username = "user";
    hostname = "hydrix";
    colorscheme = "hydrix";

    user = {
      hashedPassword = null;         # mkpasswd -m sha-512 (null = prompt on first login)
      sshPublicKeys = [];            # SSH authorized_keys
      extraGroups = [];              # Additional groups beyond defaults
    };

  };
}
```

### System State Version

Every machine config declares a plain, native `system.stateVersion` (not under `hydrix.*` -
this is standard NixOS, not a Hydrix option):

```nix
# machines/<serial>.nix
system.stateVersion = "25.05";
```

This is detected **once**, automatically, and is never meant to change afterward - per the
[NixOS manual](https://nixos.org/manual/nixos/stable/options.html#opt-system.stateVersion),
bumping it can silently change defaults for stateful services, so it should always reflect
when this specific machine was originally installed, not whatever release it happens to be
running today.

- **`install-hydrix.sh`** (fresh install): reads the live ISO's own running NixOS release
  (`nixos-version`), since there's no prior install to preserve a value from.
- **`setup-hydrix.sh`** (migrating an existing install): reads the value already declared in
  the machine's existing `/etc/nixos/configuration.nix`, carrying it forward as-is. If that
  file has no `system.stateVersion` line, you're prompted to enter it manually.
- Neither script ever derives it from the framework's own currently-pinned nixpkgs channel -
  that would defeat the purpose (a machine installed years ago on an older release must keep
  its original value even after `nix flake update` moves the whole fleet forward).

**Every profile VM and task VM belonging to a machine inherits that machine's
`system.stateVersion` automatically** - each VM's build gets it injected directly in
`flake.nix` (`{ system.stateVersion = machineConfigs.<name>.config.system.stateVersion; }`),
the same way each VM inherits its own per-machine identity (see
[§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)). You never set
`system.stateVersion` per-VM, and a second machine with a different value only ever affects
its own VMs. Infra VMs (router-stable, builder, files, gitsync, hostsync, usb-sandbox, vault)
don't participate in this at all - they're ephemeral (see
[§ Infra VM Persistence Model](#infra-vm-persistence-model)), so there's no stateful service
config to protect from drifting.

### Locale and Timezone

Locale is standard NixOS, configure it once in `modules/common.nix` and it applies to the host and all VMs automatically:

```nix
# modules/common.nix
time.timeZone                 = "America/New_York";
i18n.defaultLocale            = "en_US.UTF-8";
i18n.extraLocaleSettings      = { LC_ALL = "en_US.UTF-8"; };
console.keyMap                = "us";
services.xserver.xkb.layout  = "us";
services.xserver.xkb.variant = "";
```

The installer detects and populates these from your current system during a fresh install. When cloning an existing `hydrix-config` repo to new hardware, they are already set.

### Default Applications

```nix
{
  hydrix = {
    terminal = "alacritty";
    shell = "fish";                  # fish, bash, or zsh
    browser = "firefox";
    editor = "vim";
    fileManager = "ranger";
    imageViewer = "feh";
    mediaPlayer = "mpv";
    pdfViewer = "zathura";
  };
}
```

### Hardware

```nix
{
  hydrix.hardware = {
    platform = "intel";              # "intel", "amd", or "generic"
    isAsus = false;                  # ASUS-specific features (aura, power-profile)

    vfio = {
      enable = true;                 # Enable VFIO for PCI passthrough
      pciIds = [ "8086:a840" ];      # PCI vendor:device IDs to bind to vfio-pci
      wifiPciAddress = "00:14.3";    # PCI address of WiFi card for passthrough
    };

    grub.gfxmodeEfi = "1920x1200";  # GRUB EFI graphics mode
  };
}
```

### Webcam Passthrough

Passes a USB webcam exclusively to a profile VM. Find your webcam's IDs with `lsusb`:

```
Bus 003 Device 002: ID 3277:0059 Shinetech ASUS FHD webcam
                       ^^^^:^^^^
                       vid  pid
```

```nix
# machines/<serial>.nix
hydrix.webcamPassthrough = {
  enable        = true;
  vendorId      = "3277";
  productId     = "0059";
  targetProfile = "comms";  # default - omit if using comms VM
};
```

This sets a udev rule granting `kvm` group ownership of the device node and injects QEMU USB passthrough args into the target VM via `microvmHost.profileOverrides`. Since profile VMs are per-machine (see [§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)), `profileOverrides` applies only to *this* machine's build of the target VM - a second machine's VID/PID never leaks into another machine's comms VM.

**The passthrough is exclusive.** The webcam is unavailable on the host while the VM is running. To temporarily restore host access:

```bash
shard stop comms   # host reclaims webcam
shard start comms  # webcam returns to VM
```

After enabling, rebuild the host (applies udev rule), then rebuild the VM:

```bash
rebuild
shard rebuild comms
```

### Router

```nix
{
  hydrix.router = {
    type = "microvm";               # "microvm", "libvirt", or "none"
    autostart = true;

    # WiFi networks are not declared here: they live in secrets/wifi.yaml,
    # managed with wifi-sync (see "WiFi Credential Management" below).

    # Mullvad VPN integration
    vpn.mullvad = {
      enable = true;
      privateKey = "";               # WireGuard private key
      address = "";                  # Assigned VPN address (e.g., 10.65.x.x/32)
      exitNodes = {
        se-sto = { server = "se-sto-wg-001.relays.mullvad.net"; publicKey = "..."; };
      };
    };

    # Libvirt router options (when type = "libvirt")
    libvirt.wan = {
      mode = "auto";                # "auto", "pci-passthrough", "macvtap", "none"
      device = null;                # Auto-detect, or specify PCI address / interface name
      preferWireless = true;
    };
  };
}
```

### WiFi Credential Management (wifi-sync)

`wifi-sync` manages WiFi networks stored sops-encrypted in `secrets/wifi.yaml`. It communicates with the router VM over vsock port 14506. See [Secrets Management](#secrets-management) for the sops setup; `wifi-sync` creates `secrets/wifi.yaml` on its first save.

#### How it works

The router VM's NetworkManager keeps its connections in `/var/lib/NetworkManager/system-connections/`. At boot, `hydrix-wifi-from-sops` adds every network from `secrets/wifi.yaml` there (delivered via virtiofs, never through the Nix store). Networks added at runtime with `nmcli` or `wifi-sync add` land in the same directory.

The router reverts to its baseline on every boot: its `/var/lib` is ephemeral (tmpfs root, see [Infra VM Persistence Model](#infra-vm-persistence-model)), so runtime-added networks only last until the next restart unless they are saved to `secrets/wifi.yaml`. `wifi-sync add`/`pull` do that. `hydrix.router.persistence.enable` keeps `/var/lib/NetworkManager` on a small volume instead; leave it off unless a router must keep state of its own.

`wifi-sync` (POLL command over vsock) diffs the router's connections against `secrets/wifi.yaml`. The router reports per profile whether it ever connected (NetworkManager's `timestamps` file); profiles left by failed attempts are not counted. The waybar WiFi widget shows **+N** when the router has N connected networks that are not saved. This is your signal to run `wifi-sync pull`.

#### Commands

```bash
wifi-sync                    # Admin: status + pending count. Fallback: capture current connection
wifi-sync add SSID PASSWORD  # Push network to router NM and save to secrets/wifi.yaml
wifi-sync pull               # Save all connected router networks to secrets/wifi.yaml
wifi-sync list               # Show saved networks
wifi-sync remove SSID        # Remove from secrets/wifi.yaml and from router NM
```

**Admin mode** applies when the router VM is reachable via vsock (normal lockdown/administrative operation).

**Fallback mode** applies when the router VM is not running (fallback specialisation with direct host WiFi). `wifi-sync` reads the current connection from the host's `nmcli` and saves it to `secrets/wifi.yaml`.

No rebuild is needed to apply a change on the running router: `wifi-sync add` pushes the network to the router's live NM over vsock immediately. The saved file reaches the router on its next boot after a host `rebuild` (the host decrypts `secrets/wifi.yaml` from its own build).

#### Wiring (machine config)

The installer does this when WiFi credentials are given during installation. Otherwise, after the first `wifi-sync` save:

```nix
hydrix.secrets = {
  enable = true;
  wifiSecretsFile = ../secrets/wifi.yaml;
};

hydrix.microvmHost.vms = {
  "microvm-router-<serial>" = { autostart = true; secrets = [ "wifi" ]; };
};
```

#### Migrating an old modules/wifi.nix

Older configs declared networks in `modules/wifi.nix` (`hydrix.router.wifi.networks`), which put them in the Nix store. That option no longer exists, and setting it fails evaluation with a message saying so. To migrate:

```bash
setup-wifi-secrets    # reads modules/wifi.nix, encrypts to secrets/wifi.yaml
git add secrets/wifi.yaml
```

Then add the wiring above, delete `modules/wifi.nix` and its `./modules/wifi.nix` imports in `flake.nix`, `rebuild`, and `shard -bR router`.

### Networking

Built-in bridges (`br-mgmt`, `br-pentest`, `br-comms`, `br-browse`, `br-dev`, `br-builder`, `br-lurking`, `br-files`) are created automatically, no configuration needed for the default set.

To add a custom bridge beyond the built-in set, use `extraNetworks`. Each entry creates a host bridge (`br-<name>`), TAP attachment rules, and a DHCP subnet in the router VM. Declare it once; it is injected into both the host and router VM configs automatically.

```nix
{
  hydrix.networking.extraNetworks = [
    {
      name      = "office";          # creates br-office
      subnet    = "192.168.109";     # /24 prefix, .253 becomes the router gateway
      routerTap = "mv-router-offi";  # router-side TAP name (max 15 chars)
    }
  ];
}
```

Profile and infra VMs that declare `routerTap` in their `meta.nix` are wired into `extraNetworks` automatically by the flake - you only need to set `extraNetworks` manually for bridges not tied to a profile or infra VM.

Every router LAN needs its own subnet: the third octet also sets the router's NIC MAC on that bridge (see [§ Router NIC table](#router-nic-table-vmmicrovminfrarouter-nicsnix)), and a duplicate fails the build.

Advanced networking options (rarely needed):

```nix
{
  hydrix.networking = {
    hostIp   = "192.168.100.1";    # DEFAULT: host IP on br-mgmt
    routerIp = "192.168.100.253";  # DEFAULT: router VM IP on br-mgmt
  };
}
```

### MicroVM Host

```nix
{
  hydrix.microvmHost = {
    enable = true;

    # Per-VM settings, by VM name: each name resolves to this machine's VM (serial
    # included), so a shared module (modules/vms.nix) can set them for every machine and a
    # machine config overrides with a plain assignment. Only declare what you change:
    # every VM is enabled by default without an entry.
    byName = {
      browsing.autostart = false;
      dev.repos = [ "hydrix-config" ];
      pentest.encryption = true;
      router.secrets = [ "wifi" ];
    };
  };

  hydrix.builder.enable = true;      # Builder VM for lockdown mode builds
}
```

`byName` keys are the registry names (`browsing`, `dev`, `router`, `gitsync`, `pentest-task1`,
...); an unknown one is a build error that lists the valid names. The full-name form
`hydrix.microvmHost.vms."microvm-dev-<serial>"` sets the same options and still works.

`hydrix.microvmHost.vmNames` also exists (`.router`/`.routerStable` only) but it's internal
wiring the flake sets for you - it's how the router's per-machine name gets threaded into
the host module, not a user customization surface. There's no equivalent for profile/task
VM names: those are always `microvm-<profile>-<serial>` and are never user-renameable, since
that fixed pattern is exactly what lets the short-form CLI (`shard start browsing`) resolve
them.

#### Coupled vs Decoupled VMs

`rebuild` builds the host only. Every VM is **decoupled** by default: excluded from
`config.microvm.vms` and built with `shard -b <name>`, which builds the runner and relinks
`/var/lib/microvms/<name>/current` (the image `microvm@<name>` boots). `rebuild -a` also
runs `shard -b` on every infra VM that has been built on the machine before, and every
`rebuild` lists running VMs whose `current` differs from the image they booted. Nothing is
restarted automatically. A fresh install builds all infra VMs once (`hydrix-firstboot-vms`),
and autostart goes through `hydrix-microvm-autostart-<name>`.

A **coupled** VM is placed in `config.microvm.vms`: the host build includes its runner and
activation relinks its `current`. Each VM's class (infra, profile, or task) is populated
automatically by the consuming flake into `hydrix.microvmHost.vmClasses`, do not set this
manually.

```nix
# Per VM, in a machine config: overrides the default either direction.
hydrix.microvmHost.byName.dev.coupled = true;

# Repo-wide, in the user flake: couples ALL profile/task VMs at once.
# A per-VM `coupled` override above still wins over this either way.
hydrix.microvmHost.coupleProfiles = true;
```

### Elastic CPU/RAM (`hydrix.vmElastic`)

A host-side daemon per profile VM that ballons memory (QMP `balloon`) and throttles CPU
(cgroup `CPUQuota` on the VM's own systemd unit) down while idle, and restores both to
their ceiling immediately under real load or while the VM is still booting. Mechanism:

- **RAM**: microvm.nix's `microvm-balloon` script (QMP `balloon`, requires `microvm.balloon
  = true`, already on for all profile VMs). Tracks headroom (`cur_mem - real usage`, from
  vm-metrics' `rammb` field) rather than a percentage - a percentage-of-current-allocation
  ratio necessarily drifts toward 100% as the balloon squeezes `cur_mem` down near a VM's
  real baseline usage, causing false "distress" reactions that have nothing to do with
  actual memory pressure.
- **CPU**: `systemctl set-property --runtime <unit> CPUQuota=<pct>%` - no vCPU hotplug
  exists under the `"microvm"` qemu machine type (no ACPI), and a cgroup quota is fluid
  rather than a hard allocation anyway, the guest never sees its vCPU count change.
- **Workspace-hold**: the VM's assigned Hyprland workspace being the active one holds
  ceiling unconditionally, same priority as real load - see below for why this exists.
- **Idle-absolute**: zero Hyprland clients matching the VM's waypipe `[name]` title prefix
  -> immediate step-down toward the floor, no debounce.
- Otherwise: guest CPU/RAM headroom below the low threshold for `lowDebounceTicks`
  consecutive polls -> gradual step down toward the low floor. Headroom below the high
  threshold (real distress) -> immediate step up to ceiling. Between the two: hold.

Every profile VM is enabled automatically, with `memCeilingMb`/`cpuCeilingPct` and the
four floor values all derived from that profile's own `meta.nix` (`mem`, `vcpu`,
`memLowFloorMb`, `memFloorMb`, `cpuLowFloorPct`, `cpuFloorPct`) - a profile author sets
these once, no per-machine boilerplate required. To override a specific field for just one
machine, plain-assign it directly - it wins over the profile's `meta.nix`-derived default:

```nix
# machines/<serial>.nix
hydrix.vmElastic.vms.lurking.memFloorMb = 2048;
hydrix.vmElastic.vms.lurking.cpuLowFloorPct = 100;
hydrix.vmElastic.vms.lurking.memAvailableMinMb = 768;  # see § availmb below
hydrix.vmElastic.vms.dev.enable = false;  # opt this VM out of elastic management entirely
```

`unitName`/`cid`/`titlePrefix`/`workspace` are structural (derived from the profile name,
machine serial, and the profile's own `meta.nix`) and are not meant to be overridden.
Deliberately separate from `hydrix.microvmHost.balloonTrim`: that's a coarse periodic
timer (fixed percentage of declared ceiling, no window-awareness, no CPU management)
meant as a lightweight safety net for VMs that don't opt into this daemon - both
manipulate the same balloon device, so don't enable both for the same VM.

`cpuLowFloorPct` is a raw percent-of-one-core value, not a percent of the VM's own
ceiling - a flat `60` across every profile meant very different things depending on vCPU
count (30% of ceiling on a 2-vCPU VM, 15% on a 4-vCPU one), leaving high-vCPU profiles
with a much deeper hole to climb out of on a fresh app launch. Set it per profile as
roughly half of `cpuCeilingPct` (`vcpu * 100 / 2`) instead of copying a fixed number
across profiles with different vCPU counts.

#### Set ceilings generously - an idle VM doesn't pay for headroom it isn't using

`mem`/`vcpu` are the ceiling this daemon deflates *from*, not a resource pool the guest
occupies just by having it declared. It's tempting to set them conservatively to "save
resources," but that reasoning doesn't hold once a VM is under real elastic management:

- An unused vCPU costs essentially nothing on the host - KVM's `KVM_RUN` loop for a vCPU
  thread with no guest work simply blocks, it doesn't spin or consume cycles. Declaring
  `vcpu = 8` instead of `vcpu = 2` doesn't mean the VM now uses 4x the CPU at rest; the
  elastic daemon still throttles it down to `cpuFloorPct` once idle regardless of how high
  the ceiling is, and a genuinely idle vCPU above that floor just sits parked.
- `CPUQuota` is a ceiling, not a reservation - raising it doesn't take cycles away from
  anything else on the host unless the VM is actually, simultaneously using them. Verified
  live: doubling a profile's `vcpu` (2 -> 4) measurably improved how quickly real
  workloads (e.g. a browser cold-starting) felt responsive once ceiling was granted, with
  no change to idle-time host CPU.
- The same logic applies to `mem` - a higher ceiling only matters once the balloon
  actually needs to grant more, and the daemon's own floor values are what determines how
  aggressively it deflates when idle, not the ceiling.

In short: a generous ceiling only costs something once the VM is genuinely working hard
enough to use it - which is exactly when you want it available. Prefer erring high on
`vcpu` (and `mem`, within what the host physically has) over trying to guess a "just
enough" number per profile.

#### Workspace-hold: why reactive usage-based scaling isn't enough on its own

The daemon's high/low-band logic only reacts to *measured* CPU/RAM usage - which means it
only notices a fresh app launch once that app is already running and already consuming
resources under a throttled quota. Measured live: a browser cold-started on a fully
deflated VM spent its first several seconds capped at the low floor before the daemon's
own poll caught up and restored ceiling, even at a fast poll interval - a real, repeatable
"first launch is slow" experience, not a one-off.

Switching to a VM's assigned Hyprland workspace is a far earlier and cheaper signal of
intent to use it than any usage measurement can be - it happens *before* an app is even
launched. `hydrix.vmElastic.vms.<name>.workspace` (populated automatically from that
profile's `meta.nix`) is checked every poll: while it's the currently active workspace,
resources are held at ceiling unconditionally, regardless of window count or measured
usage. Stepping away from the workspace releases it back to the normal idle-absolute/
low-band behavior immediately - there is no extra debounce for leaving, only for
entering.

This is why "the VM shows high CPU/RAM while I'm actively looking at its workspace" is
expected, not a bug - that's the ceiling being held on purpose for exactly as long as
you're there.

#### The `set_cpu` stale-quota bug (fixed, worth understanding if this class of bug resurfaces)

`systemctl set-property --runtime` persists across the *daemon's own* restarts, not just
VM restarts - the cgroup's `CPUQuota` is a property of the VM's systemd unit, entirely
independent of the daemon process's lifecycle. The daemon's own `cur_cpu` tracking
variable, however, starts from an assumption (the declared ceiling) on every fresh daemon
start, never a real read of the actual unit's current `CPUQuota`.

Combined with an optimization that only issued the `systemctl set-property` call when
`target != cur_cpu`, this produced a real, confirmed bug: if a previous daemon
incarnation left the real quota throttled, a fresh daemon's very first `set_cpu ceiling`
call (during the boot-hold phase) would silently no-op against its own stale internal
assumption - the real quota never got corrected until some *other* target value happened
to differ from that assumption, which could go an entire session without happening.
Confirmed live: `cur_cpu` tracked "200" (ceiling) from daemon startup while the real
`CPUQuota` stayed at a leftover throttled value through dozens of poll ticks, including
several where measured guest CPU crossed 90%+ and should have forced ceiling.

Fixed by always re-issuing the `systemctl set-property` call unconditionally - the same
approach `set_mem` already used for the equivalent problem on the RAM side (see its own
code comment: re-issuing is "the only way to detect drift"). The call is cheap; the
correctness cost of skipping it isn't worth the savings.

#### Poll interval and reaction latency

`pollIntervalSec` (default `2`, was `10`) directly bounds how long a fresh spike in
usage can run under a throttled quota before the daemon notices and restores ceiling -
there's no debounce on the way up, only on the way down. `lowDebounceTicks` (default
`15`, was `3`) scales inversely so the real-world *descent* debounce stays the same
(`15 * 2s = 30s`, matching the original `3 * 10s`) - only the high-usage reaction time
got faster, idle-descent behavior is unchanged. Combined with workspace-hold above, this
means a fresh app launch is now backstopped two ways: ceiling is already held if you just
switched to the workspace, and even without that, any real spike is caught within ~2s
instead of ~10s.

#### `rammb`: what it measures, and why it reads lower than htop

`vm-metrics.c`'s `rammb` field - the number both the elastic daemon and waybar's VRAM
widget read - is `Active(anon) + Inactive(anon) + Shmem` from `/proc/meminfo`: process
heap/stack and shared memory pages. It deliberately excludes page cache and buffers.

This choice is load-bearing, not cosmetic. `MemTotal` is fixed for the life of the guest;
`virtio_balloon` only ever removes pages, which lowers `MemAvailable`. Any metric of the
form `MemTotal - MemAvailable` therefore rises every time the balloon deflates, with no
change in real usage - the denominator is constant while the numerator mechanically
tracks physical memory pressure the daemon itself is causing. Feeding that into a
ceiling/floor controller creates a closed loop: shrink -> metric rises -> controller
relieves back to ceiling -> shrink again.

`Active(anon) + Inactive(anon) + Shmem` has no such coupling: these pages are pinned
(would need to be swapped or killed to reclaim), so their size doesn't move just because
the balloon changed how much total memory exists. This is what makes `rammb` usable as
the daemon's headroom signal (`cur_mem - rammb`).

Because it excludes cache/buffers, `rammb` will consistently read lower than `htop`'s
"used" line - virtiofs/Nix-store reads and journal data don't count toward it. This is
the intended definition: "how much memory can safely be reclaimed right now," not "how
much memory has this VM touched." waybar and the elastic daemon both use this definition
on purpose.

The legacy `ram=` percentage field (`(MemTotal - MemAvailable) * 100 / MemTotal`) is
still emitted for display compatibility but has the same denominator problem described
above - `vm-elastic` never uses it for a decision, only `rammb`.

#### `availmb`: the hard safety floor `rammb` can't provide

`rammb` (`Active(anon) + Inactive(anon) + Shmem`) excludes anything that isn't pinned
anonymous or shared memory - which also means it excludes kernel slab and actively-mapped
binaries/libraries (`Active(file)`). A guest can be genuinely low on usable memory from
those categories while `rammb` reports no change at all.

`vm-metrics.c` also emits `availmb`, raw `MemAvailable` from `/proc/meminfo` in MB - the
kernel's own reclaim-aware estimate of how much memory a new allocation could get without
swapping. `vm-elastic` checks this as a second, independent condition alongside the
existing `kswapd`-in-`top` check: if `availmb` drops below `memAvailableMinMb` (default
512), the daemon immediately relieves to ceiling, the same response as a `kswapd`
sighting.

This check is deliberately *not* used as the primary descent signal the way `rammb` is.
`MemAvailable` has the same mechanical coupling to the balloon that made `MemTotal -
MemAvailable` unusable as a continuous signal (it necessarily drops on every deflation,
independent of real usage) - using it continuously would reintroduce the original
sawtooth. Restricting it to a one-shot hard floor, checked the same way `kswapd` already
is, gets the benefit (catching real pressure `rammb` structurally can't see) without the
downside (no continuous feedback loop to destabilize).

VMs running a `vm-metrics` build from before this field existed simply don't have this
check: `availmb_now` comes back empty, the condition is skipped, and the rest of the
daemon's logic runs unaffected.

### Graphical Configuration

```nix
{
  hydrix.graphical = {
    enable = true;
    standalone = false;              # true for libvirt VMs with own display
    colorscheme = "hydrix";
    wallpaper = "/path/to/wallpaper.jpg";
    polarity = "dark";

    # Font configuration
    font = {
      family = "Iosevka";
      size = 10;                      # Base size at 96 DPI

      # Per-app font size multipliers (final size = base * scale_factor * relation)
      relations = {
        alacritty = 1.0;
        waybar = 1.0;
        wofi = 1.0;
        notifications = 1.0;
        firefox = 1.2;
        gtk = 1.0;
      };

      # Standalone mode overrides (no external monitor)
      standaloneRelations = {};       # e.g., { alacritty = 1.05; }

      overrides.alacritty = 12;       # Fixed size (bypass scaling)
    };

    # UI dimensions
    ui = {
      gaps = 15;
      border = 2;
      barPadding = 2;
      cornerRadius = 2;              # Windows; eww/wofi panels use cornerRadius + border - 1

      # Drop shadows on windows (Hyprland), eww blocks, waybar pills, wofi and
      # notifications. Each keeps its own tuned baseline; strength scales them
      # all together.
      shadow = {
        enable = true;
        strength = 1.0;              # Multiplier on opacity and size
      };

      # Workspace labels (attrset mapping number to label)
      workspaceLabels = {
        "1" = "I"; "2" = "II"; "3" = "III"; "4" = "IV"; "5" = "V";
        "6" = "VI"; "7" = "VII"; "8" = "VIII"; "9" = "IX"; "10" = "X";
      };

      # Window opacity
      opacity = {
        active = 1.0;
        inactive = 1.0;
        overlay = 0.85;              # Unified opacity for terminals/overlays
        overlayOverrides = { alacritty = 0.95; };
        exclude = [ "Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc" ];
      };

      # Wofi dimensions
      rofiWidth = 800;                # Read by wofi.nix (name predates the wofi migration)
      rofiHeight = 400;

      # Notifications (swaync, see "Notifications" below)
      notifications = {
        width = 300;
        offset = 5;                  # Clearance past a tiled window's edge, both axes
        offsetCompensation = { x = 0; y = 0; };  # Per-machine fractional-scale fudge
        popups = true;               # false = panel only
        sound = null;                # e.g. "bell.wav"
        timeout = { low = 5; normal = 10; critical = 0; };  # Seconds, 0 = never
      };

      # Compositor animations
      compositor.animations = "modern"; # "none" or "modern"
    };

    # VM resource bar (inside VMs)
    vmBar = {
      enable = true;
      position = "bottom";
    };

    # DPI scaling
    scaling = {
      auto = true;
      applyOnLogin = true;
      referenceDpi = 96;
      standaloneScaleFactor = 1.0;
    };

    # Blue light filter
    bluelight = {
      enable = true;
      defaultTemp = 4500;
      minTemp = 2500;
      maxTemp = 6500;
      step = 200;                    # Temperature adjustment per keypress
      schedule = {
        dayTemp = 6500;
        nightTemp = 3500;
        dayStart = 7;
        nightStart = 20;
      };
    };

    # Lockscreen
    lockscreen = {
      idleTimeout = 600;             # Seconds before auto-lock (null to disable)
      font = "CozetteVector";
      fontSize = 143;
      clockSize = 104;
      text = "Enter password";
      wrongText = "Ah ah ah! You didn't say the magic word!!";
      verifyText = "Verifying...";
      blur = true;
    };

    # Stylix opt-in (see "Stylix (Opt-in Theming)") -- only meaningful if your
    # flake supplies the `stylix` input at all; both default as shown here.
    stylix = {
      autoTheme = true;   # auto-theme apps Hydrix has no curated wiring for
      exclusive = false;  # hand GTK/zathura/alacritty/fish to Stylix too
    };
  };
}
```

### Graphical Package Tiers

`modules/graphical/packages.nix` and `modules/graphical/home.nix` install different sets of packages depending on the system type, controlled by two derived booleans:

```nix
isHost    = vmType == null || vmType == "host";
isMicrovm = !isHost && !graphical.standalone;
```

| Tier | Condition | What it gets |
|---|---|---|
| **microvm** | VM with `standalone = false` | Theming only: pywal, wpgtk, feh, imagemagick, pulseaudio |
| **standalone** | VM with `standalone = true` | Same theming base, plus the Hyprland stack if `hydrix.hyprland.enable = true` is also set |
| **host** | `vmType = "host"` | Adds: ddcutil (DDC/CI monitor control) |

**Why:** MicroVMs forward apps to the host via waypipe, they have no local window manager and no physical display. Standalone libvirt VMs run a full desktop via virt-manager and need the WM stack (Hyprland), but still have no physical backlight or lockscreen. Only the host needs those.

The `standalone` option on a VM config is the switch:

```nix
hydrix.graphical.standalone = true;   # libvirt VM with own display -> full WM tier (with hyprland.enable = true)
hydrix.graphical.standalone = false;  # microVM -> theming only, display forwarded via waypipe (default)
```

**`hydrix.vm.desktopEnvironment`** (`vm/libvirt/vm-base.nix`) is the higher-level switch for libvirt VMs specifically, one option instead of wiring `graphical.standalone`/`hyprland.enable`/`greetd.enable` by hand:

```nix
hydrix.vm.desktopEnvironment = "none";     # headless, like a microVM (default)
hydrix.vm.desktopEnvironment = "xfce";     # recommended: real X11 session, spice-vdagent clipboard/resize just works
hydrix.vm.desktopEnvironment = "hyprland"; # sets graphical.standalone + hyprland.enable + greetd.enable above
```

`"xfce"` is recommended over `"hyprland"` for standalone libvirt desktops: XFCE is a real X11 session manager with native XDG autostart, so `spice-vdagent` (SPICE clipboard sync, display resize) works with zero extra wiring. `"hyprland"` reuses the Hydrix Hyprland/waypipe stack, but it's a bare WM with no session manager, `spice-vdagent` is X11-native and needs manual `exec-once` wiring to reach XWayland at all, and a fresh VM's Hyprland session falls back to its own stock example config (not Hydrix's) until `home-manager-<user>.service` finishes activating.

### Shared Modules

The `modules/` directory in your `hydrix-config` holds settings that apply to all machines. Each file is a NixOS module imported by every machine (and, where relevant, by VMs via `hostConfig`). Settings use `lib.mkDefault` so individual machine configs can override with plain assignment.

| File | What it controls | Populated by |
|------|-----------------|-------------|
| `user.nix` | Username, colorscheme, WM choice, shared services | Installer (fresh/add) |
| `common.nix` | Locale, timezone, keyboard layout, system packages | Installer (auto-detected) |
| `fonts.nix` | Font packages and per-app size relations | User |
| `graphical.nix` | Opacity, bluelight filter, bar layout, lockscreen | User |
| `waybar.nix` | Waybar config (Hyprland) | User |
| `hyprland.nix` | Hyprland keybindings and per-machine rules | User |
| `fish.nix` | Shell abbreviations and functions | User |
| `alacritty.nix` | Terminal cursor shape, keyboard overrides | User |
| `notifications.nix` | Notification popup size, sound and timeouts | User |
| `ranger.nix` | File manager keybindings and rifle rules | User |
| `zathura.nix` | PDF viewer options | User |
| `starship.nix` | Full prompt configuration (TOML inlined as Nix string) | User |
| `vim.nix` | Editor configuration (vimrc inlined as Nix string) | User |
| `firefox.nix` | Host Firefox toggle and user-agent spoofing | User |
| `obsidian.nix` | Host Obsidian toggle and vault CSS theme deployment | User |
| `tor-hardening.nix` | Tor anonymity: bridges, Firefox hardening, no-swap enforcement | User |
| `repos.nix` | Git repos, declared once: host clones, git VM pushes, VM views | User |

`user.nix` and `common.nix` are the only two files the installer writes to. All other modules are copied from templates with sensible defaults and are edited manually by the user.

#### firefox.nix

```nix
# Install Firefox on the host (always enabled in VMs)
hydrix.graphical.firefox.hostEnable = lib.mkDefault false;

# User-agent preset (null = real Firefox UA):
#   "edge-windows", "chrome-windows", "chrome-mac", "safari-mac", "firefox-windows"
# hydrix.graphical.firefox.userAgent = lib.mkDefault "edge-windows";
```

Extensions are managed per VM profile. To add one, run inside the VM:
```bash
firefox-extension-add <slug>
# slug = last part of addons.mozilla.org/en-US/firefox/addon/<slug>/
```

Each registry entry (`firefox.extensionRegistry.<name>`) can optionally pin a
content hash instead of trusting AMO's "latest" URL live at runtime:

```nix
hydrix.graphical.firefox.extensionRegistry.ublock-origin = {
  # versioned download URL, not the "latest" redirect (its content changes over time)
  url = "https://addons.mozilla.org/firefox/downloads/file/<id>/<slug>-<version>.xpi";
  hash = "sha256-...="; # nix store prefetch-file --hash-type sha256 <url>
};
```

When `hash` is set, the extension is fetched once at build time via
`pkgs.fetchurl` and hash-verified, instead of Firefox fetching `url`
live on every install. This is opt-in per extension: entries without a
`hash` keep the default live-fetch behavior, so users who don't need
reproducible/audited fetches don't have to do anything differently.

Deliberately `pkgs.fetchurl`, not `pkgs.fetchFirefoxAddon` - the latter
unpacks the `.xpi`, rewrites `manifest.json` (injects a legacy
`applications` key alongside `browser_specific_settings`) and re-zips, but
keeps the *original* `META-INF/manifest.mf`, which still lists the digest
of the pre-rewrite `manifest.json`. That mismatch makes Firefox reject the
install:
```
addons.xpi-utils  WARN  Add-on <id> is not correctly signed.
```
silently - no install, no visible error outside the Browser Console
(hamburger menu → More tools → Browser Console). `fetchurl` makes zero
content changes, so the pinned hash matches the exact bytes Mozilla signed.
Verify a fetch is safe by diffing it against a fresh download of the same
URL - it should be byte-identical.

#### obsidian.nix

```nix
# Install Obsidian on the host
hydrix.graphical.obsidian.hostEnable = lib.mkDefault false;

# Vaults to deploy the Hydrix CSS theme snippet to (paths relative to $HOME)
# hydrix.graphical.obsidian.vaultPaths = lib.mkDefault [ "notes" "hack_the_world" ];
```

The framework auto-generates a CSS snippet from the active colorscheme and font settings, deploying it to each vault's `.obsidian/snippets/` directory and enabling it via `appearance.json`.

#### repos.nix

Every repo is declared once, in `modules/repos.nix` (options in Hydrix `shared/repos-options.nix`).
The flake imports it for every machine, and `infra/gitsync/default.nix` imports it for the git VM,
which is not built per machine. The git boundary:

| Who | Does | From |
|---|---|---|
| Host | Holds every clone, makes every commit | `hydrix.repos.entries`, `ensure-repos` |
| Git VM (gitsync) | Only holder of the GitHub key; push, pull, fetch, status | entries with `push = true` |
| Other VMs | Edit working trees, cannot commit | `microvmHost.vms.<vm>.repos` in the machine config |

```nix
# modules/repos.nix
hydrix.repos = {
  enable = true;
  owner = "youruser";            # default url github.com/<owner>/<name>, sshUrl to match
  entries = {
    hydrix-config = {};          # path defaults to ~/<name>
    notes = { description = "Personal notes"; };
    site = { url = "https://github.com/youruser/site.git"; path = "/home/youruser/www"; };
    vault = { clone = false; };  # no remote yet: shared and pushable, not cloned
    scratch = { push = false; }; # host clone only
  };
};

# machines/<serial>.nix
hydrix.secrets.githubSecretsFile = ../secrets/github.yaml;   # key goes to the git VM only

# modules/vms.nix (shared by every machine)
hydrix.microvmHost.byName.dev.repos = [ "hydrix-config" ];
```

- **Host** (`host/repos.nix`): holds clones and commits, but no GitHub credential in any boot
  mode. Each entry's directory is created at activation if missing (the git VM's shares need a
  source when it starts). `ensure-repos` (run it yourself after install or after declaring a repo;
  starting the git VM asks for sudo) asks the git VM to clone every `clone = true` entry whose
  path is empty (`shard git clone <name>`), starting and stopping the VM around it. Existing
  clones are never pulled or overwritten. This works in lockdown: the git VM reaches GitHub
  through the router.
- **Git VM** (`hydrix.gitsync.agent`, `vm/microvm/infra/gitsync-agent.nix`): mounts every
  `push = true` entry at `/mnt/repos/<name>` (uid-squashed, no mknod/setfcap) and answers
  `shard git clone|push|pull|fetch|status|repos <name>` on vsock 14512, refusing undeclared
  names; `clone` only fills an empty, host-shared directory. Its
  SSH key arrives from `secrets/github.yaml` through `hydrix.secrets.github.vms` (default: the
  git VM only).
- **VM views** (`microvmHost.vms.<vm>.repos`): the host's working tree at the same path, read-write,
  with `hydrix.repos.readOnlyPaths` (default `.git`, `.claude`) read-only on the host side. See
  [Host Repos](#host-repos-hostrepos). `hostRepos` is the low-level form for paths that
  are not declared repos.
- **Guards**: the build fails when a VM names an undeclared repo, or lists `"github"` in its own
  `secrets` (extend `hydrix.secrets.github.vms` instead, only for a VM that must push).

#### waybar.nix

Unlike the old polybar setup, waybar's module layout is not driven by string options -
it's a fixed Nix-defined list per bar (`topBar`/`bottomBar`/`monoBar` in `modules/waybar.nix`).
To add or remove modules, edit that file directly (see its header comment for the pattern);
`hydrix.graphical.waybar.barType` (`"dualbar"` or `"monobar"`) is the only user-facing switch.

Module keys used in the layout include: `custom/workspace-desc`, `custom/focus`, `custom/pomo`,
`custom/sync`, `custom/git`, `custom/mvms`, `custom/vms`, `custom/volume`, `custom/temp`,
`custom/memory`, `custom/cpu`, `custom/disk`, `custom/uptime`, `custom/clock`,
`custom/power-profile`, `custom/battery`, `custom/battery-time`, `custom/rproc`, `custom/cproc`,
`custom/rproc-bottom`, `custom/cproc-bottom`, `custom/vm-cpu`, `custom/vm-ram`, `custom/vm-fs`,
`custom/vm-sync-dev`, `custom/vm-sync-stg`, `custom/vm-tun`, `custom/vm-up`, `custom/wifi-sync`.

### Waybar VM Integration

**workspace-desc** - Shows current workspace label (e.g., "BROWSING", "PENTEST") read from `/etc/hydrix/vm-registry.json` at runtime. Works automatically for any VM added to your config.

Labels can be overridden temporarily at runtime with `ws-name`:

```bash
ws-name encryption   # current workspace shows "ENCRYPTION" in the status bar
ws-name              # reset, reverts to registry label (e.g. "DEV")
```

Overrides are written to `/tmp/ws-names/<number>` and cleared automatically on reboot. The status bar module checks this directory before falling back to the vm-registry, so workspace names are never changed.

**focus** - Shows which VM type is currently focused on each workspace. Uses the same vm-registry lookup.

**Bottom bar modules** (vm-ram, vm-cpu, rproc-bottom, cproc-bottom, etc.) - Query running VMs by polling vm-registry, then fetch metrics via vsock from each VM's CID (port 14501).

Each profile VM runs a `vm-metrics` systemd service, a compiled C binary (`vm-metrics-server`) that collects CPU, RAM, disk, uptime, top processes, and tunnel traffic by reading `/proc` and `statvfs()` directly. It never calls external binaries during collection, which avoids virtiofsd round-trips: every process spawned in a VM resolves its `/proc/<pid>/exe` symlink through virtiofs into the host's `/nix/store`, causing host-side virtiofsd reads per spawn. The C binary loads once from virtiofs at service start, then runs entirely from guest RAM.


The collection interval and polling interval are tunable:
```nix
hydrix.vmMetrics = {
  vmCollectInterval = 5;   # seconds between collection cycles inside each VM (default: 5)
  hostPollInterval  = 5;   # seconds between host polling the active workspace VM (default: 5)
  staleThreshold    = 15;  # seconds before a cached snapshot is considered stale (default: 15)
};
```

The host queries the snapshot via vsock on demand,the VM only writes to `/run/vm-metrics-snapshot`; the host reads it when status bar modules poll.

### Power Management

```nix
{
  hydrix.power = {
    defaultProfile = "balanced";     # "powersave", "balanced", or "performance"
    chargeLimit = null;              # Battery charge limit % (20-100, null = no limit)
  };
}
```

Change at runtime: `power-mode <powersave|balanced|performance>`

ASUS laptops also have `power-profile` which coordinates both the ASUS platform profile (fan curves) and CPU power mode together:

```bash
power-profile quiet        # ASUS Quiet + CPU powersave
power-profile balanced     # ASUS Balanced + CPU balanced
power-profile performance  # ASUS Performance + CPU performance
power-profile status       # Show both profiles
```

#### What Each Mode Does

| Setting | Powersave | Balanced | Performance |
|---------|-----------|----------|-------------|
| **Governor** | `powersave` | `powersave` (HWP) | `performance` |
| **Max Frequency** | 60% cap | 100% | 100% |
| **Turbo Boost** | Disabled | Enabled | Enabled |
| **EPP** | `power` | `balance_power` | `performance` |
| **auto-cpufreq** | Stopped | Stopped | Stopped |

- **Powersave**: Hard-caps CPU at 60% max frequency via `intel_pstate/max_perf_pct`, disables turbo boost, and sets EPP to `power`. Useful for battery life but can feel sluggish under load.
- **Balanced**: Sets governor to `powersave` with EPP `balance_power`. On Intel CPUs with Hardware P-states (HWP), the hardware scales frequency autonomously in microseconds based on load, no userspace daemon needed. `auto-cpufreq` is not used; its 2-second polling loop was causing periodic CPU spikes with no benefit on HWP hardware.
- **Performance**: Locks governor to `performance`, enables turbo, and sets EPP to `performance`. Maximum speed at the cost of power and thermals.

The status bar PWR module shows the current mode (SAVE/AUTO/PERF) and left-clicking cycles through all three modes.

### Waybar Layout

| `hydrix.graphical.waybar.barType` | Description |
|-------|-------------|
| `dualbar` | Top + bottom bars, all modules always visible |
| `monobar` (default) | Single top bar; conditional modules hide below threshold |

### Secrets Management

Hydrix uses [sops](https://github.com/getsops/sops) with age encryption and **one key**: the repo's master key. Every secret is encrypted to it and nothing else, on every machine. Its private half is committed as `secrets/master-age-key.age`, encrypted with a passphrase, and unlocked onto the host at `/var/lib/sops-nix/master-age-key.txt` (outside the Nix store, survives rebuilds). It never leaves the host: VMs only receive decrypted files. There are no per-machine keys and no fallback: until the master key is unlocked, decrypt services warn and VMs start without secrets.

```
secrets/
├── .sops.yaml               # one creation rule, one recipient: the master public key
├── master-age-key.age       # the master key, passphrase-encrypted (safe to commit)
├── wifi.yaml                # WiFi credentials (encrypted)
└── github.yaml              # GitHub SSH key (encrypted)
```

#### `hydrix-sops-setup`

| Command | Purpose |
|---|---|
| `hydrix-sops-setup` | Fresh repo: generate the master key, activate it, write `.sops.yaml`. Existing repo: check that the master key is unlocked and is the only recipient in `.sops.yaml` and every secret. |
| `hydrix-sops-setup --print-key` | Print the master public key. |
| `hydrix-sops-setup --unlock` | Decrypt the master key with its passphrase and activate it on this machine immediately, for sops-nix services and your own `sops` runs. No rebuild needed. |
| `hydrix-sops-setup --gen-master-key` | Generate the master key on a fresh repo (what bare `hydrix-sops-setup` does there). |
| `hydrix-sops-setup --rekey` | Make the master key the only recipient: rewrites `.sops.yaml` and runs `sops updatekeys` on every secret, then verifies each one. |
| `hydrix-sops-setup --enroll-fido2` | Enroll a FIDO2 hardware key (YubiKey, Titan, ...) for a future replacement of the master key. Does **not** add a recipient. |

The installers run all of this for you: a fresh install generates and activates the master key, an add-mode install or reinstall offers to unlock it. See [§ Installs and reinstalls](#installs-and-reinstalls).

#### Initial setup

```bash
# 1. In machines/<serial>.nix: hydrix.secrets.enable = true;
# 2. Generate the master key and .sops.yaml (asks for a passphrase)
hydrix-sops-setup
# 3. Commit them
git -C ~/hydrix-config add secrets/master-age-key.age secrets/.sops.yaml
# 4. Create secrets, then rebuild
sops secrets/wifi.yaml
```

The unlocked key is also installed as `~/.config/sops/age/keys.txt`, so plain `sops` commands work as your user.

#### Installs and reinstalls

- **Fresh `hydrix-config`**: the installer generates the master key, asks for its passphrase and activates it on the new machine directly.
- **Add-mode install or reinstall**: the installer offers to unlock the committed master key. Otherwise run `hydrix-sops-setup --unlock` after first boot.

#### Encrypting on another machine

Encryption only needs the master **public** key, so a secret can be encrypted on a machine that must never hold the private key (e.g. a work laptop the secret comes from):

```bash
# On the Hydrix host:
hydrix-sops-setup --print-key
# On the other machine, straight from the source file (no plaintext copy):
sops -e --age <master-pubkey> /path/to/source.json > name.json
# Move name.json (ciphertext) into secrets/, git add it, rebuild.
```

`sops` picks the output format from the input's extension; `.sops.yaml` covers both `.yaml` and `.json`.

#### Migrating a repo with extra recipients

Repos set up before the single-key model also list per-machine SSH-derived keys (and possibly personal or FIDO2 keys). On a machine with the master key unlocked:

```bash
hydrix-sops-setup            # reports any recipient other than the master key
hydrix-sops-setup --rekey    # master key only, in .sops.yaml and every secret
git -C ~/hydrix-config add secrets/ && git -C ~/hydrix-config commit -m 'chore(secrets): re-key to master key only'
```

Unlock the master key on **every** machine before it rebuilds with this module: activation removes any other active key, so a machine without it gets empty secrets. Re-keying does not affect copies in git history; old recipients can still open those versions.

#### Replacing the master key with FIDO2

`--enroll-fido2` stores the identity only. The swap itself is manual: make the FIDO2 key the only recipient in `.sops.yaml`, `sops updatekeys` every secret, remove `secrets/master-age-key.age`. Decrypt services run unattended at boot and a FIDO2 key needs a touch per decryption, so this needs its own design first.

#### Declaring secret files

```nix
hydrix.secrets = {
  enable = true;

  # Convenience shorthands
  githubSecretsFile = ../secrets/github.yaml;   # provisions ssh/ to declared VMs
  wifiSecretsFile   = ../secrets/wifi.yaml;     # provisions wifi/ to the router VM

  # Arbitrary secrets (generic files attrset)
  files.discord = {
    file  = ../secrets/discord.yaml;
    vmDir = "browser";                          # delivered to VM at /mnt/vm-secrets/browser/
    # No 'keys' = whole-file mode: decrypts discord.yaml as-is
  };
};

# Per-VM opt-in: only listed VMs receive each secret type (by VM name, resolved to this
# machine's VM).
hydrix.microvmHost.byName.browsing.secrets = [ "discord" ];
hydrix.microvmHost.byName.router.secrets   = [ "wifi" ];
```

The `github` secret is the exception: it is never listed per VM (that is a build error). With
`githubSecretsFile` set it goes to `hydrix.secrets.github.vms`, the git VM by default, the only
machine that pushes (see [repos.nix](#reposnix)).

Task slots get theirs from `secrets` in `tasks/default.nix` (applied with `mkDefault`, so a
per-slot `microvmHost.vms` entry still overrides it).

Each entry in `hydrix.secrets.files` auto-generates a `hydrix-sops-decrypt-<name>.service` on the host. Secrets are decrypted to `/run/secrets/<name>/` and provisioned to each VM's virtiofs share at `/run/hydrix-secrets/<vmname>/<vmDir>/`. Inside the VM they appear at `/mnt/vm-secrets/<vmDir>/`.

#### Per-key extraction mode

When `keys` is specified, individual YAML keys are extracted to separate files:

```nix
hydrix.secrets.files.github = {
  file  = ../secrets/github.yaml;
  vmDir = "ssh";
  keys  = {
    "id_ed25519"     = { outFile = "id_ed25519";     mode = "0600"; };
    "id_ed25519_pub" = { outFile = "id_ed25519.pub"; mode = "0644"; };
  };
};
```

#### Whole-file mode

When `keys` is omitted (or left empty), the entire sops file is decrypted as-is and written as a single file named after the attrset key. Use this for arbitrary credential formats:

```nix
hydrix.secrets.files.discord = {
  file  = ../secrets/discord.yaml;
  vmDir = "browser";
};
# Result inside VM: /mnt/vm-secrets/browser/discord.yaml (plaintext YAML)
```

#### Creating and editing secrets

```bash
# Create a new encrypted file (opens in $EDITOR, saves encrypted):
sops ~/hydrix-config/secrets/discord.yaml

# Edit an existing file:
sops ~/hydrix-config/secrets/github.yaml
```

#### Applying secret changes without a full rebuild

When the content of a secrets file changes (new network, updated password, etc.), restart the relevant host services instead of rebuilding:

```bash
sudo systemctl restart hydrix-sops-decrypt-wifi
sudo systemctl restart hydrix-secrets-microvm-router-<serial>
# The router VM sees the change immediately via virtiofs.
# If the VM has a consuming oneshot service, restart it too:
# (inside router VM) systemctl restart hydrix-wifi-from-sops
```

#### How secrets reach VMs

```
secrets/wifi.yaml (age-encrypted, git-tracked)
  |
  | hydrix-sops-decrypt-wifi.service (host, runs at boot)
  v
/run/secrets/wifi/networks.json (decrypted, tmpfs)
  |
  | hydrix-secrets-microvm-router-<serial>.service (host)
  v
/run/hydrix-secrets/microvm-router-<serial>/wifi/ (host, tmpfs)
  |
  | virtiofs (live passthrough)
  v
/mnt/vm-secrets/wifi/networks.json (inside the router VM only)
```

Other VMs have no access to `/mnt/vm-secrets/wifi/`; the pentest, browsing, and dev VMs only receive the secret types listed in their own `secrets = [...]` declaration.

#### Adding a new machine

Nothing per machine: run `hydrix-sops-setup --unlock` on it (the installers offer this during install). Until it is unlocked, decrypt services exit with a warning and VMs start without secrets.

#### Troubleshooting

**`sops: could not decrypt`**

The master key is not unlocked on this machine: run `hydrix-sops-setup --unlock`. If it is, `hydrix-sops-setup` reports any secret not encrypted to it.

**Secret not appearing in VM**

Check the host decrypt service:
```bash
journalctl -u hydrix-sops-decrypt-wifi
```

Check the provisioning service:
```bash
journalctl -u hydrix-secrets-microvm-router-<serial>
```

Check the virtiofs mount inside the VM:
```bash
ls /mnt/vm-secrets/
```

**`wifi-sync list` shows 0 networks after setup**

`secrets/wifi.yaml` may not be committed. Files referenced via `wifiSecretsFile` must be git-tracked (Nix copies them into the store at eval time):
```bash
git add secrets/wifi.yaml && git commit -m 'feat(secrets): add wifi credentials'
rebuild
```

### Disk Configuration (Disko)

```nix
{
  hydrix.disko = {
    enable = true;
    device = "/dev/nvme0n1";
    swapSize = "16G";
    layout = "full-disk-luks";      # or "full-disk-plain", "dual-boot-luks"
  };
}
```
### User Colorschemes



Custom colorschemes in your hydrix-config take priority over framework ones:
```nix
  hydrix.userColorschemesDir = ./colorschemes;  # Point to your colorschemes/
}
```
{

---

## Colorscheme System

Hydrix uses pywal-based colorschemes with real-time synchronization between the host and all running VMs. There are three independent color layers per VM, each controlling a different aspect of the visual environment.

### The Three Color Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  Layer 1: VM internal colorscheme                                   │
│  hydrix.colorscheme = "punk"                                        │
│  Drives pywal palette inside the VM: alacritty, wofi, GTK           │
│  This is the VM's own base theme, independent of the host.          │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 2: Host wal cache inheritance (virtiofs)                     │
│  hydrix.vmThemeSync.useHostWal = true   (default when enabled)      │
│  Host ~/.cache/wal shared read-only via virtiofs → /mnt/wal-cache   │
│  VM has its own isolated ~/.cache/wal copied from that mount.       │
│  REFRESH vsock signal pulls updated colors; writes stay in VM.      │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 3: Focus border color (host-side, compositor border)          │
│  focusBorder = "yellow"  ← set in profiles/<name>/meta.nix          │
│  The border color shown on the HOST when a VM window is focused.    │
│  Completely independent from the VM's internal colors.              │
└─────────────────────────────────────────────────────────────────────┘
```

### Layer 1 - VM Internal Colorscheme

Each VM has its own declarative colorscheme that drives pywal inside the VM:

```nix
# profiles/browsing/default.nix
hydrix.colorscheme = "hydrix";   # default colorscheme 
```

This scheme is used for the VM's own terminals, wofi, GTK, and any other pywal-aware apps running inside the VM. It acts as the base palette, which colors are actually applied depends on Layer 2.

**Available colorschemes** (located in `colorschemes/`):
- `hydrix` - Default teal/cyan
- `nord` - Nord blue

User-defined colorschemes in `hydrix-config/colorschemes/` take priority over framework ones with the same name.

### Layer 2 - Host Wal Cache via Virtiofs

With `vmThemeSync` enabled, VMs do not run pywal locally. Instead, the host's wal cache is shared read-only via virtiofs and copied into each VM's own isolated `~/.cache/wal` at boot. VM-side writes (e.g. `restore-colorscheme`, `wal-sync`) stay inside the VM and never reach the host.

```
Host                                      VM
~/.cache/wal/  (read-only virtiofs)       /mnt/wal-cache  (read-only mount)
  colors.json  ---- virtiofs ---->        │  copied at boot by wal-cache-link
  sequences                               ~/.cache/wal/  (isolated local copy)
  colors                                    colors.json
                                            sequences
                                            colors-runtime.toml (generated at boot)
                                            alacritty imports colors-runtime.toml

walrgb / randomwalrgb / restore-colorscheme (on host)
  -> pywal updates ~/.cache/wal/colors.json
  -> systemd path unit detects change
  -> sends REFRESH to VMs via vsock:14503
       VM handler (as root): cp /mnt/wal-cache/* ~/.cache/wal/
                              regenerates colors-runtime.toml (new terminals)
                              pushes sequences to all user /dev/pts/* (running terminals)
                              sudo -u user refresh-colors (pywalfox, swaync, xsetroot)

walrgb / wal-sync / restore-colorscheme (inside VM - fully contained)
  -> updates VM's own ~/.cache/wal/ only, never touches host
  -> refresh-colors: regenerates colors-runtime.toml
                     pushes sequences to all owned /dev/pts/*
                     updates pywalfox, swaync, xsetroot
```

This eliminates ~500ms color flash on VM startup, keeps all VMs in sync with the host wallpaper in real time, and ensures VM color changes are fully contained.

**`useHostWal`** (default: `true` when vmThemeSync is enabled) controls whether the VM reads from the host cache or its own. Setting it to `false` restores local pywal execution and makes the VM fully independent.

```nix
# opt out of host cache sharing for this VM
hydrix.vmThemeSync.useHostWal = false;
```

#### Apps Updated When Colors Change

Inside VMs (on REFRESH from host or after `walrgb`/`wal-sync` inside VM):
- **Alacritty**  all ANSI colors + cursor color (via `colors-runtime.toml`, triggers `live_config_reload`)
- **Running terminals**  ANSI palette + cursor updated immediately via OSC sequences pushed to all `/dev/pts/*`
- **Starship / fastfetch**  pick up updated ANSI palette in running terminals
- **GTK apps**  `gtk-wal.css` regenerated and re-imported (file pickers, virt-manager, etc.)
- **Zathura**  already-open windows updated live via D-Bus; new windows always open with current colors regardless
- **swaync**  notification colors (libvirt Hyprland VMs)
- **Firefox**  via pywalfox

On the host (after `walrgb` / `randomwalrgb` / `restore-colorscheme`):
- **compositor**  window borders
- **status bar**  all bar colors
- **Alacritty**  all ANSI colors + cursor color (via `colors-runtime.toml`)
- **Running terminals**  ANSI palette + cursor via sequences to all `/dev/pts/*`
- **GTK apps**  `gtk-wal.css` regenerated and re-imported
- **Zathura**  already-open windows updated live via D-Bus; new windows always open with current colors regardless
- **swaync**  notification colors and per-sender borders
- **Firefox**  via pywalfox extension
- **RGB lighting**  ASUS Aura / OpenRGB

See "Stylix (Opt-in Theming)" below for how this list changes if Stylix is enabled.

#### VM Color Commands

These commands are available inside every VM with `vmThemeSync` enabled:

| Command | Description |
|---------|-------------|
| `wal-sync` | Pull host's current colors into VM local cache and refresh |
| `restore-colorscheme` | Restore VM's own profile colorscheme (from `/etc/hydrix-colorscheme`) |
| `refresh-colors` | Regenerate `colors-runtime.toml` + push sequences to all open terminals |
| `write-alacritty-colors` | Regenerate `colors-runtime.toml` only (no sequence push) |
| `walrgb <image>` | Generate colors from image, apply fully within VM |

All VM color operations are fully contained, writes never reach the host's `~/.cache/wal`.

#### Fast Startup (No Color Flash)

Without theme sync, VMs show default colors for ~500ms while pywal runs. This is prevented by:

1. **wal-cache-link service**  copies host colors into VM's local `~/.cache/wal` before apps start, so colors exist from the first shell
2. **Pre-generated `colors-runtime.toml`**  built at VM boot from the copied `colors.json` via jq; available before any terminal opens
3. **Stylix fish target disabled**  if Stylix is enabled at all (opt-in, see below), its fish target is disabled by default so it can't override colors with OSC escape sequences on every shell start
4. **Conflicting services disabled**  `vm-colorscheme`, `wal-sync` timer, and `init-wal-cache` are disabled so they cannot overwrite the VM's local cache

#### Wal Cache Pre-population (Cold Start)

On first boot the host has no wal cache yet. The `wal-cache-init` service solves this:

1. Checks if `~/.cache/wal/colors.json` exists  skips if already populated
2. If `graphical.wallpaper` is set, runs `wal -q -i <wallpaper>` to generate it
3. Otherwise falls back to the configured `colorscheme` JSON file

Without this, the virtiofs mount would be empty on first boot and VMs would have no colors to copy until the user runs `walrgb`.

#### Host Commands

| Command | Description |
|---------|-------------|
| `walrgb <image>` | Generate and apply colors from image |
| `randomwal` | Random wallpaper from ~/Pictures/wallpapers |
| `restore-colorscheme` | Revert to configured colorscheme |
| `refresh-colors` | Reload all apps with current colors |
| `save-colorscheme <name>` | Save current colors as new scheme |

---

### Layer 3 - Focus Border Color

The focus border is the window border color shown **on the host** when a VM application window is focused. It is entirely independent from what colors the VM uses internally, you can have a VM running `nord` internally while its host-side border is bright orange.

#### Priority Chain

The focus daemon resolves the border color using this priority order:

```
1. focusBorder (named color or hex, set in VM profile)   <- always wins if set
2. focusOverrideColor (hex, legacy <- only when hydrix-focus on)
3. focus daemon mode:
     static  <- reads color4 from VM's colorscheme JSON
     dynamic <- reads a configurable key from the host's live wal cache
```

#### `focusBorder` - Primary Option

Set a fixed border color per VM profile in **`meta.nix`** (not `default.nix`):

```nix
# profiles/browsing/meta.nix
{
  vsockCid    = 103;
  bridge      = "br-browse";
  tapId       = "mv-browse";
  routerTap   = "mv-router-brow";
  subnet      = "192.168.103";
  workspace   = 3;
  label       = "BROWSING";
  focusBorder = "yellow";        # ← here
}
```

Accepts named colors or hex: `focusBorder = "#FF5555";`

Named colors: `red`, `orange`, `yellow`, `green`, `cyan`, `blue`, `purple`, `pink`, `magenta`, `white`, `black`, `gray`

**Why `meta.nix` and not `default.nix`?** The host flake reads `focusBorder` at evaluation time to populate `vmRegistry` (→ `/etc/hydrix/vm-registry.json`). `meta.nix` is a plain Nix attrset with zero evaluation cost. Reading it from `hydrix.vmThemeSync.focusBorder` in `default.nix` would force full NixOS evaluation of every VM config during every host rebuild, which causes OOM on systems with limited RAM.

The `hydrix.vmThemeSync.focusBorder` option in `default.nix` still exists and is read by the Python focus daemons at runtime, keep it in sync with `meta.nix`.

When `focusBorder` is set, it is always active and bypasses both the static/dynamic daemon modes and the `hydrix-focus` override toggle entirely.

#### Focus Daemon Modes (fallback when `focusBorder` is unset)

| Mode | Color Source | Use Case |
|------|-------------|----------|
| `static` | VM profile's colorscheme JSON (`color4`) | Fixed tones per VM, shifts only when colorscheme changes |
| `dynamic` | Host's live wal cache (configurable color key) | Border shifts with every wallpaper change |

**Default dynamic color map:**

| VM Type | Color Key | Typical result |
|---------|-----------|----------------|
| pentest | color1 | Red tones |
| browsing | color2 | Green tones |
| comms | color3 | Yellow tones |
| dev | color5 | Magenta tones |
| lurking | color6 | Cyan tones |

Override in your machine config:
```nix
hydrix.vmThemeSync = {
  enable = true;
  focusDaemon.mode = "dynamic";
  dynamicColorMap = {
    pentest = "color1";
    browsing = "color4";
  };
};
```

**Window detection:** The daemon identifies VM windows by title prefix `[<vmtype>]` (e.g., `[browsing] firefox`).

#### `focusOverrideColor` - Legacy Option

Hex-only predecessor to `focusBorder`. Only active when `hydrix-focus on` is toggled:

```nix
# profiles/pentest/default.nix
hydrix.vmThemeSync.focusOverrideColor = "#FF5555";
```

| Command | Effect |
|---------|--------|
| `hydrix-focus on` | Enable override colors |
| `hydrix-focus off` | Revert to static/dynamic mode |
| `hydrix-focus toggle` | Toggle (default action) |
| `hydrix-focus status` | Show current state |

Prefer `focusBorder` for new profiles - it is simpler, always active, and supports named colors.

#### Enabling

In your machine config:
```nix
hydrix.vmThemeSync.enable = true;
hydrix.vmThemeSync.focusDaemon.mode = "dynamic";
```

Import `vmThemeSyncModule` in your flake for both the host and all VMs.

---

## Stylix (Opt-in Theming)

Stylix is **not** a Hydrix input by default. Fonts, console (TTY) colors, and
wallpaper are handled natively (`theming/graphical/native-theme.nix`); GTK, zathura,
alacritty, firefox, and fish are themed at runtime by the wal pipeline described
above. None of that requires Stylix. It's available purely as an opt-in for users who
want its much broader auto-theming reach (arbitrary terminals, browsers, and other
apps Hydrix has no curated wiring for).

### Enabling

Stylix follows the same "consumer-supplied, purely optional" pattern as
`nix-index-database`/`disko`: it isn't declared anywhere in Hydrix's own `flake.nix`,
so it costs nothing (not even a `flake.lock` entry) unless *your* flake supplies it.

```nix
# In your flake.nix inputs:
stylix.url = "github:danth/stylix/release-26.05";
stylix.inputs.nixpkgs.follows = "nixpkgs";
hydrix.inputs.stylix.follows = "stylix";

# Then pass it through extraInputs on your mkHost/mkMicroVM calls, same as
# disko/nix-index-database:
extraInputs = { inherit stylix; /* ...disko, nix-index-database, etc. */ };
```

`hydrix.lib.mkHost`/`mkVM`/`mkMicroVM` detect its presence (`allInputs ? stylix`) and
load `stylix.nixosModules.stylix` plus Hydrix's own `theming/graphical/stylix.nix`
automatically. Every consumer of `hasStylix` (a `specialArgs` value, not a
`hydrix.*` option) treats its absence as the default, zero-footprint state.

### Two Tiers

Both require the `stylix` input to be present at all -- neither does anything on its
own otherwise.

```nix
hydrix.graphical.stylix.autoTheme = true;   # default once Stylix is opted in
hydrix.graphical.stylix.exclusive = false;  # default
```

- **`autoTheme`** (default `true`): sets `stylix.autoEnable`, letting Stylix theme
  any program it recognizes that Hydrix has no curated wiring for -- a new terminal,
  a new browser, whatever. Set `false` to fall back to Stylix's own curated target
  whitelist only (`theming/graphical/stylix.nix`'s `stylix.targets`/HM `targets`
  blocks).
- **`exclusive`** (default `false`): hands GTK, zathura, alacritty, and fish over to
  Stylix too, instead of Hydrix's own wal-based theming for those four. This is an
  all-or-nothing switch, not a priority nudge -- for GTK and zathura specifically,
  Hydrix's wal theming isn't just a competing `mkForce`, it's an active delivery
  mechanism (a CSS `@import`, a binary wrapper) that would keep overriding Stylix even
  with its own `mkForce false` lifted. `exclusive` disables those mechanisms too, not
  just the force-disable. Firefox is unaffected either way -- its Stylix target has
  always been enabled by default, coexisting with the pywalfox extension.

### Per-App Handoff (what `exclusive` actually changes)

| App | Normal (curated/autoTheme) | Under `exclusive = true` |
|---|---|---|
| GTK | wal-owned: `gtk-wal.css` generated by `generate-gtk-colors`, imported via `gtk3.extraCss`/`gtk-4.0/gtk.css`. Stylix's GTK target force-disabled. | Hydrix's CSS import and color-generator script are **not installed at all**. Stylix's GTK target runs normally. |
| Zathura | wal-owned: `zathura` is wrapped (`theming/programs/zathura.nix`) -- every launch builds a temp `--config-dir` with fresh wal colors; open windows get pushed live updates via D-Bus. Stylix's zathura target force-disabled. | Plain unwrapped `pkgs.zathura` is installed instead. Stylix's zathura target manages `~/.config/zathura/zathurarc` itself. `hydrix.graphical.zathura.*` (recolor, padding, scroll/zoom, sandbox, mappings, `extraConfig`) **stops applying** -- those only exist inside the wrapper. |
| Alacritty | wal-owned: colors come from `colors-runtime.toml` (`write-alacritty-colors`, pushed on `walrgb`/vsock). Stylix's alacritty target disabled. | Stylix's alacritty target enabled instead. |
| Fish | System-level Stylix fish target disabled (only relevant in VMs with `vmThemeSync.useHostWal`) to avoid an OSC-sequence race with alacritty's `colors-runtime.toml` import. | Re-enabled -- no longer racing anything, since alacritty is Stylix-owned too in this mode. |

### The Build-Time Caveat

Whichever tier you pick, **Stylix only themes at rebuild time.** It bakes in whatever
`hydrix.graphical.colorscheme`/wallpaper resolves to when the system builds --
`stylix.base16Scheme` is fed from the exact same colorscheme-resolution pipeline
(`theming/lib.nix`: base16 YAML lookup, pywal JSON conversion, vmType fallback) that
everything else uses, so it's not a second/disconnected palette. But Stylix never
plugs into the live `walrgb`/`refresh-colors` runtime path. A new app it covers won't
recolor live when you run `walrgb <wallpaper>`; it needs a rebuild. The wal-owned apps
(GTK, zathura, alacritty, firefox, swaync, waybar, console) always update live
regardless of any of this.

---

## Notifications

Popups and the notification panel are swaync (`theming/programs/swaync.nix`), enabled with the
Hyprland stack (`hydrix.hyprland.enable`), so microVMs never run a daemon. `$mod+Shift+N`
(`swaync-client -t`) opens the panel: history, clear, do not disturb.

- **Placement:** top-right. X = `ui.gaps + notifications.offset` from the screen edge, Y =
  `notifications.offset` under the bar's exclusive zone, the same clearance past a tiled
  window's edge on both axes. `offsetCompensation.{x,y}` fixes per-machine fractional-scale
  rounding, tuned by editing the `.notification-background` padding in
  `~/.config/swaync/style.css` and running `swaync-client -rs`.
- **Look:** corners use `scaling.computed.panelRadius` like eww and wofi, the drop shadow
  comes from `ui.shadow`, the fill uses `ui.opacity.overlay` (or `overlayOverrides.notifications`).
  Text only (no images or app icons), in the system font at the px equivalent of the eww and
  alacritty size (`font.size * relations.notifications * 4/3`, waybar's 14px at 11pt). The
  service runs with `GSK_RENDERER=cairo`: GTK4's default renderer draws text heavier than the
  GTK3 surfaces around it.
- **Borders follow the sender**, with the same gradients as windows: the host gradient
  (`focusDaemon.hostColor` to `baseColor`) by default, and a VM's own gradient (its
  `focusBorder`, or its `dynamicColorMap` color with `hydrix-focus` on) for notifications the
  relay tags `hydrix-vm-<vm>`. Both use `theming/wm/hyprland/border-colors.nix`, the shell
  library `hypr-focus-daemon` also sources. swaync is patched
  (`swaync-category-class.patch`) to add a `category-<category>` CSS class to each card,
  since stock swaync has no per-notification style hook.
- **Rounded gradient ring:** GTK draws `border-image` with square corners, and a gradient
  under a translucent fill would show through it. The ring is therefore four edge strips in
  the card's background (backgrounds follow `border-radius`), each fading toward the far
  corner, around a fill clipped to the padding box.

Files in `~/.config/swaync`: `config.json` and `style.css` are written on every rebuild and
can be hand-edited in between (`swaync-client -R` / `-rs`); `colors.css` is written by
`swaync-apply-colors` on rebuild, colorscheme changes (`refresh-colors`) and `hydrix-focus`
toggles, so it must never carry hand edits.

---

## Font System

Fonts are configured via `hydrix.graphical.font` and flow through two separate pipelines for host and VMs.

### Configuration

```nix
{
  hydrix.graphical.font = {
    family = "Iosevka";              # Global font family
    size = 10;                        # Base size at 96 DPI
    relations = {                     # Per-app size multipliers
      alacritty = 1.0;
      waybar = 1.0;
      wofi = 1.2;
      notifications = 0.9;
    };
  };
}
```

### Host Font Pipeline

Hyprland handles DPI scaling natively per-monitor (fractional compositor scale), so
Alacritty and other apps read their font size directly from the Nix-generated
`alacritty.toml` (home-manager, `theming/programs/alacritty.nix`, build-time) with no
runtime DPI wrapper needed. That file sets `font.size` from `hydrix.graphical.font`
directly, but deliberately leaves `font.normal.family` unset -- alacritty resolves it
via fontconfig's `monospace` alias instead, which `theming/graphical/native-theme.nix`
points at `hydrix.graphical.font.family` (see "Stylix (Opt-in Theming)" above for why
this indirection exists and what changes if Stylix is enabled). Firefox is the one app
that still needs a runtime wrapper (`firefox-dpi`), because Firefox's own scaling
doesn't follow the compositor scale automatically - it reads the scale via
`hyprctl monitors` at launch time (see `theming/programs/firefox.nix`).

### VM Font Pipeline

VMs use their own `alacritty.toml` directly - no wrapper overrides:

1. home-manager generates `alacritty.toml` with font size from `hydrix.graphical.font`; family resolves via the fontconfig `monospace` alias, same as the host
2. Apps are launched inside the VM via `hypr-ws-app` / waypipe
3. Alacritty reads its own config with the correct font

### Updating Fonts

| Action | Host | VMs |
|--------|------|-----|
| Change `font.family` | `rebuild` | `rebuild` + `shard switch <vm>` |
| Change `font.size` | `rebuild` | `rebuild` + `shard switch <vm>` |
| DPI change (new monitor) | Automatic via Hyprland's per-monitor scale | N/A (waypipe forwards the rendered window) |

Font packages must be included in the VM's closure. Add them to `vmPackages` in your font config:

```nix
vmPackages = with pkgs; [ iosevka tamzen scientifica gohufont ];
```

### Adding Custom Font Profiles

Font profiles live in `~/hydrix-config/fonts/`. Each profile sets per-app sizes, relations, and overrides that activate when `hydrix.graphical.font.family` matches. To add a new font:

1. Create `fonts/myfont.nix` using an existing profile as a template (e.g. `fonts/iosevka.nix`)
2. Import it in `fonts/default.nix` and add the family → profile mapping:
   ```nix
   imports = [ ./iosevka.nix ./tamzen.nix ./myfont.nix ];
   config.hydrix.graphical.font.profileMap = {
     "MyFont" = "myfont";
     # ...
   };
   ```
3. Add the package to `modules/fonts.nix` under `packages` and `packageMap`
4. Set `hydrix.graphical.font.family = "MyFont"` in your machine config

The profile activates automatically, no other wiring needed.

### Live Switch (shard switch)

`shard switch` performs a live config switch that includes home-manager activation. This means font changes in `alacritty.toml` are applied without VM restart. The host dumps nix store registration info to the VM before switching so home-manager can realise new store paths.

New terminal windows pick up the updated font. Already-running terminals keep their current font (alacritty inotify doesn't detect nix store symlink changes).

---

## MicroVM Management

### Commands

The `shard` CLI. Lifecycle operations work as either a word or a same-letter
flag; flags combine and run in the order given (`shard -bs browsing` builds
then starts). Every other command is word-only.

```bash
# Lifecycle (flag | word, both always work)
shard -b <name>            | shard build <name>       # Build/rebuild VM image
shard -s <name>            | shard start <name>        # Start VM (polls PING→OK, then starts the waypipe tunnel)
shard -S <name>            | shard stop <name>         # Stop VM
shard -R <name>            | shard restart <name>      # Restart VM
shard -r <name>            | shard rebuild <name>      # Build + live switch (no restart)
shard -w <name> [path]     | shard switch <name> [path] # Live switch to (already-)built config
shard -W <name>            | shard switch-status <name> # Show live vs built configuration paths

# Applications (just press Super+Return on the VM workspace)
shard -a <name> <cmd>      | shard app <name> <cmd>    # Launch app in VM via waypipe
shard -c <name>            | shard console <name>      # Serial console (headless VMs)

# Status
shard -i [name]            | shard status [name]       # Show status
shard list                                             # List all VMs
shard -l <name>            | shard logs <name>         # View logs

# Data Management
shard snapshot create <name> <snap>  # Create snapshot
shard snapshot list <name>           # List snapshots
shard snapshot revert <name> <snap>  # Revert to snapshot
shard -p <name>            | shard purge <name>        # Delete all data (fresh start)
shard gc                                               # List/delete orphaned VM directories (see below)

# Encrypted home volume
shard encrypt-setup <name>           # Manual pre-provision (build auto-sets this up if enabled)
shard -s <name>            | shard start <name>        # Prompts for passphrase, then starts normally
shard -S <name>            | shard stop <name>         # Stops VM and locks volume automatically
```

### Cleaning Up Orphaned VM Directories (`shard gc`)

`/var/lib/microvms/<name>/` directories are never deleted automatically - renaming a
profile, removing one from `hydrix-config/profiles/`, or one-off test VMs all leave
behind a directory with no corresponding `nixosConfiguration` anymore. `shard gc`
finds and (with confirmation) removes them:

```bash
shard gc          # Dry-run: lists orphaned directories with size + last-modified date
shard gc --force  # Skip the confirmation prompt
```

**How it decides what's orphaned:** it evaluates `nix eval .#nixosConfigurations
--apply builtins.attrNames` (cheap - just enumerates flake output keys, no build) and
diffs that against `ls /var/lib/microvms/`. Any directory whose name isn't a currently
declared VM is flagged. This means removing a profile's directory under
`hydrix-config/profiles/<name>/` and rebuilding is enough - its old
`/var/lib/microvms/microvm-<name>-<serial>/` state is automatically caught on the next
`shard gc` run, with no manual bookkeeping needed.

Deliberately **on-demand only** - no timer, not part of `rebuild` - the same reasoning
`shard purge` already follows: VM data shouldn't disappear without a human explicitly
asking. It will stop a matching VM first if one happens to still be running under an
orphaned name before removing its directory.

### Encrypted Home Volumes

Persistent home volumes can be LUKS-encrypted so data is locked at rest whenever the VM is not running. The passphrase is prompted as part of `shard start`, no separate unlock step needed.

**How it works:**

- `shard encrypt-setup` creates a raw LUKS2 container (`home.luks`) in `/var/lib/microvms/<name>/`
- `shard start` runs `cryptsetup luksOpen` before QEMU starts, presenting `/dev/mapper/vm-<name>-home` to the VM
- `shard stop` runs `cryptsetup luksClose` after the VM halts - data is locked immediately
- If the host is powered off mid-session, the container is locked automatically on reboot (the mapper device never persists across boots)

**Enabling encryption for a VM:**

```bash
# 1. Stop the VM if running
shard stop pentest

# 2. Create the LUKS container (prompts for passphrase, formats ext4 inside)
shard encrypt-setup pentest

# 3. Enable in your VM profile (hydrix-config/profiles/pentest/default.nix):
#    hydrix.microvm.encryption.enable = true;

# 4. Rebuild to point the VM at the encrypted volume
shard build pentest

# 5. Start - passphrase prompt appears before QEMU launches
shard start pentest
```

**Notes:**

- Any existing `home.qcow2` is **not** migrated - it remains on disk and can be mounted manually for data recovery (see below), then deleted once you've confirmed the encrypted volume is working
- Snapshots (`shard snapshot`) do not apply to encrypted volumes - use a filesystem-level backup of `home.luks` while the mapper is closed instead
- On **btrfs** hosts: disable copy-on-write on the container file to prevent fragmentation: `sudo chattr +C /var/lib/microvms/<name>/home.luks` (must be set before first write)

**Recovering data from the old qcow2:**

```bash
sudo modprobe nbd
sudo qemu-nbd --connect=/dev/nbd0 /var/lib/microvms/<name>/home.qcow2
sudo mount /dev/nbd0 /mnt
# copy files as needed
sudo umount /mnt
sudo qemu-nbd --disconnect /dev/nbd0
```

### Profile VMs

Declared in `hydrix-config/profiles/<name>/meta.nix`, auto-discovered by the flake, tracked in `/etc/hydrix/vm-registry.json`. All values are user-configurable.

**Convention: CID = subnet last octet = workspace.**

| Name | CID | WS | Bridge | Subnet | Persistence |
|------|-----|----|--------|--------|-------------|
| `pentest` | 102 | 2 | br-pentest | 192.168.102 | persistent, LUKS-encrypted |
| `browsing` | 103 | 3 | br-browse | 192.168.103 | 10GB home |
| `comms` | 104 | 4 | br-comms | 192.168.104 | persistent |
| `dev` | 105 | 5 | br-dev | 192.168.105 | 50GB + 20GB docker |
| `lurking` | 106 | 6 | br-lurking | 192.168.106 | Ephemeral |

Each is actually its own per-machine `microvm-<name>-<serial>` nixosConfiguration - see
[§ VM Naming and Machine Identity](#vm-naming-and-machine-identity).

Custom profiles start at CID 107+. Use `new-profile <name>` to scaffold one.

**Adding a new profile VM:**

```bash
# Scaffold new profile (auto-discovers next free CID/workspace)
new-profile myprofile

# Creates:
#   profiles/myprofile/meta.nix     # CID, bridge, subnet, workspace, label, focusBorder
#   profiles/myprofile/default.nix  # NixOS config (imports, resources, colorscheme)
#   profiles/myprofile/packages.nix # Package declarations
# Also runs: git add profiles/myprofile/
```

The flake auto-discovers any profile directory that contains `meta.nix` - no manual wiring in `flake.nix` required.

**Then complete the integration manually:**

1. Declare the VM in `machines/<serial>.nix` (optional - only needed to change a default
   like autostart/secrets/encryption; the VM builds and runs with no entry here at all):
```nix
hydrix.microvmHost.byName.myprofile = { autostart = false; };
```

2. Customise `profiles/myprofile/default.nix` - set colorscheme, RAM/vCPUs, packages.

   Optionally set a custom hostname (what you see at the shell prompt inside the VM).
   The default is the profile name suffixed with `-vm` (e.g. `myprofile-vm`).
   This only affects the internal hostname - host scripts, window titles, and storage paths
   always use the nixosConfiguration key, which is per-machine
   (`microvm-myprofile-<serial>`, see
   [§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)):

   ```nix
   hydrix.vm.hostname = "my-custom-name";
   ```

3. If the profile needs a Mullvad VPN tunnel, add to `machines/<serial>.nix` (or `modules/graphical.nix`):
```nix
hydrix.router.vpn.mullvad.bridges.myprofile = ./mullvad-myprofile.conf;
```

4. Rebuild in order - router and files VM have their TAP interfaces baked into the QEMU runner at build time, so they need a full restart to pick up the new bridge:
```bash
rebuild                       # host: creates br-myprofile, updates tapLookupScript + vm-registry
shard rebuild router files      # router picks up new subnet TAP; files VM picks up new bridge leg
shard build myprofile
shard start myprofile
```

**What is auto-wired after `rebuild`** (no manual action needed):
- `br-myprofile` bridge created and firewall-trusted
- Router gets a TAP and dnsmasq entry for the new subnet (from `routerTap` in meta.nix)
- TAP→bridge mapping in `tapLookupScript` (the `mv-myprofile*` glob covers all TAPs)
- `vm-registry.json` updated at activation (workspace, CID, subnet \- the status bar and focus daemon read from there)
- `hydrix-switch` and `router-status` include the new bridge

### Infrastructure VMs

Infrastructure VMs fall into two categories:

**Framework-fixed** - defined in Hydrix modules, reserved CIDs, not in `profiles/`. Do not assign these CIDs to profile or user infra VMs.

| Name | CID | Purpose |
|------|-----|---------|
| `microvm-router` | 200 | WiFi VFIO passthrough |
| `microvm-router-stable` | 201 | Break-glass fallback router |
| `microvm-builder` | 210 | Lockdown-mode nix builds |

**Template-based** - declared in `hydrix-config/infra/<name>/`, auto-discovered by the flake. Hydrix provides a starting template; the user owns the config. Reserved CIDs: do not reuse these for profile or custom infra VMs.

| Name | CID | Purpose |
|------|-----|---------|
| `microvm-usb-sandbox` | 209 | Safe USB storage handling |
| `microvm-gitsync` | 211 | Lockdown-mode git push/pull |
| `microvm-files` | 212 | Encrypted inter-VM file transfer |
| `microvm-vault` | 213 | Offline KeePassXC password database (`hydrix.passwords`) |
| `microvm-hostsync` | 214 | Secure host file inbox/outbox via virtiofs |

### Tor Hardening (lurking profile example)

The `tor-hardening.nix` module provides Tor anonymity hardening for VMs. Import it in your VM profile and configure:

```nix
# profiles/lurking/packages.nix
{ config, lib, pkgs, ... }: let meta = import ./meta.nix; in {
  imports = [
    ../../modules/tor-hardening.nix  # Tor hardening module
  ];

  hydrix.tor.hardening = {
    enable = true;
    level = "moderate";              # minimal | moderate | paranoid
    bridgeType = "obfs4";            # none | obfs4 | meek-azure | snowflake

    # Get bridges: email getobfs4bridges@torproject.org with body "obfs4"
    customBridges = ''
      Bridge obfs4 1.2.3.4:443 0000000000000000000000000000000000000000 iat-mode=0
    '';
  };

  services.tor = {
    enable = true;
    client = {
      enable = true;
      socksPort = 9050;
    };
  };
}
```

**Features:**
- **Pluggable bridges** - obfs4, meek-azure, snowflake for bypassing censorship
- **Three privacy levels** - minimal/moderate/paranoid trade-offs
- **Firefox hardening** - disables telemetry and fingerprinting
- **No-swap enforcement** - prevents memory forensics via hibernation
- **Bridge helper** - `fetch-tor-bridges` command to get bridges from torproject.org

**Adding a new user infra VM** (no `~/Hydrix` changes needed):

1. Create `infra/<name>/meta.nix`:
```nix
{
  vsockCid = 214;               # unique - avoid reserved CIDs above
  subnet   = "192.168.214";    # unique /24 prefix
  tapId    = "mv-myinfra";
  tapMac   = "02:00:00:02:xx:01";  # unique; 06/07 role bytes are the routers' (see Router NIC table)
  tapBridges = { "mv-myinfra" = "br-myinfra"; };
  # routerTap = "mv-router-myinfra";  # add if the VM needs internet via the router
}
```

2. Create `infra/<name>/default.nix` - standard NixOS module; `mkInfraVm` provides the headless base.

3. Declare in `machines/<serial>.nix`:
```nix
hydrix.microvmHost.byName.myinfra = { enable = true; };
```

4. Rebuild and start:
```bash
rebuild                              # creates bridge, configures TAP wiring, writes registry
shard rebuild router                   # only needed if routerTap was declared
shard build microvm-myinfra
shard start microvm-myinfra
```

If `routerTap` is set, the flake feeds it into `extraNetworks`, which automatically wires a router TAP and routes that subnet - no changes to router config required. If omitted, the VM is isolated and only reachable from other VMs sharing its bridge (like usb-sandbox).

### TUI Launcher

```bash
hydrix-tui              # Interactive TUI for VM management
# Or press Mod+m for the launcher
```

The TUI's MicroVM menu includes task slots. Task slots display their bound engagement name and offer a **Snapshots** sub-menu when stopped.

### Task Slots (per-engagement VMs)

For work that benefits from isolation per target or engagement, Hydrix supports **task slots**: a pool of generic VMs, built once, that named engagements are bound to at runtime without a host rebuild.

**How it works:**
- All slots come from one block in `hydrix-config/tasks/default.nix`, expanded by `tasks/slots.nix` (imported by both `flake.nix` and the files VM). Slot N gets CID = subnet last octet = `baseCid + N - 1`. Like every other profile/task VM, each slot is a per-machine `microvm-<profile>-task<N>-<serial>` nixosConfiguration (see [§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)); use the short `taskN` form, it always resolves correctly.
- Every slot is its own network: bridge `br-taskN`, subnet `192.168.<cid>.0/24`, router TAP `mv-router-taskN`, passed to the host and both routers as `extraNetworks`. The router's auto-generated inter-bridge drop rules therefore isolate each slot from every other VM network, including the other slots and the base profile VM.
- An engagement is only a name bound to a slot. Bindings live in `~/.local/share/hydrix/engagements.json` and archived volumes in `/var/lib/microvms/.engagements/<name>/`, both outside the flake, so engagement names never reach git or the nix store.

**Declaring slots** (`hydrix-config/tasks/default.nix`):

```nix
{
  count = 3;           # task1..task3, max 9 (TAP glob mv-taskN* and the 15-char interface limit)
  baseCid = 115;       # task1 = 115, task2 = 116, task3 = 117
  profile = "pentest"; # base profile every slot builds on; workspace and border follow it
  secrets = [];        # hydrix secrets delivered to every slot, e.g. ["burp"]
  module = {lib, ...}: {           # applied to every slot
    hydrix.microvm.persistence.homeSize = 20480;
    hydrix.microvm.encryption.enable = true;
    # hydrix.vm.hostname = lib.mkForce "Win-aabbcc1122";  # mkForce: pentest sets it plainly
  };
  overrides = {};      # per-slot additions, e.g. task2 = {hydrix.microvm.persistence.homeSize = 51200;};
}
```

Changing `count` or `baseCid` needs `rebuild` (bridges, registry), then `shard -bR router files` (new subnets and TAPs), then `shard -b taskN` for new slots. To give slots VPN egress, add their `br-taskN` bridges to the router's Mullvad bridge map.

**Engagement workflow:**

```bash
shard pentest task1 google        # bind 'google' to slot 1 (no rebuild)
shard pentest google              # or: first free slot (long form: shard pentest start google --slot 1)
shard -b google                   # build; the first build sets up the encrypted volume
shard -s google                   # the engagement name works anywhere a VM name does
shard -a google alacritty

shard pentest end google          # stop, archive the volume, free the slot
shard pentest task2 google        # resume the archived data into any free slot
shard pentest purge google        # delete an engagement's data, active or archived
shard pentest list                # slots, bindings, archived engagements
```

`end` moves the slot's home volume (qcow2, with its snapshots, or LUKS container) into the archive, so the slot starts empty for the next engagement. Binding refuses a slot that still holds an unbound volume: `--adopt` binds that volume to the new engagement instead, `shard -p taskN` deletes it. Engagement names are lowercase letters, digits, `-` and `_`, and cannot shadow a VM name or `shard pentest` subcommand.

**Task slot table** (defaults):

| Slot | Real per-machine name | CID | TAP | Bridge | Subnet |
|------|-----------------------|-----|-----|--------|--------|
| `task1` | `microvm-pentest-task1-<serial>` | 115 | `mv-task1` | `br-task1` | 192.168.115 |
| `task2` | `microvm-pentest-task2-<serial>` | 116 | `mv-task2` | `br-task2` | 192.168.116 |
| `task3` | `microvm-pentest-task3-<serial>` | 117 | `mv-task3` | `br-task3` | 192.168.117 |

**When libvirt is better:**
- Engagement needs elastic disk beyond the fixed qcow2 max size
- Lab environment (Windows, Active Directory, multi-machine networks)
- RAM snapshots (suspended mid-session state)

### Files VM (Encrypted Inter-VM Transfer)

The files VM (`microvm-files`, CID 212, fixed infra) is an encrypted jump host for moving files between VMs. It has direct L2 TAP connections to each bridge you grant it access to, so it can reach VMs without going through the router. Source and destination IPs are derived at runtime from the VM registry (`subnet + .10`).

**Security model:**

- File content is **always encrypted** (AES-256-CBC via openssl) before it leaves the source VM
- A random passphrase is generated fresh per transfer on the host and held only in host memory
- The passphrase travels **exclusively via vsock** - it never touches a bridge network
- SHA-256 is verified at every hop; the passphrase is only released to the destination after all checksums match
- Source files are never modified or moved - the original path is always preserved
- The files VM receives only ciphertext during transfer operations (it sees plaintext only during `store`, where it decrypts into its own `/storage`)
- Port 8888 on each VM only accepts connections from the files VM's IP (`.2` on that bridge), enforced by iptables on each VM

**Transfer flow** (`shard files transfer pentest/projects/report comms/pentest/`):

```
1. Host generates PASSPHRASE (openssl rand -base64 32), stays in host memory

2. Host -> pentest VM (vsock 14506): ENCRYPT <passphrase> projects/report
   Pentest VM: tar czf -> | openssl enc -aes-256-cbc -> ~/shared/xfer.enc
   Returns: SHA256=<hash>

3. Host -> pentest VM (vsock 14506): SERVE
   Pentest VM starts ephemeral HTTP server on port 8888

4. Host -> files VM (vsock 14505): FETCH <pentest-subnet>.10 xfer.enc
   Files VM downloads ciphertext via HTTP  (IP from vm-registry.json)
   Returns: SHA256=<hash>  <- host verifies both hashes match

5. Host -> pentest VM (vsock 14506): SERVE_STOP

6. Host -> comms VM (vsock 14506): RECEIVE_PREPARE
   Comms VM starts one-shot HTTP upload server on port 8888 (always receives to ~/shared/)

7. Host -> files VM (vsock 14505): DELIVER <comms-subnet>.10 xfer.enc
   Files VM HTTP PUTs ciphertext to comms VM  (IP from vm-registry.json)
   Returns: SHA256=<hash>  <- host verifies three-way match

8. Host -> comms VM (vsock 14506): DECRYPT <passphrase> shared/xfer.enc pentest/
   Comms VM decrypts + unpacks -> ~/pentest/report/, deletes shared/xfer.enc
   Returns: OK

9. Host -> pentest VM (vsock 14506): CLEANUP  (deletes ~/shared/xfer.enc)
   Host discards passphrase from memory
```

**Store flow** (`shard files store pentest/projects/report`):

Steps 1-4 are identical. After the files VM has the ciphertext, the host sends the passphrase via vsock and the files VM decrypts in-place into `/storage/pentest/`. Ciphertext is deleted after successful decryption.

**Setup** in `flake.nix`:

```nix
"microvm-files" = hydrix.lib.mkMicrovmFiles {
  # Bridges the files VM gets direct TAP access to.
  # Only listed VMs can exchange files with each other via this VM.
  accessFrom = [ "pentest" "browsing" "dev" "comms" ];
};
```

Enable in your machine config:

```nix
hydrix.microvmHost.byName.files.enable = true;
hydrix.microvmFiles.enable = true;
```

**Commands:**

```bash
# Move files between VMs (source files untouched)
shard files transfer pentest/projects/report comms/pentest/
shard files transfer dev/src/tool pentest/tools/

# Archive to files VM /storage/ (encrypted, then decrypted in-place)
shard files store pentest/projects/report

# List stored files
shard files list
shard files list pentest
```

**Network layout:**

```
Host (passphrase, orchestration)
 │  vsock 14505 → files VM (CID 212)
 │  vsock 14506 → any regular VM or usb-sandbox (ENCRYPT/SERVE/RECEIVE_PREPARE/DECRYPT/CLEANUP)
 │
Files VM (192.168.108.10 on br-files)
 ├── mv-files      → br-files       (192.168.108.10) [always]
 ├── mv-files-pent → br-pentest     (192.168.102.2)  [profile VMs, auto-discovered]
 ├── mv-files-brow → br-browse      (192.168.103.2)
 ├── mv-files-dev  → br-dev         (192.168.105.2)
 ├── mv-files-comm → br-comms       (192.168.104.2)
 ├── mv-files-lurk → br-lurking     (192.168.106.2)
 ├── mv-files-task1 → br-task1      (192.168.115.2)  [task slots, from tasks/slots.nix]
 ├── mv-files-usb  → br-usb-sandbox (192.168.209.2)  [usb-sandbox, explicit]
 └── mv-files-hsy  → br-hostsync    (192.168.214.2)  [hostsync, explicit]

Profile/infra VMs: static .10 IPs on their bridge
 port 8888: ephemeral HTTP server (serve or receive), files VM IP only
 vsock 14506: vm-files-agent (receives host ENCRYPT/SERVE/RECEIVE_PREPARE/DECRYPT/CLEANUP commands)
```

The files VM's TAP list is **auto-discovered** at build time from `infra/files/meta.nix`, which reads `profiles/*/meta.nix` and includes explicit entries for infra VMs like usb-sandbox and hostsync. Adding a new profile automatically adds a new TAP after rebuilding the files VM.

### Files VM - Implementation Details

Two cooperating agents handle all file operations:

**Files VM orchestrator** (`infra/files/default.nix`, vsock 14505) - multi-homed, one TAP per allowed profile. `ifaceMap` reads each profile's `meta.nix` at build time to derive the TAP name, MAC address, and subnet IP - fully dynamic for all profiles listed in `accessFrom`. Which VMs participate is the only hardcoded part:

```nix
# infra/files/default.nix
accessFrom = [ "pentest" "browsing" "dev" "comms" ];  # lurking intentionally excluded
```

Adding a new profile to `accessFrom` is sufficient - `ifaceMap` auto-derives the TAP name, MAC, and `.2` IP from that profile's `meta.nix`. No other changes needed.

**Per-VM agent** (`modules/vm/files-agent.nix`, vsock 14506) - runs inside every profile VM. Handles `ENCRYPT`, `DECRYPT`, `SERVE`, `RECEIVE_PREPARE`, `CLEANUP` on behalf of the host. Opens port 8888 exclusively to the files VM's `.2` address on the VM's own bridge subnet - that address is derived from `vmSubnet` in the VM's config, which itself comes from `meta.nix`. No hardcoded IPs anywhere in the per-VM agent.

**What is dynamic vs explicit:**

| Thing | How it's determined |
|-------|-------------------|
| Which VMs participate | Explicit in `accessFrom` in `infra/files/default.nix` |
| TAP names, MACs, IPs for those VMs | Fully dynamic - derived from each profile's `meta.nix` at build time |
| Bridge attachment (`tapBridges`) | Auto-derived from `accessFrom` profiles |
| Port 8888 firewall rule (per VM) | Dynamic - uses `vmSubnet` from that VM's own config, traced back to `meta.nix` |

Traffic between the files VM and profile VMs never touches the router. The files VM reaches each profile VM directly over the shared bridge via its dedicated per-bridge TAP.

### Hostsync VM (Host File Inbox)

`microvm-hostsync` (CID 214) is a minimal infra VM that bridges the encrypted file transfer system to the host filesystem. It has no internet access and no persistent storage of its own, its only writable surface is a virtiofs share pointing at `~/vm-inbox/` on the host.

**Security model:**

- Regular VMs have no direct host filesystem access whatsoever
- Only hostsync can write to the host, and only to `~/vm-inbox/` - blast radius is one directory
- Every write is host-started (`shard files transfer ... hostsync/`); the archive, authored by the
  source VM, is unpacked with `hydrix.microvm.safeExtract` (regular files and directories only, no
  owners or permissions), the share's virtiofsd cannot create device nodes, and `/home` is mounted
  `nosuid,nodev` on the host
- Files arrive at hostsync already encrypted; the passphrase is released via vsock only after three-way SHA-256 verification passes
- Port 8888 accepts connections only from the files VM (`192.168.214.2`), enforced by nftables

**VM → Host** (`shard files transfer browsing/wallpapers/Sunset.png hostsync/wallpapers`):

```
browsing VM  →  [encrypted, br-browse]  →  files VM  →  [encrypted, br-hostsync]  →  hostsync VM
                                                                                           │
                                                                                     virtiofs (rw)
                                                                                           │
                                                                                    ~/vm-inbox/wallpapers/
```

The standard `shard files transfer` protocol is used unmodified. hostsync's vsock agent (port 14506) is compatible with the same `RECEIVE_PREPARE` / `DECRYPT` / `CLEANUP` commands sent to any destination VM.

**Host -> VM** (drop a file into `~/vm-inbox/`, then transfer out):

```bash
cp ~/somefile.txt ~/vm-inbox/
shard files transfer hostsync/somefile.txt pentest/
```

hostsync's agent also implements `ENCRYPT` and `SERVE`, so it can act as a transfer source.

**Commands:**

```bash
# VM -> Host
shard files transfer <src-vm>/<path> hostsync/            # extract to ~/vm-inbox/
shard files transfer <src-vm>/<path> hostsync/<subdir>    # extract to ~/vm-inbox/<subdir>/

# Host -> VM (drop file into ~/vm-inbox/ first)
shard files transfer hostsync/<filename> <dst-vm>/<path>
```

**Enable in your machine config** (included in the default template):

```nix
hydrix.microvmHost.byName.hostsync.enable = true;

# Required: pre-create the inbox before virtiofsd starts
systemd.tmpfiles.rules = let u = config.hydrix.username; in [
  "d /home/${u}/vm-inbox 0755 ${u} users -"
];
```

**What the files VM stores** (`/storage/` persistent qcow2, 50GB default):

```
/storage/
├── pentest/    # Files stored from pentest VM
├── comms/      # Files stored from comms VM
├── dev/        # Files stored from dev VM
└── tmp/        # In-transit blobs (cleaned after each operation)
```

**TAP/subnet/CID assignments:**

| Item | Value |
|------|-------|
| Bridge | `br-files` |
| Subnet | `192.168.108.0/24` |
| Files VM IP | `192.168.108.10` |
| Files VM per-bridge IP | `192.168.1xx.2` |
| Router leg | `192.168.108.253` |
| vsock CID | `212` |
| Home TAP | `mv-files` -> `br-files` |
| Router TAP | `mv-router-file` -> `br-files` |

### USB Sandbox (microvm-usb-sandbox)

Ephemeral VM for safely handling USB storage devices. The whole USB device is hotplugged into it (`usb attach`); the host kernel never binds USB storage, so this VM's kernel is the only one that parses the medium. It is isolated from all networks except the files VM.

**Network architecture:**

usb-sandbox sits on a dedicated isolated bridge (`br-usb-sandbox`) that has no router leg and no internet access. The files VM has a second TAP (`mv-files-usb`) on the same bridge, giving it direct L2 access to usb-sandbox without going through the router. No other VM can reach usb-sandbox.

```
Host
 │  vsock 14506 → usb-sandbox (CID 209)   [ENCRYPT / SERVE / RECEIVE_PREPARE / DECRYPT / CLEANUP]
 │  vsock 14505 → files VM    (CID 212)   [FETCH command]
 │
 │  br-usb-sandbox (192.168.209.0/24, no router, no internet)
 │   ├── usb-sandbox  (192.168.209.10)  mv-usb-sandbox TAP
 │   └── files VM     (192.168.209.2)   mv-files-usb TAP
```

**Transfer flow (USB → VM):**
1. Host -> usb-sandbox (vsock 14506): `ENCRYPT <passphrase> usb/sda1/file` encrypts AES-256-CBC to `~/shared/xfer.enc`
2. Host -> usb-sandbox (vsock 14506): `SERVE` starts HTTP server on port 8888
3. Host -> files VM (vsock 14505): `FETCH 192.168.209.10 xfer.enc` files VM pulls ciphertext over br-usb-sandbox
4. Host -> files VM (vsock 14505): `DELIVER <dest-ip> xfer.enc` files VM pushes to destination VM
5. Host -> dest VM (vsock 14506): `DECRYPT <passphrase> ...` destination VM decrypts


The passphrase is generated on the host and sent exclusively over vsock -> it never crosses a bridge network.

**Setup** in your `machines/<serial>.nix`:

```nix
hydrix.microvmHost.byName.usb-sandbox.enable = true;
```

Then rebuild and start:

```bash
rebuild
shard start microvm-usb-sandbox
```

**Host-side USB device pass-through** (Hydrix `host/usb.nix`):

The host blocks `usb_storage` and `uas` (initrd included, `hydrix.usb.blockHostStorage`,
default on; set it false in a fallback specialisation so install media works). Plugging a
stick in only sends a notification. Nothing attaches without an explicit command that shows
the device and target and asks y/N:

```bash
usb list                         # storage devices, where attached, which VMs accept them
usb attach <busid> usb-sandbox   # e.g. usb attach 4-1 usb-sandbox; -y skips the prompt
usb detach <busid>               # unmount inside the VM first
```

Any microVM whose `meta.nix` sets `usbPassthrough = true` accepts devices this way (an xHCI
controller plus QMP `device_add usb-host`); libvirt domains get a `virsh attach-device` USB
hostdev. In a Hydrix microVM, USB block devices arrive read-only (a guest udev rule);
`usb-rw <dev>` (`usb rw` in usb-sandbox) makes one writable.

Devices a VM should always have, such as a USB WiFi adapter for the pentest VM, go in its
`meta.nix` as `usbDevices = [ "148f:5572" ];` (vendor:product from `lsusb`). They attach at
VM start and on replug, and the host grants the `kvm` group access to exactly those IDs.

**Inside the VM (auto-logged in as `sandbox`):**

```bash
# List block devices
usb list

# Scan for filesystems
usb scan

# Mount partition (e.g., /dev/sda1), read-only until `usb rw /dev/sda`
usb mount /dev/sda1

# View mounted files
ls ~/usb/sda1/

# Unmount
usb umount /dev/sda1

# USB device info
lsusb

# Block device tree
lsblk
```

**File transfer (from host):**

```bash
# Archive from USB to files VM (encrypted)
shard files store usb-sandbox/usb/sda1/<path>

# Transfer to another VM
shard files transfer usb-sandbox/usb/sda1/<path> dev/<dest>
```

Paths are relative to `/home/sandbox/` inside the VM. USB drives mount at `/home/sandbox/usb/`.

**Security model:**

| Protection | Status |
|------------|--------|
| Network isolation from host |  Isolated bridge, no host IP, no internet |
| Network isolation from other VMs |  Only files VM access via br-usb-sandbox (port 8888) |
| Read-only USB access |  Set read-only on arrival in the VM; `usb rw` lifts it |
| Encrypted file transfers |  AES-256-CBC via files VM |
| Host never parses the medium |  `usb_storage`/`uas` blocked on the host; whole device passed after y/N |
| **Host USB core (enumeration)** |  **Not protected** |
| **Firmware-level attacks** |  **Not protected** |
| **Malicious USB peripherals** |  **Not protected** (only storage) |

**What it protects against:**
- Malicious filesystems on USB drives
- Auto-run malware
- Network-based USB attacks from compromised drives

**What it does NOT protect against:**
- Host kernel vulnerabilities in USB drivers (USB/IP, usb-storage)
- Malicious USB firmware (BadUSB, Rubber Ducky-style attacks)
- USB controller exploits
- Devices masquerading as keyboards/ethernet (only storage passed)

**Usage warnings:**
- Only pass through **USB storage** devices, not other USB peripherals
- The USB drive is read-only inside the VM
- Always scan transferred files before use on trusted systems
- Consider using Tails or Whonix for untrusted USB devices requiring higher assurance

---

### Passwords (hydrix.passwords, vault VM)

One frontend over a choice of backends, set per machine:

```nix
hydrix.passwords.backend = "vm";   # "vm" | "host" | "none" (default)
```

| Backend | Where the database is opened |
|---------|------------------------------|
| `"vm"` | Inside `microvm-vault` (CID 213), a fully offline VM. KeePassXC and the decrypted database never run in the host session. Enable the VM too (`hydrix.microvmHost.byName.vault`). |
| `"host"` | `keepassxc-cli` in the host session, against the same file. |
| `"none"` | Nothing installed; use your own password manager. |

The database is one file on the host, `~/vault/Passwords.kdbx`, a standard KeePassXC
database (encrypted with the master password; any KeePassXC opens it). With the `vm`
backend it is shared into the vault VM as `/var/lib/vault` (virtiofs, read-write,
uid-squashed to your user) and only ever decrypted there.

#### Using it

| Command | What it does |
|---------|--------------|
| `Mod+P` (`vault-pick`) | The TUI in a floating window; picking an entry copies it into the window you came from |
| `vault` | The same TUI in the current terminal |
| `vault ls` / `get PATH [FIELD]` / `copy PATH [FIELD]` | List entries; print or copy a field (`password` `username` `url` `notes` `totp`) |
| `vault add [PATH]` / `edit PATH [FIELD]` / `mv PATH NEW` / `rm PATH` | Add (empty password = generated), edit, rename or move between groups, delete (recycle bin) |
| `vault gen [LENGTH]` | Generate a password |
| `vault status` / `unlock` / `lock` | Session state |

TUI keys: `Enter` password, `Ctrl+U` username, `Ctrl+O` URL, `Ctrl+A` add, `Ctrl+E` edit,
`Ctrl+R` move, `Ctrl+D` delete, `Ctrl+G` generate, `Ctrl+L` lock, `Esc` quit. Entry paths are
`Group/Sub/Title`; groups are created as needed. The first `vault` on a machine without a
database asks for a master password twice and creates one.

Copies go to the host clipboard with `wl-copy --sensitive` and are cleared after
`hydrix.passwords.clipboardClear` seconds (30) if the clipboard still holds them (compared by
hash, so the background clearer never holds the secret).

#### How it works

```
vault / vault-pick (host, Hydrix host/passwords.nix)
   │  one request per call: VERB plus base64 arguments
   ├── backend "vm":   vsock 14514 ──▶ microvm-vault: socat (as user vault)
   └── backend "host": local process                 │
                                                     ▼
                         hydrix-vault-backend (Hydrix shared/vault/backend.py)
                           master password on keepassxc-cli's stdin only
                                                     │
                         ~/vault/Passwords.kdbx  (/var/lib/vault in the VM)
```

- **Protocol v2** (`shared/vault/backend.py`): `PING`, `STATUS`, `INIT`, `UNLOCK`, `LOCK`,
  `LIST`, `GET`, `ADD`, `EDIT`, `MOVE`, `RM`, `GEN`, `MERGE`. Every argument is base64, so
  names with spaces or any characters work; replies are `OK` or `ERROR <message>` followed
  by base64 data lines. `LIST` never returns passwords; `GET` returns one field.
- **Session**: `UNLOCK` stores the master password in a tmpfs file, mode 600: in the vault VM
  `/run/vault-session/token` (1 MB tmpfs owned by the vault user), for the host backend
  `$XDG_RUNTIME_DIR/hydrix-vault/session`. `LOCK`, or `lockTimeout` seconds without use
  (300, checked every minute in the VM), deletes it.
- **Agent** (`hydrix.vault.agent`, `vm/microvm/infra/vault-agent.nix`): a socat listener on
  vsock 14514 running each request as the vault user, plus the auto-lock timer.

#### Security boundaries

- **No network**: the vault VM has no interface at all, so nothing running in it can send a
  credential anywhere. The only way out is the vsock reply to the host.
- **Only the host reaches it**: vhost-vsock delivers guest connections to the host only, so
  other VMs cannot address the vault VM's port.
- **Master password in VM RAM only**: never written to disk, never on a command line, never
  logged; deleted on lock and after the idle timeout.
- **Clipboard scoping (hypr-clip-guard)**: `vault-pick` remembers the focused window, closes
  its floating window, refocuses that window, and only then copies. clip-guard sees a
  headless copy while that window has focus and locks the secret to it, so it is not
  replayed to windows focused later or to other VMs. A copy from `vault` in a normal
  terminal is locked to the host (the terminal has focus); use `Mod+P` for VMs.
- **Encrypted at rest**: the `.kdbx` file is ciphertext without the master password; it can
  sit in a private git repository.

#### What it does not protect against

| Threat | Notes |
|--------|-------|
| Compromised host session or compositor | Sees the master password as it is typed and every copied secret |
| Host root | Can read the vault VM's memory |
| Weak master password | The file's protection is only as strong as the password |

#### Setup

1. In the machine config: `hydrix.passwords.backend = "vm";` and the vault VM enabled
   (`"microvm-vault" = { autostart = true; };` under `hydrix.microvmHost.vms`).
2. `rebuild`, then `shard -bR vault`.
3. Press `Mod+P` (or run `vault`): set a master password, and the database is created.

#### Between machines

The database moves as the one encrypted file, and `~/vault` is yours to track. Keep it in
your own **private** git repository and declare it in `modules/repos.nix` (`vault = {};`, or
`vault = { clone = false; };` until the remote exists): `ensure-repos` clones it into an empty
`~/vault` on every machine and the git VM shares it. Commit on the host and `shard git push vault` after
changes, and `shard git pull vault` on the other machine. Edit on one machine at a time: two
edited copies of the binary file cannot be merged by git. A built-in `vault sync` that merges
both sides entry by entry (protocol `MERGE`) is a possible later addition
(`hydrix-config/plans/vault-rework.md`, Step 5).

Never track the database inside your hydrix-config repo: every tracked file there is copied
into `/nix/store`, which every VM can read, and the database's protection would then rest on
the master password against offline guessing.

#### Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| "vault VM unreachable (shard -s vault)" | The VM is not running, or its agent is not: `shard -i vault`, then `shard -bR vault` |
| "the vault VM runs an older agent" | The VM was not rebuilt after an update: `shard -bR vault` |
| "wrong password" on a machine meant to start fresh | An old `Passwords.kdbx` is still in `~/vault`; move it aside |
| `Mod+P` shows an error and "Press any key to close" | The message is the backend's; the table above covers the common ones |

---

### In-VM Development (vm-dev workflow)

Package a GitHub project inside a VM, get it building there, then pull it into a profile on the
host. Every staged package is self-contained: it carries the nixpkgs revision and source commit
it was built and tested with, so it builds the same on the host, and host nixpkgs bumps never
change it.

```bash
# === Inside VM ===
vm-dev build https://github.com/owner/repo   # Create flake, then auto-fix until it builds
vm-dev run repo                               # Run it (auto-fixes the build first if needed)
vm-dev fix repo                               # Build, diagnose, edit flake.nix, repeat
vm-dev update repo                            # Re-pin nixpkgs to the VM's current system nixpkgs
vm-dev install repo                           # Install to the VM user profile (also takes a URL)
vm-dev list                                   # List local packages
vm-sync push --name repo                      # Stage for the host

# === On host ===
vm-sync list                                  # List staged packages from running VMs
vm-sync pull repo --target dev                # Pull to profiles/dev/packages/
vm-sync status                                # Show packages per profile
shard -r dev                                  # Build the VM with the package, live switch
```

**Package locations:**
- VM development: `~/dev/packages/<name>/flake.nix` (+ `flake.lock`, `build.log`)
- VM staging: `~/staging/<name>/package.nix`
- Host profiles: `~/hydrix-config/profiles/<type>/packages/<name>.nix`

#### Pinning

`vm-dev build` resolves the repository's default branch to its current commit and writes that
commit into `fetchFromGitHub` (`rev` + `hash`), so upstream pushes never change the package.
The flake's `nixpkgs` input is locked to an exact `github:NixOS/nixpkgs/<rev>` with its
`narHash`. The first lock uses the VM's own system nixpkgs (revision from `nixos-version --json`,
store path from `/etc/nix/registry.json`), which is already in the store, so pinning downloads
nothing. The pin is explicit (`nix flake lock --override-input`) because locking an indirect
`nixpkgs` input resolves through the global registry (nixpkgs-unstable), not the system one.

The pin is sticky: `vm-dev run`, `rebuild`, `install` and `fix` keep it. `vm-dev update <pkg>`
moves it to the VM's current system nixpkgs, which is how a package follows a host nixpkgs bump
on purpose (rebuild the VM first so its system nixpkgs is the new one).

#### Auto-fix (`vm-dev fix`)

`vm-dev fix` (`vm/dev/vm-dev-fix.py`) builds with full logs, turns recognised errors into
`flake.nix` edits, and rebuilds, up to 10 rounds (`--max N`, `-n` to only diagnose). Changes
are shown as a diff; the previous file is kept as `flake.nix.bak`. `vm-dev build` and `vm-dev
run` call it automatically. It handles:

- Missing C/C++ headers, `-l` libraries, pkg-config modules, CMake packages and build tools
- Rust `-sys` crates and bindgen, Python build backends, missing modules and version pins
- Fixed-output hash mismatches (source, `vendorHash`, `cargoHash`, `npmDepsHash`, ...)
- Names that are not nixpkgs attributes (removed again)
- Newer-gcc strictness on old C (`-Wno-error=...`, `-std=gnu17`, `-fcommon`), hardening flags
- Failing sandboxed tests (`doCheck = false`) and installs that cannot find the binary
- Go: builds only the module's `package main` directories (`subPackages`) when the tree holds
  nested modules or test-only packages; picks a `buildGo1XXModule` new enough for `go.mod`
- A binary not named after the package (`meta.mainProgram`)

Dependency candidates come from a curated map, then `nix-locate` (nix-index-database), then
name guesses, filtered to attributes that exist in the package's pinned nixpkgs. A candidate that
does not clear the error is removed again and the next one is tried. When the pinned toolchain
is too old for the project (Go, Rust, Python), only that package's pin moves, to the latest
`nixos-unstable`.

#### Staging and transfer

`vm-sync push --name <pkg>` makes sure nixpkgs and the source are pinned (refusing otherwise),
then writes `~/staging/<pkg>/package.nix`: the flake's derivation, wrapped to import its own
pinned nixpkgs instead of the host's:

```nix
{ pkgs }:
let
  system = pkgs.stdenv.hostPlatform.system;
  nixpkgs = builtins.fetchTree { type = "github"; owner = "NixOS"; repo = "nixpkgs"; rev = "<rev>"; narHash = "<narHash>"; };
in
let
  pkgs = import nixpkgs { inherit system; };
in
pkgs.buildGoModule { ... }
```

The VM never writes to the host. Each profile VM runs `vm-staging-server`
(`vm/microvm/infra/vm-staging-server.c`, vsock 14502), which only answers host requests:
`list`, `info <pkg>`, `dev`, `get <pkg>` (a `tar` stream of `~/staging/<pkg>`) and
`unstage <pkg>`.

The `vm-sync pull` command:
1. Finds the VM holding the package (`info` to each running VM; CID from
   `/etc/hydrix/vm-registry.json`) and fetches it with `get`, capped at 10 MB.
2. Checks the archive before extracting: only regular files and directories under `<package>/`
   (no links, special files, absolute paths or `..`), extracted without owners or permissions.
   Anything else is refused.
3. Shows the staged `package.nix` (control characters stripped) and asks y/N, since the package
   is built on the host.
4. Copies it to your user config's profile (never through a symlink), regenerates
   `packages/default.nix` (each package as `import ./<name>.nix { inherit pkgs; }` in
   `environment.systemPackages`), stages both for git tracking, and sends `unstage` to the VM.

When the host evaluates the package, `fetchTree` resolves the pinned nixpkgs by its hash: free
when it is already in the store, otherwise fetched (through the builder VM in lockdown mode). A
package pinned to a different nixpkgs than the host adds that nixpkgs (and possibly its
toolchain) to the store.

### Live Switch (shard switch)

`shard switch` builds a new VM config and applies it without restart. 

**How it works:**

1. **Host builds** new VM system closure via `nix build`
2. **Host dumps nix DB registration** for the new closure's store paths to `/var/lib/microvms/<vm>/config/.switch-reg`
3. **Host sends** `SWITCH /nix/store/...` to VM via vsock port 14504
4. **VM loads registration** via `nix-store --load-db` so its local DB knows about host-built paths
5. **VM runs** `switch-to-configuration switch` with full home-manager activation
6. **Result:** new systemd services start, alacritty.toml updates, etc.

**When to use restart instead:**
- Kernel or initrd changes
- New qcow2 volumes added
- Microvm runner configuration changes (memory, CPU, shares)

---

## Mullvad VPN

Each VM bridge can route through a separate Mullvad WireGuard exit node. The router VM manages all tunnels \- VMs themselves have no VPN configuration.

### Setup

1. **Download .conf files**  - mullvad.net -> Account -> WireGuard configuration -> select server -> download. One file per VM that needs VPN:
   ```
   ~/hydrix-config/vpn/mullvad-browsing.conf
   ~/hydrix-config/vpn/mullvad-pentest.conf
   ~/hydrix-config/vpn/mullvad-comms.conf
   ```
   Multiple VMs can share the same Mullvad key pair \- just download separate .conf files pointing to different (or the same) servers.

2. **Create `vpn/mullvad.nix`**. copy from the provided example:
   ```bash
   cp ~/hydrix-config/vpn/mullvad.nix.example ~/hydrix-config/vpn/mullvad.nix
   ```
   Then edit it to map bridge names to conf files:
   ```nix
   {
     enable = true;
     bridges = {
       browsing = ./mullvad-browsing.conf;
       pentest  = ./mullvad-pentest.conf;
       comms    = ./mullvad-comms.conf;
     };
   }
   ```
   Bridges omitted from the map go direct (no VPN, no kill switch).

3. **Wire into machine config** - uncomment in `machines/<serial>.nix`:
   ```nix
   router.vpn.mullvad = import ../vpn/mullvad.nix;
   ```
   The flake also auto-includes `vpn/mullvad.nix` if it exists \- no manual wiring needed if you use the flake template as-is.

4. **Rebuild the router:**
   ```bash
   shard build router && shard restart router
   ```

### How It Works

At router boot, `vpn-boot-assign` brings up a `wg-<bridge>` WireGuard interface for each entry in the bridges map and routes that bridge's traffic through it. Bridges not in the map go direct. The router uses policy routing (one table per subnet, table ID = CID) so each bridge is fully isolated, a browsing VM and a pentest VM can exit through different countries simultaneously.

**Fail closed.** `vpn-policy-init` installs every network's table before any interface comes up, each ending in an `unreachable` default. A network only reaches the WAN when its table says so:

| Assignment | Table contents | Result |
|------------|----------------|--------|
| `wg-<name>` | `default dev wg-<name>` | Traffic through the tunnel |
| tunnel down or deleted | only the `unreachable` fallback | Blocked, never direct |
| `blocked` | only the `unreachable` fallback | Blocked |
| `direct` | `throw default` | Handed to the main table, follows the router's current WAN route (survives WiFi roaming) |

Mullvad networks stay blocked from boot until their tunnel is up, and a tunnel that fails to connect at boot leaves its network blocked. Traffic *to* a router LAN always uses the main table, so router replies and allowed inter-VM traffic never enter a tunnel table.

**DNS follows the traffic.** VMs use the router (`.253`) as their resolver. For tunnelled and blocked networks the router DNATs those queries to the in-tunnel resolver (`hydrix.router.vpn.mullvad.dns`, default Mullvad's `10.64.0.1`), so lookups leave through the same tunnel as the traffic, or not at all while blocked. Direct networks use the router's own resolver. `vpn-assign` keeps this redirect in step with every reassignment.

The `Table = off`, IPv6, and DNS lines are automatically stripped from downloaded `.conf` files at build time so they don't interfere with the router's own routing.

New profiles are handled automatically: add the bridge entry to `mullvad.nix` and rebuild the router, no other changes needed.

### Runtime Management

All commands run on the host (sent to router via vsock) or from the router console. No rebuild required.

```bash
vpn-status                                  # Show all bridge assignments and tunnel state
vpn-assign browsing direct                  # Bypass VPN for browsing VM
vpn-assign browsing wg-browsing             # Re-enable VPN
vpn-assign --persistent pentest direct      # Persist assignment across reboots
vpn-assign list-mullvad                     # List configured exit nodes
```

### Adding a New VM to VPN

1. Download a `.conf` file for the new VM: `vpn/mullvad-myvm.conf`
2. Add `myvm = ./mullvad-myvm.conf;` to the `bridges` map in `vpn/mullvad.nix`
3. Rebuild the router: `shard build router && shard restart router`

---

## Vsock Communication

All host-VM communication uses virtio-vsock. No SSH or network access to VMs. Each VM has a unique CID (Context ID).

### Port Assignments

| Port | Service | Direction | Purpose |
|------|---------|-----------|---------|
| 14501 | vm-metrics | Host -> VM | Poll CPU, RAM, disk, uptime |
| 14502 | vm-staging | Host -> VM | List/pull staged packages (vm-sync) |
| 14503 | vm-colorscheme | Host -> VM | Push colorscheme updates (REFRESH) |
| 14504 | vm-switch | Host -> VM | Live NixOS config switch (SWITCH/TEST/STATUS/PING) |
| 14505 | files-agent | Host -> Files VM | File transfer ops (FETCH/DELIVER/STORE/LIST) |
| 14506 | vm-files-agent | Host -> any VM | Per-VM file ops (ENCRYPT/DECRYPT/SERVE/CLEANUP) |
| 14506 | router-stats-server | Host -> Router | WiFi/net/WireGuard status + WiFi credential sync (see [Polling Architecture](#polling-architecture) below). Commands: `PING`, `POLL`/`STATUS`, `NET`, `WG`, `ALL`, `ADD`/`REMOVE` |
| 14505 | pulse-vsock | VM -> Host | PulseAudio/PipeWire audio bridge, only for VMs with `audio = true` in meta.nix |
| 14508 | waypipe-launch | Host -> VM | App launch commands (Wayland mode) |
| 14509 | display-mode | Host -> VM | Display mode selector / readiness gate: `PING`/`waypipe-reconnect`/`STATUS`/`stop` |
| 14510 | builder-build | Host -> Builder | Send build commands |
| 14511 | builder-status | Host -> Builder | Query builder status |
| 14518 | vm-notify-relay | VM -> Host | Forwards `org.freedesktop.Notifications` calls to a host popup. Opt-in per VM via `notifyForward = true` in the profile's `meta.nix`, which drives both `hydrix.microvm.notifyForward.enable` and the host's per-CID allowlist |
| 146xx | waypipe per-VM | VM -> Host | Wayland tunnel, one port per VM: `14600 + CID - 100` |

> **waypipe per-VM ports**: browsing (CID 103) -> 14603, pentest (CID 102) -> 14602, lurking (CID 106) -> 14606, etc. This avoids collision when multiple VMs are tunnelled simultaneously.

### Protocol

All services use raw TCP-like streams over vsock. Messages are line-oriented text. The host uses `vsock-cmd` (a small Python helper installed by the framework) for reliable communication:

```bash
# vsock-cmd <cid> <port> [connect-timeout-seconds]
# Reads command from stdin, writes response to stdout.

# Query VM metrics
echo "cpu" | vsock-cmd 101 14501

# Trigger color refresh
echo "REFRESH" | vsock-cmd 101 14503

# Live switch (longer connect timeout for slow VMs)
echo "SWITCH /nix/store/..." | vsock-cmd 101 14504 30

# Query switch status
echo "STATUS" | vsock-cmd 101 14504
```

`vsock-cmd` uses `AF_VSOCK` sockets directly (no socat). It sends one newline-terminated command, then reads until the connection closes, which happens naturally when the per-connection handler exits on the VM side.

### Polling Architecture

Some vsock services answer a command the host asks for repeatedly on a timer (WiFi/net
status polled every few seconds, package-staging lists polled every couple minutes),
rather than once per human action. Those services use a different pattern from the rest
of this table, for a concrete reason: **KVM runs a guest's vCPU as a real host thread**,
so guest work and host CPU time on that thread are the same event, not two separate
things. A vsock listener implemented as `socat VSOCK-LISTEN:PORT,fork EXEC:handler`
forks a new process and execs a shell and execs the actual payload on every single
connection - and since a VM's entire `/nix/store` is typically mounted read-only over
virtiofs, each new process can mean a FUSE round trip to the host's virtiofsd for every
path/library it needs to resolve. On a low-vCPU guest, that fork+exec chain shows up as
a measurable CPU spike **regardless of how cheap the payload itself is** - reproducible
by firing a single connection at an otherwise-idle fork-per-connection listener and
watching CPU spike on that guest's vCPU thread.

**The fix, used by `router-stats-server`/`vm-staging-server`**: a persistent process
that binds the vsock listener once and holds it open for the service's lifetime,
answering every connection from already-cached data or direct in-process work - no
`fork`/`exec` on the connection path at all. Concretely:

1. **Separate gathering from serving, and avoid timers where possible.** The
   vsock-facing part is an always-running process that answers from memory or a cache
   file, never forking. How the data gets there depends on its kind:
   - *State that changes on events* (associated SSID, saved connections): watch the
     event source (nl80211 multicast groups, inotify on a directory) and rewrite the
     cache only when something happens. `router-netlink-poller` does this and sleeps in
     `poll()` with no timeout once everything it watches exists.
   - *Counters* (interface bytes, WireGuard handshakes and transfer): read them in the
     server when a request arrives, compute rates from the previous request's values,
     and reuse the answer for a short window (2s) so several consumers asking at once
     cost one read. `router-stats-server` does this for `NET` and `WG`.
   - *Slow external lookups* (geo-location over HTTPS): trigger them from a systemd path
     unit on a file the server rewrites only when the input set changes
     (`/tmp/wg-endpoints` -> `router-geo-refresh`).
   A timer-driven sampler is the last resort, for data with neither an event source nor
   a cheap on-request read.
2. **One command that returns everything.** Alongside per-topic commands, give the
   server an `ALL`-style command that returns every topic it serves in one response, so
   a consumer needing multiple pieces of data can do it in a single connection instead
   of several.
3. **If a timer is unavoidable, route its interval through one option.** A single
   `mkDefault`-able interval option (rather than a hardcoded value duplicated across
   scripts) lets machine configs dial down sample frequency on weaker hardware without
   touching code.
4. **Merge multiple independent sampler loops into one where they serve the same
   consumer**, instead of several independently-scheduled `while true; sleep` loops
   each paying their own fork/exec cost on their own schedule.
5. **When rewriting a sampler's internals to avoid forking, don't stop at the obvious
   command.** A single command call looks cheap in isolation, but a real tick that also
   loops over N saved items calling `grep`+`sed` (or similar) per item can add up to
   dozens of forks in one burst - test the *actual* service tick (e.g. restart it and
   watch a per-thread CPU sample immediately after), not just its individual commands run
   once by hand, which can look deceptively cheap due to warm page cache from the very
   loop you're trying to measure.
6. **Judge fork/exec elimination against actual risk and frequency, not uniformly.**
   Rewriting logic that only touches plain data (files, `/proc`, JSON) is low-risk and
   worth doing wherever a real polling loop exists. Logic touching cryptography or auth
   flows (encryption, SSH, OAuth device flows) is a bad candidate for a hand-rolled
   rewrite regardless of how "simple" the surrounding shell script looks - the security
   cost of a subtle bug outweighs a fork's CPU cost, especially for something only
   triggered once per explicit human action rather than continuously polled. Similarly,
   a one-shot handler that's already just a single command dispatch (no per-item loop)
   usually isn't worth converting at all - the fork-per-connection listener overhead on
   something triggered a few times a day is not a measurable cost.
7. **A command that looks irreducible (a real CLI tool wrapping a kernel API) can often
   still be eliminated** if that kernel API is exposed over a stable protocol. `iw`/`wg`
   both wrap netlink (`nl80211`, WireGuard's generic-netlink family): querying the same
   attributes directly over a netlink socket, from an already-running process, removes
   the fork+exec entirely (see `router-netlink-poller.c`, `router-stats-server.c` and the
   shared `router-netlink.h`). Watch for two pitfalls
   specific to netlink dumps when doing this: `MNL_SOCKET_BUFFER_SIZE`/similar library
   defaults can be too small for a real, attribute-heavy response and netlink truncates
   silently rather than erroring; and any receive loop that stops reading as soon as it
   finds what it wants, without draining to the dump's terminator message, leaves
   unread data in the socket's receive queue that corrupts every later read on that
   socket if it's reused across ticks.

A persistent server can still `fork`+`execvp` for genuinely rare/interactive commands
within the same process (e.g. `ADD`/`REMOVE` WiFi credentials, `get`/`unstage` a staged
package) - that cost doesn't recur on every poll cycle, so it doesn't need the same
treatment as the commands actually hit by a timer. When a rare command's payload needs
to run an external tool with caller-supplied arguments (an SSID, a package name), pass
them as an `execvp`/`execve` argv array rather than building a shell string - avoids any
possibility of the argument being reinterpreted as shell syntax.

**Measuring it.** Per-process tools miss most of this: the cost is in short-lived processes
and in the VM's vCPU thread on the host. hydrix-config's `custom/spike-tools` (personal
tooling, not part of Hydrix) shows the approach: sample each QEMU thread at 0.1s, trace
host execs and vsock connects with bpftrace, and compare phases with suspected sources
switched off (consumers frozen with `SIGSTOP`, guest services stopped over the serial
console). Look for a fixed period in the vCPU spikes: a 10s or 30s rhythm points at a
timer, and stopping candidates one at a time finds it.

---

## VM Store Sharing

VMs share the host's `/nix/store` via virtiofs with a writable overlay, avoiding multi-gigabyte per-VM stores.

### Architecture

```
Host /nix/store (read-only virtiofs)
         |
         v
VM /nix/.ro-store  ─────────┐
                            ├── overlayfs ──> VM /nix/store
VM /nix/.rw-store (qcow2) ──┘
```

- **Lower layer:** `/nix/.ro-store`, host's store via virtiofs (read-only, high performance)
- **Upper layer:** `/nix/.rw-store`, thin-provisioned qcow2 (starts near 0, grows as VM builds packages)
- **Merged:** `/nix/store`, VM sees all host paths plus its own builds

### Filesystem Shares

**Rule:** anything a VM shares with the host is either read-only to the VM, enforced by the
host (`readOnly = true` on the share, so virtiofsd runs with `--readonly`; a guest's own
read-only mount can be remounted by guest root), or written only during an operation the
host starts (builder builds, `shard git`, `shard files transfer`, vault commands). Shares a
VM can write additionally get `hydrix.microvm.writableShareArgs`
(`--modcaps=-mknod:-setfcap`: no device nodes or file capabilities); shares holding the user's
own files (vault, hostsync inbox, gitsync repos) use `hydrix.microvm.ownedShareArgs`, which also
squashes every guest uid/gid to `hydrix.microvm.hostOwner` (default 1000/100; those VMs' service
users are pinned to it, and the shares set `posixAcl = false`). The host mounts
`/home` and the repo views `nosuid,nodev` (`hydrix-home-nosuid`), so nothing a guest writes
can carry a working setuid bit or device node. Archives that come from another VM are
unpacked with `hydrix.microvm.safeExtract` (regular files and directories only, no owners
or permissions).

| Tag | Source (Host) | Mount (VM) | Access | Purpose |
|-----|---------------|------------|--------|---------|
| `nix-store` | `/nix/store` | `/nix/.ro-store` | read-only (builder: read-write) | Shared nix store |
| `vm-config` / `router-config` | `/var/lib/microvms/<vm>/config` | `/mnt/vm-config`, `/mnt/router-config` | read-only | Live switch registration (the host writes and removes it) |
| `hydrix-config` | `~/.config/hydrix` | `/mnt/hydrix-config` | read-only | Host theming state |
| `vm-secrets` | `/run/hydrix-secrets/<vm>` | `/mnt/vm-secrets` | read-only | Provisioned secrets |
| `repo-<name>` | `/run/hydrix-repos/<vm>/<name>` | same path as on the host | read-write except `readOnlyPaths` | Host working tree (only with `hostRepos`) |
| `vault-data`, `host-inbox`, gitsync `repo-*` | `~/vault`, `~/vm-inbox`, repos | `/mnt/...` | read-write, host-started operations | Vault database, hostsync inbox, git sync |

#### Host Repos (`hostRepos`)

`hydrix.microvmHost.vms.<vm>.hostRepos` shares host working trees into a profile VM so it
can edit them without being able to commit or push. The host service `hydrix-repos-<vm>`
runs before the VM's virtiofsd and builds one view per repo:

1. Bind-mounts the working tree at `/run/hydrix-repos/<vm>/<name>` and makes that mount
   private, so nothing mounted inside it propagates back onto the real tree.
2. Bind-mounts each `readOnlyPaths` entry (default `.git`) over itself and remounts it
   read-only. Missing entries are created as empty directories first.
3. virtiofsd serves the view, and the VM mounts it at the working tree's own absolute path
   (`hydrix.microvm.hostRepos`, which the user flake sets from the same value).

The read-only mounts live in the host's mount namespace, so root in the guest can't undo
them. A guest-side read-only mount stacked over a read-write share could simply be unmounted.
With `.git` read-only the VM cannot commit or change refs, hooks, or git config, and since only
the git VM receives the `github` secret, it has no push path at all. For declared repos, use the
shorthand `microvmHost.vms.<vm>.repos = [ "<name>" ]` (see [repos.nix](#reposnix)).

The views are built on VM start, not on rebuild (`restartIfChanged = false`), so a changed
`hostRepos` takes effect on the next restart. They are torn down when the VM stops
(`partOf` its `microvm@` unit), so a repo directory moved or replaced on the host while the
VM is down is picked up as it is at the next start. Inside the guest, read-only paths still pass
`test -w`, since only the host knows they are read-only. VM-side scripts must attempt the
write and handle `EROFS` rather than check first.

### Nix DB Registration

Paths exist in the VM's `/nix/store` via virtiofs but the VM's local nix database (`/nix/var/nix/db/db.sqlite`) doesn't know about them. This matters during `shard switch` \- home-manager's `nix-store --realise` queries the local DB. The host dumps registration info before switching, and the VM loads it with `nix-store --load-db`.

---

## Build System

### Host Rebuild

```bash
# Standard rebuild (auto-detects specialisation)
rebuild

# Force specific specialisation
rebuild lockdown
rebuild administrative
rebuild fallback

# Options
rebuild -u              # Update flake inputs first
rebuild -p              # Pre-build VM configs after
rebuild -a              # Also build infra VMs already built on this machine
rebuild -v              # Verbose output

# Backwards-compat alias
nixbuild                # Same as rebuild
```

### Builder VM (Lockdown Mode)

The builder VM enables nix builds in lockdown mode when the host has no internet. It fetches dependencies via the router VM and writes build outputs directly to the host's `/nix/store`.

**Commands:**

```bash
# Build a single target
shard builder build browsing
shard builder build host

# Build multiple targets in one session (eval cache stays warm)
shard builder build browsing pentest dev

# Build and immediately switch host config
shard builder switch                 # Switches to current specialisation
shard builder switch administrative  # Switch to specific specialisation

# Prefetch only (keep builder running for batch operations)
shard builder fetch browsing
shard builder fetch pentest
shard builder stop                  # Stop when done

# Manual control
shard builder start                 # Start builder (stops host nix-daemon)
shard builder shell                 # Attach to builder console
shard builder status                # Check builder state
shard builder stop                  # Stop builder (restarts host nix-daemon)
```

**Named targets:**

| Target | Resolves To |
|--------|-------------|
| `browsing` | `microvm-browsing-<serial>` (this machine) |
| `pentest` | `microvm-pentest-<serial>` |
| `dev` | `microvm-dev-<serial>` |
| `comms` | `microvm-comms-<serial>` |
| `lurking` | `microvm-lurking-<serial>` |
| `task1` / `task2` / `task3` | `microvm-pentest-task<N>-<serial>` |
| `router` | `microvm-router-<serial>` |
| `builder` | `microvm-builder` (shared, not per-machine) |
| `host` | Host NixOS config |

**Operational flow:**

```
shard builder build browsing

1. Host nix-daemon stops, /nix/store remounted R/W
2. Builder VM starts with virtiofs /nix/store access
3. Builder evaluates flake (cached after first build)
4. Dependencies fetched via router VM (has internet)
5. Build happens in builder, outputs written to host's /nix/store
6. Builder stops, /nix/store remounted R/O
7. Host nix-daemon restarts
8. Host builds packages instantly (all deps already in store)
```

**Local flake inputs (`localInputs`):**

The builder evaluates the user flake from `/mnt/hydrix` (a read-only share of
`~/hydrix-config`). A local input such as `hydrix.url = "path:/home/<user>/Hydrix"` is
locked by its absolute host path, so the builder needs that path too.
`hydrix.builder.localInputs` shares each listed path read-only (enforced by the host
virtiofsd) at the same absolute path, and adds it to the builder's git `safe.directory`:

```nix
# infra/builder/default.nix
{config, ...}: {
  hydrix.builder.localInputs = ["/home/${config.hydrix.builder.hostUsername}/Hydrix"];
}
```

An offline build then resolves the input exactly as the host does. With `hydrix.url` on a
remote the share is simply unused. Every listed path must exist on the host, or the
builder's virtiofsd fails to start.

**Builder shell access:**

```bash
shard builder shell

# Inside builder:
nix flake metadata                        # Check flake inputs
nix build .#microvm-browsing-<serial>     # Manual build (use your machine's serial)
exit                                       # Return to host, builder stops
```

**Status checking:**

```bash
shard builder status

# Output:
# Builder state: running
# Process ID: 12345
# Target: browsing
# Progress: building...
```

**Recovery if builder crashes:**

```bash
# If builder is stuck
shard stop microvm-builder  # This also restores host nix-daemon

# If store is still rw after crash
sudo mount -o remount,ro,bind /nix/store
sudo systemctl start nix-daemon
```

**Persistent eval cache:**

The builder maintains an 8GB persistent volume (`builder-cache.img` at `/root/.cache/nix`) that survives restarts. First build after purge is slow (2+ min for flake eval); subsequent builds skip evaluation entirely.

To reset:
```bash
shard builder purge          # Remove builder-cache.img
shard builder start          # Rebuild clean cache
```

### Libvirt VMs

```bash
# Build base images 
build-base --type browsing
build-base --type pentest --type dev
build-base --all

# Deploy VM instances 
deploy-vm --type browsing --name personal --user myuser
deploy-vm --type pentest --name htb --vcpus 8 --memory 16384
deploy-vm --type dev --name work --encrypt    # LUKS encrypted
deploy-vm --type pentest --name win-target --bridge br-pentest   # next to the pentest VM
```

**Networking.** The host never routes, so a libvirt VM gets internet only from a bridge the router serves. `virbr0` (libvirt's `default` network) is isolated and has no internet. deploy-vm picks the bridge in this order:

1. `--bridge <br>` on the command line
2. `hydrix.libvirt.defaultBridge`, for every type
3. the type's own bridge (`pentest` -> `br-pentest`, `browsing` -> `br-browse`, ...)

A dedicated network for standalone VMs keeps them out of your profile VMs' segments. Declare it in `flake.nix` (the router is a separate build and only sees networks passed there) and point deploy-vm at it:

```nix
# flake.nix
standaloneNetworks = [
  { name = "libvirt"; subnet = "192.168.130"; routerTap = "mv-router-libv"; }
];
extraNetworks = profileExtraNetworks ++ infraNetworks ++ taskNetworks ++ standaloneNetworks;

# machines/<serial>.nix
hydrix.libvirt.defaultBridge = "br-libvirt";
```

After `rebuild`, `br-libvirt` exists on the host and the router serves `192.168.130.0/24` (gateway and DNS `.253`, DHCP `.10`-`.200`), isolated from every other VM network and assignable to a Mullvad exit like any other. For VMs created by hand in virt-manager, set the NIC's network source to "Bridge device" `br-libvirt`; Windows needs the virtio-win drivers for a `virtio` NIC, or use `e1000e`. A test target on `br-pentest` shares the pentest VM's subnet, so the pentest VM reaches it directly, and it follows pentest's routing.

---

## Shell

Fish shell with babelfish for fast environment variable sourcing.

### Abbreviations & Aliases

The Hydrix framework provides several shell abbreviations for common commands:

| Abbreviation | Expands to | Purpose |
|--------------|------------|---------|
| `s` | `shard` | MicroVM lifecycle CLI |
| `za` | `zenaudio` | Audio device switcher (ASUS ZenBook) |
| `zas` | `zenaudio speakers` | Enable internal speakers |
| `zah` | `zenaudio headphones` | Enable headphones |
| `zab` | `zenaudio bluetooth` | Enable Bluetooth headset |
| `za` | `zenaudio toggle` | Toggle speakers/headphones |
| `rvm` | `rebuildvms` | Rebuild multiple VMs at once |

**Multi-VM commands** - every word and flag form of `shard` already accepts
multiple VM names directly, so no separate multi-VM subcommand is needed:

```fish
# Build multiple VMs at once
shard build files pentest browsing

# Restart multiple VMs
shard restart files pentest browsing dev

# Rebuild (build + switch) multiple VMs
shard rebuild vault files pentest browsing

# Flag form combines actions too, run in the order given, flag-major across
# every listed VM (build both, then start both):
s -bs pentest browsing
```

### Babelfish

NixOS modules often source bash scripts to set environment variables (e.g., `/etc/profile`). Fish needs to translate these. Two approaches:

| Method | How | Speed |
|--------|-----|-------|
| `foreign-env` | Spawns bash, diffs environment (~6 calls) | ~170ms |
| `babelfish` | Compiled Go binary, translates syntax directly | ~1ms |

Babelfish is enabled globally via `programs.fish.useBabelfish = true` in the fish module. This applies to both host and VMs.

### Prompt

Starship prompt with git status, directory, command duration. Configured per-host via Hydrix options.

### Navigation

Zoxide for frecency-based `cd` (`z <partial-path>`). Initialized in fish config.

---

## Workspace Integration

Workspaces are mapped to VMs via the `hypr-ws-app` script. Pressing `Super+Return` launches a terminal in the correct context, host or VM, based on the focused workspace.

### Workspace Mapping

| Workspace | Target | Behavior |
|-----------|--------|----------|
| WS1 | Host | Always host terminal |
| WS2 | Pentest VM | Active VM tracking |
| WS3 | Browsing VM | Active VM tracking |
| WS4 | Comms VM | Fixed (comms) |
| WS5 | Dev VM | Active VM tracking |
| WS6 | Lurking VM | Fixed (lurking) |
| WS7-9 | Host | Always host terminal |
| WS10 | Router | Serial console |

> **Note**: VM workspaces are dynamic \- they're read from `/etc/hydrix/vm-registry.json` at runtime. Adding a new profile VM automatically adds its workspace mapping. No hardcoded workspace→VM tables in scripts.

### vm-registry Integration

All workspace→VM routing reads from `/etc/hydrix/vm-registry.json` at runtime:

```
hypr-ws-app (Super+Return)
  -> get focused workspace number
  -> query vm-registry for profile at that workspace
  -> return "profile:select" or "host" or "router"
  -> launch app on appropriate target
```

**workspace-desc module** (status bar) - Shows workspace label (e.g., "BROWSING") with colored underline:

```bash
# Runtime lookup (no hardcoded values)
jq -r --argjson w "$ws" \
  'to_entries[] | select(.value.workspace == $w) | .value.label' \
  /etc/hydrix/vm-registry.json
```

**focus module** (status bar) - Shows which VM type is focused on each workspace, using the same registry lookup.

**focus menu** (launcher) - Press `Mod+F4` to enter focus mode. The menu is built by scanning vm-registry for all profile VMs.

### Active VM Tracking

For workspace types that support multiple VMs (pentest, browsing, dev), `hypr-ws-app` remembers your last-used VM in `~/.cache/hydrix/active-vms.json`.

**Selection logic**:
1. If active VM is set and still running → use it
2. If active VM stopped → find all running VMs of that type
   - Exactly one → use it, update active
   - Multiple -> show launcher selection menu, update active
   - None → fall back to host, clear active

**Manual VM selection**: Use `vm-select` (or `Mod+Shift+p` on a VM workspace) to choose which VM is "active" for that type.

### Launch Flow

```
Super+Return
  -> hypr-ws-app alacritty
  -> detect focused workspace
  -> query vm-registry for workspace->VM mapping
  -> if VM not running: notify "use shard start <vm>", exec host terminal
  -> if waypipe-connect not running: start it (setsid, background), wait 1s
  -> poll vsock:14509 STATUS every 1s until "waypipe" (up to 20s)
  -> send "alacritty" to vsock:14508 (waypipe-launch)
  -> VM runs alacritty with WAYLAND_DISPLAY=waypipe-0
  -> window appears on host desktop, compositor routes it to correct workspace
```

### waypipe VM Forwarding

VM apps appear as individual windows on the host desktop with no visible border between "VM app" and "host app".

**Architecture:**

```
VM side (waypipe server):                   Host side (waypipe client):
  App -> WAYLAND_DISPLAY=waypipe-0             waypipe --vsock --socket <PORT> client
  waypipe --vsock --socket <PORT> server        ↑ listens; VM connects to this
    -> connects to host vsock:<PORT>           forwards to $WAYLAND_DISPLAY
```

The VM's waypipe server connects *out* to the host (VM→HOST vsock works because `vhost_vsock` is loaded on the host). The host's waypipe client listens on a per-VM vsock port.

**Session lifecycle:**

| Event | What happens |
|-------|-------------|
| `shard start <vm>` | Polls `PING` on vsock:14509 until VM responds `OK`, then starts `waypipe-connect <vm>` in background + sends notification |
| `waypipe-connect` starts | Starts host-side `waypipe client` listener, sends `waypipe-reconnect` to VM via vsock:14509 |
| VM receives `waypipe-reconnect` | Restarts `waypipe-vsock`; VM's waypipe server connects out to host vsock port |
| Compositor starts (VMs already running) | `waypipe-connect-all` spawns one poller per running VM; each polls `PING->OK` then starts `waypipe-connect` immediately |
| App launched | `hypr-ws-app` sends command to vsock:14508; VM runs app under `WAYLAND_DISPLAY=waypipe-0` |
| Connection drops | VM `waypipe-vsock` has `Restart=always`; host `waypipe-connect` has restart loop - both self-heal |
| `exit-wayland` | Kills all `waypipe-connect` processes; pushes `stop` to VMs; unsets `WAYLAND_DISPLAY` |

**Display mode selection (vsock:14509):**

The `display-mode` service on each VM accepts these commands:

| Command | Effect |
|---------|--------|
| `waypipe` | Starts/restarts waypipe-vsock + waypipe-launch |
| `waypipe-reconnect` | Unconditional restart, used by `waypipe-connect` on startup/reconnect |
| `STATUS` | Returns `"waypipe"` or `"none"` |
| `stop` | Stops all display services (WM exiting) |
| `PING` | Returns `"OK"` (VM readiness check) |

**Known gotcha \- `set -e` and the restart loop:**

`waypipe-connect` uses `set -euo pipefail`. The `waypipe client` command exits non-zero when the VM disconnects cleanly. Without `|| true` on the waypipe invocation, the bash wrapper exits silently and the restart loop never runs - leaving the host with no active tunnel while `pgrep` still finds nothing, causing `hypr-ws-app` to keep trying to start the tunnel from scratch. The fix: `waypipe client || true` in the while loop.

**Known gotcha \- STATUS false positive:**

`STATUS` checks both `[[ -S /run/user/1000/waypipe-0 ]]` AND `systemctl is-active --quiet waypipe-vsock`. Checking only the socket file is insufficient, it can persist after the service has stopped (crashed, or stopped by `stop` push). If STATUS incorrectly returns `"waypipe"`, `hypr-ws-app` proceeds to launch the app which then fails silently (app starts in VM but no window appears on host).

### waypipe - VM-Side Services

Three systemd services run in each graphical profile VM:

**`display-mode.service`** - runs as root, listens on vsock:14509. Handles mode switching and readiness signalling. Accepts: `PING` (returns `OK`), `STATUS` (returns `waypipe`/`none`), `waypipe` (starts/restarts waypipe-vsock + waypipe-launch), `waypipe-reconnect` (restarts waypipe-vsock if socket missing, leaves running apps alive otherwise), `stop` (stops all display services, leaves VM in neutral state ready for next start), `JOURNAL_WAYPIPE` (returns waypipe-vsock journal for remote diagnostics).

Runs as root because starting/stopping system services requires it. STATUS returns `"waypipe"` only when both `/run/user/1000/waypipe-0` exists AND `waypipe-vsock` is active - checking the socket file alone is insufficient since it can persist after the service crashes.

**`waypipe-vsock.service`** - runs as the user, started on-demand by display-mode. Connects outward to the host (CID 2) on the per-VM waypipe port (`14600 + CID - 100`). Key details:
- `ExecStartPre`: creates `/run/user/1000/` and removes any stale `waypipe-0` socket from a previous session
- `--display waypipe-0`: creates the Wayland proxy socket that apps inside the VM connect to via `WAYLAND_DISPLAY=waypipe-0`
- `--title-prefix "[vmname] "`: derived at build time from `hydrix.vmType` (e.g. `[browsing] `), **not** from the VM's hostname/`storeName` - those now carry the per-machine serial suffix (`microvm-browsing-<serial>`, see [§ VM Naming and Machine Identity](#vm-naming-and-machine-identity)), which would break the title match below if used directly. `vmType` is set independently by each profile's own `default.nix`, so it stays a clean, machine-independent name (`browsing`, `pentest`, ...) regardless of the per-machine flake-attribute name. This prefix is how the host compositor routes VM windows to the correct workspace via `for_window` rules
- `Restart=always`, `RestartSec=5s`: self-heals if the tunnel drops

**`waypipe-launch.service`** - runs as the user, listens on vsock:14508. Receives one-line app launch commands from the host. On receipt:
1. Waits up to 5s for `/run/user/1000/waypipe-0` to exist
2. Runs the command with `WAYLAND_DISPLAY=waypipe-0`, `XDG_RUNTIME_DIR=/run/user/1000`, and correct nix profile `PATH`
3. Uses `setsid` to detach the launched app from the socat connection - the app keeps running after socat closes

### waypipe - Host-Side Scripts

**`waypipe-connect <vm-name>`** - establishes and maintains the host-side tunnel:
1. Looks up the VM's CID from `/etc/hydrix/vm-registry.json`
2. Kills any stale waypipe process on the per-VM port
3. Starts `waypipe --vsock --socket PORT client` (listening for VM's outbound connection)
4. After 1s (background), pushes `waypipe` mode to the VM via vsock:14509
5. Restart loop: if waypipe exits (VM disconnect/restart), restarts it automatically - requires `waypipe client || true` so the `set -euo pipefail` wrapper does not exit on non-zero waypipe exit

**`hypr-ws-app <command>`** - workspace-aware app launcher:
1. Detects focused workspace via `hyprctl activeworkspace -j`
2. Looks up which VM owns that workspace in `vm-registry.json`
3. If `waypipe-connect` is not running for that VM, starts it and waits for the tunnel
4. Polls vsock:14509 `STATUS` up to 20s until it returns `"waypipe"`
5. Sends the command to vsock:14508 (`waypipe-launch`)

**`vm-push-display-mode`** - pushes `waypipe` mode to all running profile VMs via vsock:14509. Called at Hyprland startup so VMs already running when the compositor starts get pinged immediately.

### waypipe - Window Routing

VM windows are routed to the correct workspace by the compositor via title-prefix matching. The title prefix is set by `waypipe --title-prefix "[browsing] "` in `waypipe-vsock.service`. Compositor config:

```nix
# windowrulev2 in modules/hyprland.nix
windowrulev2 = [
  "workspace 3, title:^\[browsing\]"
  "workspace 2, title:^\[pentest\]"
  # etc - generated from vm-registry at build time
];
```

Rules are generated at build time from `vm-registry.json` so adding a new profile VM automatically adds the corresponding window routing rule after a rebuild.

### waypipe - Session Cleanup

A persistent `WAYLAND_DISPLAY` in the systemd user environment after the compositor exits causes problems for anything gated on `ConditionEnvironment=!WAYLAND_DISPLAY`. The session wrapper handles cleanup:

**`hyprland-session`** - wrapper script that starts the compositor and on exit:
1. Kill all `waypipe-connect` processes
2. Push `stop` to all running VMs via vsock:14509 (VMs stop display services, return to neutral state)
3. Unset `WAYLAND_DISPLAY` and `DISPLAY` from the systemd user environment
4. Drop back to TTY

**`exit-wayland`** - can be called from any terminal to perform the same cleanup without killing the compositor, then sends the compositor an exit signal.

### Adding a New Profile VM

**Use the scaffold script**, it auto-discovers the next free CID/workspace, creates all files, and stages them for git:

```bash
new-profile myprofile
```

The script scans existing profiles for the next free CID (starts at 107), prompts for any values it can't auto-derive, copies `templates/profiles/_template/`, substitutes `__PLACEHOLDER__` values, and runs `git add`. Profile VMs are **auto-discovered** by the flake, no manual wiring in `flake.nix` required.

**After scaffolding, complete integration manually:**

1. Declare in `machines/<serial>.nix` (optional, only for non-default settings): `hydrix.microvmHost.byName.myprofile = { autostart = false; };`
2. Customise `profiles/myprofile/default.nix` ,colorscheme, RAM/vCPUs, packages
3. Add VPN if needed: `hydrix.router.vpn.mullvad.bridges.myprofile = ./conf;`
4. Rebuild in order (router and files VM have TAPs baked into their QEMU runner):
```bash
rebuild                       # creates bridge, updates tapLookupScript + vm-registry
shard rebuild router files      # picks up new subnet TAP + new bridge leg
shard build myprofile && shard start myprofile
```

**What auto-adapts after rebuild** (no manual wiring needed):
- `hypr-ws-app` routes workspace -> new VM (reads vm-registry at runtime)
- status bar `workspace-desc` shows new label; `focus` shows new VM type
- focus menu includes new VM
- `hydrix-switch` and `router-status` include the new bridge

**What you add manually:**
- Dedicated keybindings (e.g., `Mod+Control+b` always opens browser on browsing VM)
- App-specific shortcuts if you want them beyond workspace-routing

---

## Lockscreen

The lockscreen uses i3lock-color with pywal integration:

- **Activation**: `Mod+Shift+e` or `hydrix-lock`
- **Auto-lock**: Configurable idle timeout (default 600 seconds)
- **Features**:
  - Screenshot with pixelation blur
  - Clock display with pywal colors
  - Custom text overlays

### Configuration

```nix
hydrix.graphical.lockscreen = {
  idleTimeout = 600;               # null to disable auto-lock
  font = "CozetteVector";
  fontSize = 143;
  clockSize = 104;
  text = "Papers, please";
  wrongText = "Ah ah ah! You didn't say the magic word!!";
  verifyText = "Verifying...";
  blur = true;
};
```

---

## Keybindings

### Window Management

| Key | Action |
|-----|--------|
| `Mod+Return` | Terminal (workspace-aware) |
| `Mod+Shift+Return` | Terminal (always on host) |
| `Mod+s` | Floating terminal |
| `Mod+q` | Kill window |
| `Mod+f` | Fullscreen |
| `Mod+Shift+space` | Toggle floating |
| `Mod+h/j/k/l` | Focus direction |
| `Mod+Shift+h/j/k/l` | Move window |
| `Mod+c` | Split vertical |
| `Mod+v` | Split horizontal |
| `Mod+1-0` | Switch workspace |
| `Mod+Shift+1-0` | Move to workspace |
| `Mod+Shift+arrows` | Adjust gaps |

### Applications

| Key | Action |
|-----|--------|
| `Mod+d` | Launcher (workspace-aware: host launcher or VM app menu) |
| `Mod+b` | Firefox |
| `Mod+o` | Obsidian |
| `Mod+Shift+f` | File manager (joshuto) |
| `Mod+Shift+m` | VM app launcher (vm-launch) |
| `Mod+z` | Zathura (PDF viewer) |
| `Mod+m` | Hydrix TUI |

### System

| Key | Action |
|-----|--------|
| `Mod+Shift+e` | Lock screen |
| `Mod+Shift+s` | Suspend |
| `Mod+Shift+v` | Reload display config |
| `Mod+w` | Random wallpaper |
| `Mod+F1/F2/F3` | Volume down/up/mute |
| `Mod+F5/F6` | Color temperature down/up |
| `Mod+F7/F8` | Brightness down/up |
| `Mod+F9` | Monitor arrangement GUI (`monitor-layout gui`) |
| `Mod+F12` | Screenshot |

### Configuration Editing

| Key | Action |
|-----|--------|
| `Mod+Shift+p` | Edit status bar config |
| `Mod+Shift+n` | Edit nix machine config |

---

## Scripts Reference

All scripts are wrapped via Nix and available in PATH after installation.

### Build & System

| Command | Purpose |
|---------|---------|
| `rebuild [mode]` | Rebuild host system (lockdown/administrative/fallback) |
| `nixbuild [mode]` | Alias for `rebuild` (backwards compat) |
| `build-base --type <t>` | Build libvirt base image |
| `deploy-vm --type <t>` | Deploy libvirt VM instance |
| `rebuild-libvirt-router` | Rebuild libvirt router (if enabled) |

### Mode Switching

| Command | Purpose |
|---------|---------|
| `hydrix-switch <mode>` | Live switch between lockdown/administrative/fallback |
| `hydrix-mode` | Show current mode and available modes |
| `router-status` | Show router VM and bridge status |

### WiFi Management

| Command | Purpose |
|---------|---------|
| `wifi-sync` | Show status: current SSID, known networks, router connections not yet saved |
| `wifi-sync add SSID PASSWORD` | Push network to router NM, save to credential store |
| `wifi-sync pull` | Merge all router NM connections into credential store |
| `wifi-sync list` | Show known networks in credential store |
| `wifi-sync remove SSID` | Remove a network from credential store and router NM |

The credential store is `secrets/wifi.yaml` (sops), created on the first save. See
[WiFi Credential Management](#wifi-credential-management-wifi-sync).

### MicroVM

| Command | Purpose |
|---------|---------|
| `shard <cmd>` | MicroVM management CLI |
| `shard build <name>` | Build/rebuild VM |
| `shard start <name>` | Start VM (polls PING->OK, starts display tunnel) |
| `shard app <name> <cmd>` | Launch app in VM |
| `shard stop <name>` | Stop VM |

### Package Sync (vm-dev workflow)

| Command | Purpose |
|---------|---------|
| `vm-sync list` | List staged packages from running VMs |
| `vm-sync pull <pkg> --target <type>` | Pull to profile packages |
| `vm-sync status` | Show packages per profile |
| `vm-sync-tui` | Interactive package sync TUI |

### Colorscheme

| Command | Purpose |
|---------|---------|
| `walrgb <image>` | Apply colorscheme from image |
| `randomwal` | Random wallpaper colorscheme |
| `restore-colorscheme` | Revert to configured scheme |
| `refresh-colors` | Reload all apps |
| `save-colorscheme <name>` | Save current as scheme |

### VPN

| Command | Purpose |
|---------|---------|
| `vpn-assign <bridge> <wg-bridge\|direct>` | Route bridge through tunnel or direct |
| `vpn-assign --persistent <bridge> <target>` | Persist assignment across reboots |
| `vpn-assign list-mullvad` | List configured exit nodes |
| `vpn-status` | Show all bridge assignments and tunnel state |

See [Mullvad VPN](#mullvad-vpn) for full setup instructions.

### Power

| Command | Purpose |
|---------|---------|
| `power-mode <profile>` | Switch power profile (powersave/balanced/performance) |

### Utilities

| Command | Purpose |
|---------|---------|
| `hydrix-tui` | Unified VM management TUI |
| `hydrix-lock` | Activate lockscreen |
| `vm-status` | Show system status (bridges, VMs, etc.) |
| `display-setup` | Reconfigure displays/status bar |
---

## Quality of Life

### Monitor Layout

A newly connected monitor is normally placed by Hyprland's own `auto` heuristic (the
framework's wildcard `monitor = ,preferred,auto,1` rule), and a manual `hyprctl keyword
monitor` reposition is pure runtime state - it doesn't survive the next `hyprctl reload`
(colour changes, VM-registry regen, etc. all trigger one), so it silently resets.

`monitor-layout` remembers a position per physical monitor, matched by its EDID
`description` rather than its port name (`DP-1`/`HDMI-A-1`), so the same monitor keeps its
saved position regardless of which port or dock it's plugged into. Saved positions are
written as explicit `desc:`-matched rules into `~/.config/hypr/monitor-layout.conf`, sourced
into `hyprland.conf` after the framework's wildcard fallback - so a position is part of the
actual config Hyprland re-reads, not a one-off runtime change that the next reload wipes out.

| Command | Purpose |
|---------|---------|
| `monitor-layout set <pos> [name]` | Position a monitor: `left`/`right`/`top`/`bottom`/`above`/`below`/`auto`/`WxH`. Defaults to the focused monitor if `name` is omitted. |
| `monitor-layout gui` | Launch `nwg-displays` for drag-and-drop arrangement; layout is captured and saved on exit. Bound to `Mod+F9`. |
| `monitor-layout apply` | Re-write the config snippet from saved state and force a reload. |
| `monitor-layout list` | Show saved positions. |
| `monitor-layout forget <match>` | Drop a saved entry (substring match on description). |

Waybar doesn't reposition itself when monitors change - `monitor-layout set`/`gui` restart
it directly, and `waybar-monitor-watch` restarts it automatically on any monitor
plug/unplug (Hyprland re-applies the saved `desc:` rule to a reconnecting monitor on its
own, since it's already part of the loaded config).

---

## Troubleshooting

### Files VM Transfer Fails (`curl rc=7`)

`curl rc=7` means the destination VM isn't reachable. The files VM reaches each profile VM at `<subnet>.10` over a dedicated TAP on that bridge.

**Check 1 - TAP on correct bridge:**
```bash
bridge link show | grep mv-files   # Each should say "master br-<profile>"
```
If any TAP shows the wrong bridge, trigger the repair service:
```bash
sudo systemctl restart microvm-tap-bridges
bridge link show | grep mv-files   # Verify
```
If that doesn't fix it, the lookup script may not know about the profile yet (host not rebuilt after adding the profile). Run `rebuild` first, then restart the repair service.

**Check 2 - Profile VM has correct static IP:**
From the files VM console (`shard console microvm-files`), ping the target VM:
```bash
ping 192.168.102.10   # Replace with target subnet
```
If unreachable, the profile VM may have the wrong IP. Verify `hydrix.networking.vmSubnet = meta.subnet` is set in `profiles/<name>/default.nix`, that line drives static IP derivation automatically. Rebuild and restart the profile VM if it was missing.

**Check 3 - Files-agent responding on profile VM:**
```bash
# From host:
echo "PING" | socat -T5 - VSOCK-CONNECT:<cid>:14506
# Expected: PONG
```
Port 8888 on each profile VM only accepts connections from the files VM's `.2` address on that bridge. If the files VM TAP was on the wrong bridge it had the wrong source IP, and iptables would drop it even if the VM was otherwise reachable.

### MicroVM Won't Start

```bash
# Check logs
shard logs <name>

# Verify vsock CID is unique
shard list

# Ensure host modules are loaded
lsmod | grep vhost_vsock
```

### Waypipe: App Launches But No Window Appears

The app was accepted by `waypipe-launch` but no window appeared on the host. The waypipe tunnel is broken.

```bash
# 1. Check tunnel status from the VM side
printf 'STATUS\n' | socat -T3 - VSOCK-CONNECT:<CID>:14509
# Expected: "waypipe"
# If "none": waypipe-vsock is not running in the VM

# 2. Check if waypipe-connect is alive on the host
pgrep -af "waypipe-connect"

# 3. Check the waypipe-connect log for silent exits
cat /tmp/waypipe-connect-<vm-name>.log

# 4. Check waypipe-vsock journal inside the VM
printf 'JOURNAL_WAYPIPE\n' | socat -T3 - VSOCK-CONNECT:<CID>:14509

# 5. Manual reconnect (kills stale tunnel, starts fresh)
waypipe-connect <vm-name>   # foreground - Ctrl+C when done
```

**Root causes:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `waypipe-connect` log empty after one entry | `set -e` killed script on VM disconnect | Ensure `waypipe client \|\| true` in restart loop |
| STATUS returns `"waypipe"` but apps don't appear | Stale socket file, service actually dead | STATUS now checks `systemctl is-active waypipe-vsock` too |
| STATUS returns `"none"` indefinitely | `display-mode` not receiving push, or VM not booted | Check `pgrep -af waypipe-connect`; restart `shard start` |

### Waypipe: hypr-ws-app Errors "waypipe not ready after 20s"

```bash
# Verify the VM has display-mode service (waypipe-vm.nix must be imported)
printf 'PING\n' | socat -T3 - VSOCK-CONNECT:<CID>:14509
# Expected: "OK" - if no response, waypipe-vm.nix is not in the VM profile

# Check waypipe-connect log
cat /tmp/waypipe-connect-<vm-name>.log

# Manually push waypipe mode to the VM
vm-push-display-mode waypipe <profile-name>

# Check if host vsock port is being listened on
ss -lnx | grep vsock   # or: socat /dev/null VSOCK-LISTEN:<PORT>,reuseaddr & sleep 1; kill %1
```

### WiFi Not Working in Router

```bash
# Verify VFIO passthrough
lspci -nnk | grep -A3 Wireless

# Check router console
shard console router

# Verify NetworkManager
nmcli device status
```

### Changed WiFi Password Not Taken

At boot the router adds each network from `secrets/wifi.yaml` that NetworkManager does not
already have; an existing profile with the same name is left alone. The router reverts to its
baseline on every boot, so after `wifi-sync add` and a host `rebuild`, a router restart
(`shard -R router`) is enough. With `hydrix.router.persistence.enable` the old profile survives
on the volume: replace it with `wifi-sync remove SSID` followed by `wifi-sync add SSID PASSWORD`.

### Host Has No Internet (Expected in Lockdown)

This is the intended behavior. Use the builder VM:

```bash
shard builder build <target>
```

Or switch to administrative mode:

```bash
rebuild administrative
# Or live switch without rebuild:
hydrix-switch administrative
```

### Colors Not Syncing to VM

```bash
# In VM - check mode
get-colorscheme-mode

# Force sync
wal-sync

# Check host colors are active
ls ~/.cache/wal/.active
```

### Display Scaling Issues

```bash
# Recalculate and apply
display-setup

# Adjust resolution step
display-setup --step -1   # Higher resolution
display-setup --step +1   # Lower resolution

# Check current values
cat ~/.config/hydrix/scaling.json
```

---

## Wayland Stack (Hyprland)

Hyprland is the only supported compositor. VM apps are forwarded to the host desktop via
**waypipe**, appearing as individual native windows. The legacy Sway and i3 stacks (and
xpra, the X11 forwarding mechanism i3 used) have been fully removed from the framework -
there is no `hydrix.sway.enable` or `hydrix.i3.enable` option anymore.

### Enabling

```nix
# machines/<serial>.nix
hydrix.hyprland.enable = true;  # Wayland, VM apps forwarded via waypipe
```

### Programs

| Component | Program |
|-----------|---------|
| Compositor | Hyprland |
| Status bar | waybar |
| Launcher | wofi |
| Lockscreen | hyprlock |
| VM forwarding | waypipe |

Start the session:
```bash
hyprland-session   # cleans up waypipe + env on exit
```

### Module Overview

| Module | Location | What it provides |
|--------|----------|-----------------|
| `wm/hyprland/waypipe.nix` | `theming/wm/hyprland/waypipe.nix` | Host-side scripts: `waypipe-connect`, `waypipe-connect-all`, `hypr-ws-app`, `vm-push-display-mode`, `exit-wayland`; PipeWire vsock audio bridge (`pulse-vsock`) |
| `vm/display/waypipe-vm.nix` | `vm/display/waypipe-vm.nix` | VM-side systemd services: `display-mode` (vsock:14509), `waypipe-vsock`, `waypipe-launch` (vsock:14508), `pulse-vsock` (PulseAudio bridge to host) |

**`theming/wm/hyprland/waypipe.nix`** is auto-imported via `theming/wm/hyprland/default.nix` and activates when `hyprland.enable` is true.

**`waypipe-vm.nix`** is auto-imported by `vm-base.nix`/`microvm-profile-base.nix` for all profile VMs.

### Display Mode Switching

The host connects to each VM's `display-mode` service (vsock:14509) to switch display services. `waypipe-connect` sends `waypipe-reconnect` directly to the VM, bypassing `vm-push-display-mode`. The VM unconditionally restarts `waypipe-vsock` and connects to the host listener.

```
shard start <vm>
  → polls PING→OK on vsock:14509
  → starts waypipe-connect (sends waypipe-reconnect internally)
```

Manual overrides:
```bash
vm-push-display-mode            # pushes waypipe mode
vm-push-display-mode stop       # stop all display services in all VMs
waypipe-connect <vm>            # manually start/restart waypipe for one VM
waypipe-connect-all             # connect waypipe for all running profile VMs
```

### Clipboard Isolation (hypr-clip-guard)

waypipe forwards the Wayland clipboard protocol between VMs and the host compositor. Without isolation, copying text in one VM makes it available to every other VM - a compromised VM could silently harvest passwords or sensitive data from unrelated sessions.

The `hypr-clip-guard` Hyprland C++ plugin hooks all clipboard delivery methods inside the compositor to enforce per-VM isolation. It is loaded automatically via `hydrix-generated.conf` - no user configuration needed.

#### Policy

| Source → Destination | Result |
|----------------------|--------|
| VM → same VM | **Allowed** (intra-VM copy/paste) |
| VM → host | **Allowed** (paste on host terminal) |
| Host → focused VM | **Allowed** (paste into active VM) |
| VM-A → VM-B | **Blocked** (cross-VM isolation) |
| VM-A → VM-B, bridge armed | **Allowed once** (`Mod+Shift+P`, see One-Shot Cross-VM Bridge below) |
| microVM ↔ libvirt VM | **Blocked** (libvirt VMs are their own group, see below) |

"Host" means any window without a `[vm-name]` title prefix. VM group identity comes from the waypipe `--title-prefix "[vm-name] "` convention - the plugin extracts the group from the window title, falling back to PID/PPID lineage for windowless clients (e.g. `wl-paste` through waypipe).

**Libvirt VMs (virt-manager/virt-viewer):** these have no waypipe title prefix to tag them with, since libvirt controls the window title, not Hydrix. Without special handling they'd fall through to the untagged "host" default and become an unrestricted bridge between otherwise isolated microVM groups, since any group can always reach "host" and "host" can always reach whatever's currently focused. Instead, `classifyWindow()` checks window **class** first: any window whose class contains `virt-manager`, `virt-viewer`, or `remote-viewer` is tagged into its own `"libvirt"` group before falling back to the title-prefix check, so it's isolated from every microVM group exactly like microVM groups are isolated from each other. No changes to the allow/block policy itself were needed, correct tagging alone was sufficient.

**Known limitation:** class-based tagging can't distinguish *which* libvirt VM a window belongs to, so all libvirt VM instances currently share the same `"libvirt"` group and can freely clipboard-share with each other. Isolation from microVMs (and from other libvirt guests, via the host as an explicit intermediary) holds regardless, but per-instance libvirt isolation is unimplemented.

#### One-Shot Cross-VM Bridge

Direct VM-A to VM-B transfer is blocked by default (see Policy above), which otherwise forces a host-hop workaround: copy in VM-A, paste on host, copy on host, paste in VM-B. `Mod+Shift+P` (`vm-clip-bridge`, wrapping `hyprctl clipguard bridge`) arms a narrow, auto-expiring exception instead: copy in VM-A, press the keybind while VM-A is still focused, then focus VM-B and paste normally. That one delivery is allowed, then the bridge disarms itself and full isolation reverts.

Arming only succeeds if the currently focused client's group matches the clipboard's live source group right now, so firing the keybind without having actually copied something from the focused VM fails cleanly ("nothing to bridge") instead of arming stale state. The bridge expires after 20 seconds if never used (checked lazily, no timer/event-loop hook). Consumption is restricted to the two focus-gated hooks (`CWLDataDeviceProtocol`, `CPrimarySelectionProtocol`) only, deliberately excluding the broadcast data-control hooks (`CDataDeviceWLRProtocol`, `CExtDataDeviceProtocol`), since those aren't focus-gated and a background data-control client in an unrelated VM could otherwise consume the grant unattended.

Two accepted, bounded properties worth knowing: consumption fires on offer-delivery (triggered by focus landing on the recipient), not on an actual paste keystroke, since there's no lower-level hook to gate on the real paste gesture; this is no looser than the pre-existing host-mediated path, which has the same offer-on-focus granularity with an unbounded window. And arming doesn't pin a destination at arm time, whichever VM group next asks for the offer within the window receives it, since the destination isn't chosen until after arming by design.

#### Architecture

```
VM app copies text
  └─ waypipe server (VM) → vsock → waypipe client (host)
       └─ Hyprland compositor receives selection
            └─ hypr-clip-guard hooks fire on delivery
                 ├─ sendSelectionToDevice (4 protocols)
                 │    └─ checks source group vs recipient group
                 └─ sendInitialSelections (2 protocols)
                      └─ blocks cross-VM delivery on device creation
                           │
                      ┌────┴────┐
                    ALLOW     BLOCK
                  (same group   (cross-VM
                   or host)      transfer)
```

#### Protocols Hooked (6 total)

**`sendSelectionToDevice`** - called when clipboard data is delivered to a requesting client:

| Protocol | Used by |
|----------|---------|
| `CWLDataDeviceProtocol` | All apps (Ctrl+C/V) |
| `CPrimarySelectionProtocol` | Text selection (middle-click paste) |
| `CDataDeviceWLRProtocol` | wl-paste, cliphist (wlr-data-control) |
| `CExtDataDeviceProtocol` | Newer wl-paste (ext-data-control) |

**`sendInitialSelections`** - called when a new data device is created, delivering the current clipboard immediately:

| Protocol | Purpose |
|----------|---------|
| `CExtDataDevice::sendInitialSelections` | Blocks cross-VM delivery on ext device creation |
| `CWLRDataDevice::sendInitialSelections` | Blocks cross-VM delivery on wlr device creation |

Without `sendInitialSelections` hooks, new data devices (created when e.g. wl-paste starts) would receive the current clipboard directly, bypassing the `sendSelectionToDevice` checks entirely.

#### Source Tracking

The plugin tracks clipboard ownership using weak pointers (`WP<IDataSource>`) to the last selection and primary sources. When a client sets a new selection, the plugin records its VM group. On delivery, the stored source group is compared against the recipient's group.

Keyboard focus seeding: when keyboard focus changes, the plugin updates the source group from the focused client's group. This ensures the host→focused-VM path works correctly (host copies land in the focused VM on paste).

Windowless clients (waypipe's per-app forks, headless tools like `clip-test`'s `wl-paste --watch`) resolve their group via a PID, falling back to PPID, lookup cache. That cache entry must not outlive the process it was recorded for: PIDs get reused fast, especially under the churn of repeatedly launching short-lived headless clients, and a stale entry would silently hand an unrelated new client someone else's group. Every client the plugin ever caches a group for gets a real Wayland client-destroy listener (`wl_client_add_destroy_listener`) that invalidates its own PID cache entry, only if unchanged since written, the moment it exits. The PPID entry is deliberately left alone: it identifies a longer-lived shared parent process, not a `wl_client` itself, and other live children of the same parent still need it valid.

#### Debug Interface

```bash
hyprctl clipguard           # per-hook stats, client-group map, PID/PPID, event log
hyprctl clipguard bridge    # arm the one-shot cross-VM bridge from the focused VM
hyprctl -j clipguard        # JSON, either subcommand, includes a seq-numbered events array
clip-monitor-host           # host: live-tails the event log by polling hyprctl -j clipguard
```

`hyprctl clipguard` shows:
- Per-hook statistics (allowed/blocked counts for all 6 hooks)
- Client → group mapping with PID/PPID
- Current source groups (selection + primary), and current bridge arm state for each
- Timestamped event log (last 256 entries with HH:MM:SS.mmm)

`clip-monitor-host` is the more useful tool for live debugging: it polls the JSON form and prints only new events by their monotonic `seq`, so it reads like a live feed of every hook firing across all 4 protocols plus bridge arm/use/expire events, instead of a manually re-diffed snapshot. A VM-side `clip-test` exists too (`wl-paste --watch` based), but it can only ever see the two data-control protocols, never the interactive one (`wl_data_device`, what Ctrl+C/V actually uses), since that protocol is only ever pushed to the focused client and isn't passively observable by a bystander. `clip-test` opens with a `wayland-info` dump of clipboard-related globals so protocol availability inside a given VM session is directly visible rather than inferred from silence.

**Testing gotcha:** after rebuilding the plugin, do a full Hyprland restart, not `hyprctl plugin unload` followed by `load`. Live reload can leave the underlying `CFunctionHook` trampolines corrupted, silently disabling all blocking (not just anything related to a specific change) while `hyprctl plugin list` still reports the plugin as loaded. This produces a false "everything leaks" result across every group pair, a full restart resolves it with no code changes needed.

#### Vault Interaction

`vault-pick` copies with `wl-copy` on the host after refocusing the window it was opened from, so the credential is locked to that window's group and not replayed to windows focused later. The 30-second auto-clear (only if the clipboard still holds it) limits the exposure window further.

#### Key Files

| File | Purpose |
|------|---------|
| `theming/wm/hyprland/plugins/hypr-clip-guard/src/main.cpp` | Plugin source (C++) |
| `theming/wm/hyprland/plugins/hypr-clip-guard/CMakeLists.txt` | CMake build config |
| `theming/wm/hyprland/hyprland.nix` | Builds plugin via `mkHyprlandPlugin`, loads in `hydrix-generated.conf` |

### Keybindings

User keybindings live in `modules/hyprland.nix` in your hydrix-config.

### Internal Display Scaling (Wayland)

Hyprland uses per-output scale. External monitors are unaffected. (The option names below
predate the migration off Sway and haven't been renamed, but they apply to Hyprland.)

```nix
# machines/<serial>.nix
hydrix.graphical.scaling.swayInternalScale  = 1.25;   # 25% larger UI (crisp, native res kept)
hydrix.graphical.scaling.swayInternalMode   = "1280x800"; # OR: change actual hw resolution
hydrix.graphical.scaling.swayInternalOutput = "eDP-1";    # default; run: hyprctl monitors
```

`swayInternalScale` and `swayInternalMode` are mutually exclusive - scale takes priority when both are set.

### Audio Forwarding (waypipe mode)

waypipe carries Wayland display only \- it has no audio channel. A parallel **PulseAudio-over-vsock** bridge on port 14505 provides audio to VM apps launched via waypipe.

**Architecture:**

```
VM app
  └─ PULSE_SERVER=unix:/run/user/1000/pulse/host-native
       └─ socat UNIX-LISTEN:host-native → VSOCK-CONNECT:2:14505
                                                    │
                                          vsock port 14505
                                                    │
                                         Host pulse-vsock user service
                                           socat VSOCK-LISTEN:14505 → vm-pulse-gate
                                           (peer CID must have audio = true) → pulse/native
                                                                              │
                                                                    PipeWire (host)
                                                                    (auth.anonymous = true)
```

**Host side (`waypipe-host.nix`):**

- `pulse-vsock` user service: `VSOCK-LISTEN:14505` (at most 8 connections) runs `vm-pulse-gate` per connection. The gate resolves the VM from the vsock peer CID in `/etc/hydrix/vm-registry.json` and only connects VMs whose `meta.nix` sets `audio = true` to `$XDG_RUNTIME_DIR/pulse/native` (host PipeWire); everything else is rejected and logged.
- PipeWire anonymous auth enabled on its unix socket so VM clients (which have no host cookie) are accepted:
  ```nix
  services.pipewire.extraConfig.pipewire-pulse."10-vm-audio" = {
    "pulse.properties"."server.address" = [
      { "address" = "unix:native"; "auth.anonymous" = true; }
    ];
  };
  ```
  Any client that reaches the socket is accepted without a cookie, so the gate above is what decides which VMs get host audio (speakers and microphone).

**VM side (`waypipe-vm.nix`):**

- `pulse-vsock` system service: creates `/run/user/1000/pulse/host-native` → `VSOCK-CONNECT:2:14505`
- Waits for `/run/user/1000/pulse/native` (the VM's own PipeWire socket) before creating its socket. This avoids a race where `systemd --user` initialises the user session and wipes `/run/user/1000` after the socket was created.
- Uses a separate path (`host-native`) to avoid conflicting with the VM's own `pipewire-pulse` which owns `pulse/native`.
- `PULSE_SERVER=unix:/run/user/1000/pulse/host-native` is injected into the environment of every app launched via `waypipe-launch`.

**Lifecycle:**

| Event | Audio action |
|-------|-------------|
| `display-mode` receives `waypipe` or `waypipe-reconnect` | Starts `pulse-vsock` in VM |
| `display-mode` receives `stop` | Stops `pulse-vsock` alongside all display services |

Audio is **off unless a VM opts in**: set `audio = true;` in its `meta.nix`. That one value turns on the guest's PipeWire stack (`hydrix.microvm.audio.enable`) and admits its CID at the host gate. Rebuild the host (registry) and the VM after changing it.

### Notification Forwarding (waypipe mode)

VMs have no local notification daemon, so calling `notify-send` (or any app hitting
`org.freedesktop.Notifications`) fails with `NameHasNoOwner` unless this is enabled. When on,
the VM claims the `org.freedesktop.Notifications` D-Bus name itself and forwards each
`Notify()` call to the host over vsock instead of rendering anything locally: the VM never
draws a popup.

**Opt-in lives in the profile's `meta.nix`:**

```nix
# profiles/<name>/meta.nix
notifyForward = true;

# profiles/<name>/default.nix
hydrix.microvm.notifyForward.enable = meta.notifyForward;
```

The same `meta.nix` value feeds both sides: the VM-side relay
(`hydrix.microvm.notifyForward.enable`, default `false`) and the host registry
(`/etc/hydrix/vm-registry.json`, `notifyForward` field, default `false`), which is what the
host listener authorizes against. Task slots follow their base profile's value unless
`tasks/default.nix` sets `notifyForward`; `tasks/slots.nix` resolves it and `flake.nix` threads
it into both the task VM and its registry entry. If the two sides disagree, the host drops the notification and logs
a rejection.

**Architecture:**

```
VM app calls notify-send / Notification API
  └─ org.freedesktop.Notifications (session D-Bus)
       └─ notify-relay.py (python3-dbus, claims the bus name)
            └─ AF_VSOCK connect to host CID 2, port 14518
                                                    │
                                          vsock port 14518
                                                    │
                                    Host vm-notify-relay user service
                                      socat VSOCK-LISTEN:14518 → vm-notify-forward
                                        (authorize by peer CID, sanitize) → notify-send (host swaync)
```

**Host side (`theming/wm/hyprland/waypipe.nix`):**

Everything a VM sends is treated as untrusted: a compromised VM does not need the relay and
can connect to vsock:14518 directly with arbitrary JSON. The `vm-notify-relay` user service
(`socat VSOCK-LISTEN:14518,fork,max-children=8`) runs `vm-notify-forward` per connection, which:

- **Resolves the VM from the vsock peer CID** (`SOCAT_PEERADDR`, set by socat), looked up in
  `vm-registry.json`. The payload's own `vm` field is ignored, so a VM cannot label its
  notifications as another VM (e.g. `[vault]`) or as the host.
- **Accepts only registry entries with `notifyForward = true`.** Anything else is dropped and
  logged as `rejected notification from CID N` (`journalctl --user -u vm-notify-relay`).
- **Caps input:** 8 KiB per message, read with a 3 s timeout (a connection held open cannot
  pin a child), `app_name` 64 / `summary` 200 / `body` 1000 characters.
- **Escapes `&`, `<`, `>`** since swaync renders Pango markup, so VM text renders
  literally and cannot style itself to mimic another source.
- **Breaks URL prefixes** (`://`, `mailto:`, `www.`) with a zero-width space, so nothing on
  the host ever recognizes a VM-supplied link or host `file://` path as openable. Text looks
  unchanged; copied links carry the invisible character.
- **Caps urgency at `normal`** (`low` is kept), so a VM cannot pin sticky critical popups.
- **Rate-limits per VM:** a per-VM `flock` held for one second after each notification;
  anything arriving meanwhile is dropped, not queued.
- Calls `notify-send -u <urgency> --app-name=<app> --category=hydrix-vm-<vm> -- "[vm] summary" "body"`. The `--` and
  `--app-name=` form stop VM text that starts with `-` from being parsed as `notify-send`
  options (e.g. `--action` plus `--wait`, which would echo the user's click back to the VM).
  The summary is tagged `[vm] `, matching waypipe's own window-title prefix, and the category
  `hydrix-vm-<vm>` makes swaync draw that VM's border gradient (see "Notifications"). Both
  come from the CID-resolved name; the VM cannot set a category through the relay.

Only plain strings cross the boundary: icons, image data, hints and actions are dropped
VM-side, and nothing flows back to the VM.

**VM side (`vm/display/waypipe-vm.nix`):**

- `notify-relay` user service, gated by `hydrix.microvm.notifyForward.enable`: a small Python
  D-Bus service (`python3-dbus` + PyGObject) that registers itself as
  `org.freedesktop.Notifications` on the session bus and implements `Notify`,
  `GetCapabilities`, `CloseNotification`, `GetServerInformation` and the
  `NotificationClosed` signal.
- `GetCapabilities` returns `["body", "actions"]`. Firefox (which sends through `libnotify`,
  dlopened) marks every web notification clickable and falls back to its own in-browser popup
  window unless the server advertises `actions`. Actions are accepted but never invoked, since
  the host popup cannot click back into the VM.
- Emits `NotificationClosed` once the requested timeout lapses (5 s if none), since nothing is
  rendered locally to close it; without it `libnotify` clients keep every notification's
  listener alive indefinitely.
- Also implements `org.freedesktop.DBus.Properties` (`Get`/`GetAll`/`Set`, all effectively
  no-ops). GDBus-based clients (`GDBusProxy`) call `Properties.GetAll` while constructing a
  proxy, before ever calling `Notify()`; without a handler proxy construction fails and the app
  never sends anything.
- On `Notify()`, opens a short-lived `AF_VSOCK` connection to the host (CID 2, port 14518),
  ships the payload as one JSON line, and closes it. No persistent VM→host connection, no
  polling on either side.

Verified working for `notify-send`, GTK apps (`zenity`) and Firefox web notifications.

### Status Bar Notes

waybar is used as the status bar, managed via a systemd user service and restarted automatically on monitor add/remove events.

---

## Pentesting VM

The pentest profile template (`profiles/pentest/`) ships with BurpSuite pre-wired via
[burpsuite-nix](https://github.com/Red-Flake/burpsuite-nix), plus the Xwayland support it
needs to actually render. Both live in `profiles/pentest/burpsuite.nix` and
`profiles/pentest/xwayland.nix`, scoped to this one VM only.

### Why Xwayland

BurpSuite, Ghidra, and most Java-based reverse-engineering GUI tools are AWT/Swing
applications. Stock OpenJDK has no native Wayland backend, so these apps need a real X11
`DISPLAY` to render at all - under the Hyprland + waypipe stack (pure Wayland, no X11
anywhere by default), they fail outright with no window and, for BurpSuite specifically, a
`java.lang.Error: no ComponentUI class for: ...` crash partway through its own UI init.

A hand-rolled rootless Xwayland client of the VM's `waypipe-0` socket was tried first and
never got a single window mapped - waypipe is a generic Wayland *proxy*, not a compositor,
so it doesn't implement whatever rootless Xwayland needs for surface positioning. The
working fix is waypipe's own `--xwls` flag, which runs
[xwayland-satellite](https://github.com/Supreeeme/xwayland-satellite) alongside the
`waypipe server` process - the purpose-built way to forward X11 clients through a waypipe
tunnel. `xwayland.nix` overrides the VM's `waypipe-vsock` service to add `--xwls`.

`--xwls` only sets `$DISPLAY` for the one process waypipe directly execs as its server
command (normally a throwaway `sleep infinity`), not for any shell or app launched
afterwards. `xwayland.nix` works around this by having that placeholder process write the
resolved display value to `/run/user/1000/xwayland-display`, which is then read by:

- **Interactive shells** - via `programs.fish.interactiveShellInit`, so typing `burpsuite`
  in a VM terminal picks up `$DISPLAY` on login.
- **`waypipe-launch` (vsock:14508)** - the receiver behind mod+D / `wofi-launcher` /
  `hypr-ws-app`. This service builds its own environment from scratch and never goes
  through a login shell, so the fish fix above is invisible to it; it needs its own
  override (also in `xwayland.nix`) that reads the display file fresh on every launch
  request, matching Hydrix's shared `vm/display/waypipe-vm.nix` `waypipe-launch` service
  exactly plus that one line. Without this override, apps launched via the app-launcher
  keybind (rather than typed in a terminal) silently get no `$DISPLAY` and hang.

Also note: `waypipe execs "xwayland-satellite"` by bare name, and systemd services don't
inherit `/run/current-system/sw/bin` the way interactive shells do - `xwayland.nix` adds
`pkgs.xwayland-satellite` to the `waypipe-vsock` unit's `path` explicitly, or the service
fails with `Failed to run program "xwayland-satellite": No such file or directory`.

### Pinning burpsuite-nix

`burpsuite.nix` fetches burpsuite-nix directly:

```nix
burpsuite-nix = builtins.getFlake "github:Red-Flake/burpsuite-nix/<full-commit-sha>";
```

This is deliberately **not** a toplevel flake input. Passing it through `extraInputs` (the
mechanism `mkHost`/`mkMicroVM` use to thread flake inputs into per-VM/per-host builds) would
mean every VM and host build carries it, even though only the pentest VM uses it. Fetching
it inline with a full pinned commit SHA keeps it fully scoped to `profiles/pentest/` and
evaluates purely (no `--impure` needed, since the ref is a fully locked commit).

**To update:** replace the commit SHA in `burpsuite.nix` with a newer commit from the
burpsuite-nix repo, then rebuild. `nix flake update` does **not** touch this - it isn't a
flake input, so there's no lockfile entry tracking it. Bumping it is a manual edit.

### Isolation

Nothing outside `profiles/pentest/` references `burpsuite-nix` or `xwayland-satellite`: no
`extraInputs` site passes it to another VM or the host, and no other profile/infra/task VM's
config imports either file. The packages do get built into the shared `/nix/store` like
anything else (content-addressed, visible from every VM), but that's irrelevant - what
matters is that no other VM's NixOS config or closure references them, and none do.

### Clipboard isolation still applies

[`hypr-clip-guard`](#clipboard-isolation-hypr-clip-guard) classifies clients by their
window's title prefix (`[pentest] `, from waypipe's `--title-prefix`) at the real host
compositor, hooking all four Wayland clipboard-selection protocols directly. Since
`xwayland-satellite` is itself just another Wayland client of the same `waypipe-0`/vsock
tunnel, BurpSuite's window gets the same title prefix as any other forwarded pentest-VM
window and falls into the same isolation group automatically - the mechanism operates below
the Wayland-vs-X11 distinction entirely. Verify live with `hyprctl clipguard` while BurpSuite
is open; its client should show up tagged `pentest`, not `host`.

---

## Key Files

### User Configuration

| File | Purpose |
|------|---------|
| `~/hydrix-config/machines/<host>.nix` | Your machine configuration |
| `~/hydrix-config/profiles/<type>/` | Your VM profile customizations |
| `~/hydrix-config/profiles/<type>/packages/` | Custom packages (via vm-sync) |
| `~/hydrix-config/colorschemes/` | Custom colorschemes (override framework) |
| `~/hydrix-config/flake.nix` | Main flake (imports Hydrix) |

### Runtime State

| File | Purpose |
|------|---------|
| `~/.config/hydrix/scaling.json` | DPI scaling, font sizes, font family |
| `~/.config/alacritty/colors-runtime.toml` | VM runtime colors (imported by alacritty) |
| `~/.cache/wal/colors.json` | Active pywal colors |
| `~/.cache/wal/.active` | Marker that wal colors are active |
| `~/.cache/wal/.colorscheme-mode` | VM colorscheme inheritance mode |
| `~/.cache/hydrix/active-vms.json` | Workspace-VM tracking (hypr-ws-app) |
| `/var/lib/microvms/<name>/` | MicroVM persistent data |
| `/var/lib/microvms/<name>/config/.switch-reg` | Nix DB registration for live switch |
| `/var/lib/libvirt/base-images/` | Libvirt base images |
| `/etc/HYDRIX_MODE` | Current boot mode (lockdown/administrative/fallback) |
