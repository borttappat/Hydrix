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
- [Configuration](#configuration)
- [Colorscheme System](#colorscheme-system)
- [VM Theme Sync](#vm-theme-sync)
- [Font System](#font-system)
- [MicroVM Management](#microvm-management)
  - [Task Pentest VMs](#task-pentest-vms-per-engagement)
  - [Files VM (Encrypted Inter-VM Transfer)](#files-vm-encrypted-inter-vm-transfer)
  - [Hostsync VM (Host File Inbox)](#hostsync-vm-host-file-inbox)
  - [USB Sandbox](#usb-sandbox-microvm-usb-sandbox)
  - [Vault VM (Credential Store)](#vault-vm-microvm-vault)
  - [Builder VM](#builder-vm-lockdown-mode-builds)
- [Vsock Communication](#vsock-communication)
- [VM Store Sharing](#vm-store-sharing)
- [Build System](#build-system)
- [Shell](#shell)
- [Workspace Integration](#workspace-integration)
- [Lockscreen](#lockscreen)
- [Keybindings](#keybindings)
- [Scripts Reference](#scripts-reference)
- [Troubleshooting](#troubleshooting)

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
|   - Bridges: br-mgmt, br-pentest, br-comms, br-browse, br-dev,      |
|              br-shared, br-builder, br-lurking, br-files            |
+---------------------------------------------------------------------+
                            |
        TAP Interfaces (Router VM connects to each bridge)
                            |
         +---- br-mgmt (192.168.100.0/24) ------+
         |         ^ mv-router-mgmt              |
         +---- br-pentest (192.168.101.0/24) ---+
         |         ^ mv-router-pent              |
         +---- br-comms (192.168.102.0/24) -----+
         |         ^ mv-router-comm              |
         +---- br-browse (192.168.103.0/24) ----+
         |         ^ mv-router-brow              |--- Router VM (WiFi)
         +---- br-dev (192.168.104.0/24) -------+
         |         ^ mv-router-dev               |    CID: 200
         +---- br-shared (192.168.105.0/24) ----+
         |         ^ mv-router-shar              |    Subnets: 192.168.100-108.x
         +---- br-builder (192.168.106.0/24) ---+
         |         ^ mv-router-bldr              |
         +---- br-lurking (192.168.107.0/24) ---+
         |         ^ mv-router-lurk              |
         +---- br-files (192.168.108.0/24) ------+
                         ^ mv-router-file        |
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

### Router VM TAP Interfaces

The router VM has **one TAP interface per bridge**, acting as the DHCP/DNS gateway for each subnet:

| Router TAP | Bridge | Router IP | Subnet | Purpose |
|------------|--------|-----------|--------|---------|
| `mv-router-mgmt` | `br-mgmt` | 192.168.100.253 | 192.168.100.0/24 | Host management |
| `mv-router-pent` | `br-pentest` | 192.168.101.253 | 192.168.101.0/24 | Pentest VMs |
| `mv-router-comm` | `br-comms` | 192.168.102.253 | 192.168.102.0/24 | Comms VMs |
| `mv-router-brow` | `br-browse` | 192.168.103.253 | 192.168.103.0/24 | Browsing VMs |
| `mv-router-dev` | `br-dev` | 192.168.104.253 | 192.168.104.0/24 | Dev VMs |
| `mv-router-shar` | `br-shared` | 192.168.105.253 | 192.168.105.0/24 | Shared services |
| `mv-router-bldr` | `br-builder` | 192.168.106.253 | 192.168.106.0/24 | Builder VM |
| `mv-router-lurk` | `br-lurking` | 192.168.107.253 | 192.168.107.0/24 | Lurking VM |
| `mv-router-file` | `br-files` | 192.168.108.253 | 192.168.108.0/24 | Files VM |

Each TAP interface is created by the host before the router VM starts, then attached to its bridge via the TAP assignment system described below.

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
| Framework MACs | `02:00:00:01:XX:01` | `02:00:00:03:XX:01` |
| Extra profile MACs | `02:00:00:02:XX:01` | `02:00:00:04:XX:01` |
| Autostart | configurable | `false` (manual only) |
| VPN support | yes | no (intentionally minimal) |
| LAN IP assignment | systemd-networkd at boot (build-time) | systemd-networkd at boot (build-time) |
| WAN detection | runtime bash (`router-network-setup`) | none needed (LAN negation) |
| VPN routing | runtime bash (`vpn-boot-assign`) | not supported |
| dnsmasq config | runtime generated from build-time names | fully declarative (build-time) |

**How it works:**

```
Main router broken (bad config, crash, etc.)
  -> manually start stable: microvm start router-stable
  -> Conflicts= stops the main router if still running (VFIO can't be shared)

Done with stable, back to main router:
  -> microvm stop router-stable
  -> microvm start router
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
microvm build router-stable      # build the golden image
microvm start router-stable      # start manually (stops main router via Conflicts=)
microvm stop router-stable       # stop (main router can then be started)
microvm console router-stable    # serial console access
```

Short names accepted: `router-stable`, `stable-router`, `stable`.

> **CIDs and subnets are user-configurable.** Built-in profiles (browsing, pentest, dev, comms, lurking) ship with default CIDs/subnets but these are declared in each profile's `meta.nix` in your `hydrix-config/profiles/<name>/meta.nix`. The host module writes all profile metadata to `/etc/hydrix/vm-registry.json` at activation, all scripts, the status bar, and the WM read from there at runtime, never from hardcoded maps. Adding a new VM type requires only `profiles/<name>/meta.nix` + `profiles/<name>/default.nix` in your config.

### VM Registry (`/etc/hydrix/vm-registry.json`)

Generated at NixOS activation from all profile `meta.nix` files. Every runtime tool reads from here, no hardcoded CID or workspace maps anywhere in scripts or modules.

```json
{
  "pentest":  { "vmName": "microvm-pentest",  "cid": 102, "bridge": "br-pentest",  "subnet": "192.168.102", "workspace": 2, "label": "PENTEST",  "focusBorder": "orange" },
  "browsing": { "vmName": "microvm-browsing", "cid": 103, "bridge": "br-browse",   "subnet": "192.168.103", "workspace": 3, "label": "BROWSING", "focusBorder": "yellow" },
  "comms":    { "vmName": "microvm-comms",    "cid": 104, "bridge": "br-comms",    "subnet": "192.168.104", "workspace": 4, "label": "COMMS",    "focusBorder": "green"  },
  "office":   { "vmName": "microvm-office",   "cid": 107, "bridge": "br-office",   "subnet": "192.168.107", "workspace": 7, "label": "OFFICE",   "focusBorder": null     }
}
```

**Convention: `vsockCid` = subnet last octet = workspace number.** All three use the same number. Custom profiles start at CID 107+. Reserved: 200 (router), 201 (router-stable), 209 (usb-sandbox), 210 (builder), 211 (gitsync), 212 (files), 213 (vault), 214 (hostsync).

Each entry drives: compositor border rules, workspace-desc label, `ws-app`/`ws-rofi` workspace -> VM routing, focus menu, `vm-sync` profile targeting, and file transfer IP resolution.

### VM Static IP Scheme

Profile VMs use a static `.10` IP on their bridge for Files VM reachability. The IP is **automatically derived** from `hydrix.networking.vmSubnet`, which every profile sets from its own `meta.nix`:

```nix
# In profiles/<name>/default.nix, this one line drives everything
hydrix.networking.vmSubnet = meta.subnet;  # e.g. "192.168.102"
# -> staticIp auto-set to "192.168.102.10" by microvm-base.nix
```

`microvm-base.nix` sets `hydrix.microvm.staticIp = lib.mkDefault "${vmSubnet}.10"` whenever `vmSubnet` is non-empty. No explicit `staticIp` declaration is needed in profile modules - the template includes the `vmSubnet` line and that is sufficient.

The table below shows the Hydrix built-in profile **defaults**, your `meta.nix` values take precedence automatically:

| VM | Default Bridge | Default Static IP |
|----|---------------|------------------|
| `microvm-pentest` | `br-pentest` | `<subnet>.10` |
| `microvm-browsing` | `br-browse` | `<subnet>.10` |
| `microvm-comms` | `br-comms` | `<subnet>.10` |
| `microvm-dev` | `br-dev` | `<subnet>.10` |
| `microvm-lurking` | `br-lurking` | `<subnet>.10` |

Each VM configures this IP on its main TAP interface via systemd-networkd. The Files VM derives the destination IP for each VM from the vm-registry (`subnet + ".10"`) at transfer time.

### Files VM Cross-Bridge Wiring

The Files VM (`microvm-files`, CID 212) has **multiple TAP interfaces** - one per allowed bridge - enabling direct L2 access for encrypted file transfers:

```
Files VM (192.168.108.10 on br-files)
├── mv-files (always -> br-files)
├── mv-files-pent (-> br-pentest, if "pentest" in accessFrom)
├── mv-files-brow (-> br-browse, if "browsing" in accessFrom)
├── mv-files-dev  (-> br-dev, if "dev" in accessFrom)
├── mv-files-comm (-> br-comms, if "comms" in accessFrom)
├── mv-files-lurk (-> br-lurking, if "lurking" in accessFrom)
└── mv-router-file (-> br-files, router leg)
```

Configuration in your flake:
```nix
"microvm-files" = hydrix.lib.mkMicrovmFiles {
  # Bridges the Files VM gets direct TAP access to
  accessFrom = [ "pentest" "browsing" "dev" "comms" ];
};
```

Per-bridge IPs (derived from vm-registry): Files VM gets `.2` on each bridge (e.g., `192.168.103.2` on `br-browse`). The Files VM is **fully isolated** from the router - it communicates directly via TAP interfaces, bypassing router forwarding rules.

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
microvm builder build browsing   # Fetch/build in builder VM
microvm builder build host       # Build host config
microvm builder status           # Check builder state
```

### Builder VM (Lockdown Mode Builds)

The Builder VM enables nix package builds in lockdown mode when the host has no internet access. It fetches dependencies through the router VM and writes build outputs directly to the host's `/nix/store`.

**Architecture:**

```
Host (Lockdown Mode)                     Builder VM                     Router VM

 /nix/store (R/O)       <-virtiofs->     /nix/store       --vsock-->    WiFi (WAN)  
 nix-daemon: STOPPED     (mounted)      (R/W overlay)     internet               

                                                                            
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
microvm builder build browsing      # Build microVM in builder
microvm builder build host          # Build host config

# Build AND apply host config (preserves current specialisation)
microvm builder switch
microvm builder switch administrative  # Switch to specific specialisation

# Prefetch only (keep builder running for batch operations)
microvm builder fetch browsing
microvm builder fetch pentest
microvm builder fetch host
microvm builder stop               # Stop when done

# Manual control
microvm builder start       # Start builder (stops host nix-daemon)
microvm builder shell       # Attach to builder console
microvm builder status      # Check builder state
microvm builder stop        # Stop builder (restarts host nix-daemon)
```

**Named targets:**

| Target | Resolves To | Purpose |
|--------|-------------|---------|
| `browsing` | `microvm-browsing` | Browsing VM |
| `pentest` | `microvm-pentest` | Pentest VM |
| `dev` | `microvm-dev` | Dev VM |
| `comms` | `microvm-comms` | Comms VM |
| `lurking` | `microvm-lurking` | Lurking VM |
| `router` | `microvm-router` | Router VM |
| `builder` | `microvm-builder` | Builder VM itself |
| `host` | Host system | Host NixOS configuration |
| `.#path` | Raw flake path | e.g., `.#nixosConfigurations.microvm-dev` |

**How it works:**

1. **Start**: Host nix-daemon stops, `/nix/store` remounted R/W
2. **Build**: Builder evaluates flake from `/mnt/hydrix` (your config)
3. **Fetch**: Dependencies fetched via router VM (has internet)
4. **Build**: Compilation happens in Builder with virtiofs store access
5. **Stop**: Outputs written to host's `/nix/store`, Builder stops
6. **Switch**: Host nix-daemon restarts, host builds instant (all deps cached)

**Builder shell access:**

```bash
microvm builder shell

# Inside builder shell:
nix flake metadata           # Check flake inputs
nix build .#microvm-browsing # Manual build
exit                         # Return to host
```

**Builder status:**

```bash
microvm builder status

# Output:
# Builder state: running
# Process ID: 12345
# Target: browsing
# Progress: fetching...
```

**Recovery if builder crashes:**

```bash
# Manual recovery if builder is stuck
microvm stop microvm-builder  # This also restores host nix-daemon

# If store is still rw after builder crash
sudo mount -o remount,ro /nix/store
sudo systemctl start nix-daemon
```

---

### VM Types

**MicroVM** (Recommended):
- Uses QEMU with virtiofs for shared /nix/store
- Display via waypipe (Wayland) or xpra (X11) over vsock

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
| Autologin | Safe, getty console is local-only, no network auth surface exists |

The `router.hashedPassword` option exists only to lock down vsock console access from the host side (e.g., shared-host scenarios). It is not a network security control, VMs cannot reach the router console regardless.

### VM-to-VM Isolation

Each VM subnet is isolated from all others at the router's `forward` chain. A compromised browsing VM cannot reach the pentest or dev VM's subnet, and vice versa. The only exception is `br-shared` (192.168.105.0/24), which all VMs can forward to and from.

```
pentest  -> browse:  BLOCKED
pentest  -> comms:   BLOCKED
browse   -> dev:     BLOCKED
any VM   -> shared:  ALLOWED  (intentional shared services subnet)
any VM   -> WAN:     ALLOWED  (via NAT through router)
```

The files VM (`microvm-files`) bypasses this intentionally by connecting directly to bridges via dedicated TAP interfaces explicitly granted per-bridge via `microvmFiles.accessFrom`. Passphrases for encrypted file transfer travel exclusively over vsock, never over bridge networks.

### Host Isolation

The host has no L3 presence on VM bridges. All bridges exist as pure L2 plumbing:
- No IPv4 addresses on any bridge in any mode
- IPv6 link-local auto-assignment is disabled on all VM bridges via sysctl (`net.ipv6.conf.<br>.disable_ipv6`)
- `br-shared` is VM-only in all modes - the host never holds an address there

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

WiFi credentials declared directly in `modules/wifi.nix` are baked into the router VM's NixOS closure and end up in `/nix/store` as plaintext or WPA PSK hashes. Because all VMs share the host's `/nix/store` read-only via virtiofs, any VM (including a compromised browsing or pentest VM) can read those credentials by scanning the store.

Hydrix solves this with sops-encrypted WiFi credentials stored in `secrets/wifi.yaml` and delivered only to the router VM at runtime via virtiofs. See [Secrets Management](#secrets-management) for setup, and [WiFi Credential Management](#wifi-credential-management-wifi-sync) for the `wifi-sync` workflow.

If you do not set up sops, credentials remain in `modules/wifi.nix` and the mitigations are:
- Full-disk encryption on the host (protects the store at rest)
- Treat any profile VM as potentially able to read your WiFi PSKs
- Avoid declaring sensitive network credentials (corporate VPN, etc.) in `wifi.nix`

---

## Installation

### Fresh Install (From Live Environment)

```bash
# Download and run installer
curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | sudo bash
```

The installer will:
1. **Auto-detect hardware**: CPU (Intel/AMD), WiFi PCI address, ASUS features
2. **Prompt for configuration**: Username, hostname, disk, WiFi credentials
3. **Detect locale**: Timezone, keyboard layout, and locale are read from the running system and written into `modules/common.nix` - one file that applies to both host and all VMs
4. **Partition disk**: GPT with EFI, optional LUKS encryption
5. **Generate config** in `~/hydrix-config/`:
   - `flake.nix` - Main flake importing Hydrix
   - `machines/<hostname>.nix` - Your machine configuration
   - `modules/common.nix` - Locale, timezone, scaling (auto-populated)
   - `specialisations/` - Boot mode configurations
5. **Pre-build infrastructure VMs**: `microvm-router`, `microvm-router-stable`, `microvm-builder`

Profile VMs (`microvm-browsing`, `microvm-pentest`, `microvm-dev`, `microvm-comms`, `microvm-lurking`) are **not** built during install. Build them on demand after first boot:

```bash
microvm build microvm-browsing
microvm build microvm-pentest
# etc.
```

The installer pre-builds `microvm-router`, `microvm-router-stable`, and `microvm-builder` during installation. On first boot:

- **Router starts automatically** (controlled by `router.autostart = true`)
- **Other VMs are declared but not started**. Build them on demand:

```bash
microvm build microvm-browsing
microvm start microvm-browsing
# etc.
```

To customize VMs per-machine, edit `machines/<serial>.nix`:

```nix
{ config, ... }: {
  hydrix.microvmHost.vms."microvm-pentest".enable = false;  # Disable if not needed
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

This auto-detects your current system configuration and generates a minimal Hydrix config preserving your existing disk layout.

### Generated Configuration Structure

```
~/hydrix-config/
├── flake.nix                    # Imports Hydrix, defines machines and VMs
├── machines/
│   └── <serial>.nix             # Your machine config (named by hardware serial)
├── profiles/                    # VM profile customizations (overlay on Hydrix base)
│   ├── browsing/
│   │   ├── meta.nix             # CID, bridge, subnet, workspace, label, focusBorder
│   │   ├── default.nix          # NixOS config (colorscheme, resources)
│   │   ├── packages.nix         # Profile-specific packages
│   │   └── packages/            # Custom packages (via vm-sync)
│   ├── pentest/
│   ├── dev/
│   ├── comms/
│   └── lurking/
├── colorschemes/                # Custom colorschemes (pywal JSON format)
├── modules/                      # Settings shared across all machines and VMs
│   ├── common.nix               # Locale, shared packages
│   ├── wifi.nix                 # WiFi credentials
│   ├── fonts.nix                # Font packages and profiles
│   ├── graphical.nix            # UI preferences (opacity, bluelight, DPI)
│   ├── polybar.nix              # Bar style, workspace labels, module layout
│   ├── i3.nix                   # i3 keybindings
│   ├── fish.nix                 # Shell abbreviations and functions
│   ├── alacritty.nix            # Terminal cursor, keyboard overrides
│   ├── dunst.nix                # Notification preferences
│   ├── ranger.nix               # File manager keybindings and rifle rules
│   ├── rofi.nix                 # Launcher keybindings and extraConfig
│   ├── zathura.nix              # PDF viewer settings
│   ├── starship.nix             # Prompt configuration
│   ├── vim.nix                  # Editor configuration
│   ├── firefox.nix              # Host Firefox toggle and user-agent
│   └── obsidian.nix             # Host Obsidian toggle and vault paths
├── custom/                     # Local NixOS modules
├── tasks/                       # Pentest task VM slots (task1.nix, task2.nix, ...)
└── specialisations/
    ├── _base.nix                # Shared base packages
    ├── lockdown.nix             # Lockdown mode config
    ├── administrative.nix       # Admin mode config
    └── fallback.nix             # Fallback mode config
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
    userProfiles = ./profiles;  # Your profile customizations
  in {
    nixosConfigurations."ABC123XYZ" = hydrix.lib.mkHost {
      modules = [ ./machines/ABC123XYZ.nix ];
    };

    # MicroVMs with user profiles overlaid on Hydrix base
    # hostname = the nixosConfiguration key; sets hydrix.vm.storeName (structural, do not change)
    # To customise the in-VM hostname, set hydrix.vm.hostname in profiles/<name>/default.nix
    nixosConfigurations."microvm-browsing" = hydrix.lib.mkMicroVM {
      profile = "browsing";
      hostname = "microvm-browsing";
      inherit userProfiles;  # Your customizations in ./profiles/browsing/
    };

    nixosConfigurations."microvm-pentest" = hydrix.lib.mkMicroVM {
      profile = "pentest";
      hostname = "microvm-pentest";
      inherit userProfiles;
    };

    # Infrastructure VMs (not user-configurable)
    nixosConfigurations."microvm-router"        = hydrix.lib.mkMicrovmRouter { inherit wifiPciAddress; };
    nixosConfigurations."microvm-router-stable" = hydrix.lib.mkMicrovmRouterStable { inherit wifiPciAddress; };
    nixosConfigurations."microvm-builder"       = hydrix.lib.mkMicrovmBuilder {};
  };
}
```

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

This sets a udev rule granting `kvm` group ownership of the device node and injects QEMU USB passthrough args into the target VM via `microvmHost.profileOverrides`.

**The passthrough is exclusive.** The webcam is unavailable on the host while the VM is running. To temporarily restore host access:

```bash
microvm stop microvm-comms   # host reclaims webcam
microvm start microvm-comms  # webcam returns to VM
```

After enabling, rebuild the host (applies udev rule), then rebuild the VM:

```bash
rebuild
mvm rebuild comms
```

### Router

```nix
{
  hydrix.router = {
    type = "microvm";               # "microvm", "libvirt", or "none"
    autostart = true;

    wifi = {
      # Single network (legacy)
      ssid = "MyNetwork";
      password = "secret";           # Consider using sops-nix

      # Multiple networks (takes precedence if non-empty)
      networks = [
        { ssid = "HomeNetwork"; password = "secret"; priority = 100; }
        { ssid = "WorkNetwork"; password = "secret2"; priority = 50; }
      ];
    };

    # Use wifi-sync to manage networks — see "WiFi Credential Management" section below

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

`wifi-sync` manages WiFi networks stored in `secrets/wifi.yaml` (sops mode) or `modules/wifi.nix` (legacy mode). It communicates with the router VM over vsock port 14506. Sops mode is strongly recommended; see [Secrets Management](#secrets-management) for setup.

#### How it works

The router VM maintains two NetworkManager connection directories:

| Directory | Contents | Source |
|---|---|---|
| `/run/NetworkManager/system-connections/` | Declared networks, generated from `wifi.nix` at build time | NixOS build |
| `/var/lib/NetworkManager/system-connections/` | Runtime-added networks, persists across restarts | `nmcli` at runtime |

`wifi-sync` (POLL command over vsock) reads both directories and diffs the result against your credential store to identify networks that are on the router but not yet saved locally.

The waybar WiFi widget shows **+N** when the router has N connections that are not in your credential store. This is your signal to run `wifi-sync pull`.

#### Commands

```bash
wifi-sync                    # Admin: status + pending count. Fallback: capture current connection
wifi-sync add SSID PASSWORD  # Push network to router NM and save to credential store
wifi-sync pull               # Merge all router connections into credential store
wifi-sync list               # Show saved networks
wifi-sync remove SSID        # Remove from credential store and from router NM
```

**Admin mode** applies when the router VM is reachable via vsock (normal lockdown/administrative operation).

**Fallback mode** applies when the router VM is not running (fallback specialisation with direct host WiFi). `wifi-sync` reads the current connection from the host's `nmcli` and saves it to the credential store.

#### Sops mode workflow (recommended)

In sops mode, networks are stored in the age-encrypted `secrets/wifi.yaml`. Credentials never appear in the Nix store and are only decrypted at boot and delivered to the router VM. Other VMs have no access.

```bash
# Add a new network (pushes to router NM immediately, saves to secrets/wifi.yaml):
wifi-sync add "NetworkName" "password"

# If the router already has a connection you want to save:
wifi-sync pull

# Check what is saved:
wifi-sync list

# Remove a network from both the credential store and the router:
wifi-sync remove "NetworkName"
```

No rebuild is needed to apply credential changes. The router sees updates via its persistent NM state (for `add`) or on next boot via virtiofs (for connections loaded from `wifi.yaml`).

#### Legacy mode workflow (wifi.nix)

In legacy mode, credentials live in `modules/wifi.nix` as WPA PSK hashes and are baked into the Nix store at build time.

```bash
wifi-sync add "NetworkName" "password"   # saves hash to wifi.nix
rebuild
# Purge is required because NM runtime state in /var/lib/ takes precedence over
# freshly built /run/ connections. Only a purge guarantees a clean NM state.
microvm purge microvm-router --force && microvm build microvm-router && microvm start microvm-router
```

To migrate from legacy to sops mode:

```bash
setup-wifi-secrets    # reads modules/wifi.nix, encrypts to secrets/wifi.yaml
git add -f secrets/wifi.yaml && git commit -m 'feat(secrets): add encrypted wifi credentials'
# In machines/<serial>.nix: set wifiSecretsFile + wifi.enable, empty modules/wifi.nix networks list
rebuild
sudo rm /var/lib/microvms/microvm-router/var-lib.qcow2
microvm purge microvm-router --force && mvm rebuild router
```

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

    # Customizable VM names (defaults shown)
    vmNames = {
      browse = "microvm-browsing";
      hack = "microvm-pentest";
      dev = "microvm-dev";
      comms = "microvm-comms";
      lurk = "microvm-lurking";
      build = "microvm-builder";
      router = "microvm-router";
    };

    vms = {
      microbrowse = { enable = true; autostart = false; };
      microhack = { enable = true; };
      microdev = { enable = true; secrets = [ "github" ]; };
      microcomms = { enable = true; };
      microlurk = { enable = true; };
    };
  };

  hydrix.builder.enable = true;      # Builder VM for lockdown mode builds
}
```

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
        polybar = 1.0;
        rofi = 1.0;
        dunst = 1.0;
        firefox = 1.2;
        gtk = 1.0;
      };

      # Standalone mode overrides (no external monitor)
      standaloneRelations = {};       # e.g., { alacritty = 1.05; }

      overrides.alacritty = 12;       # Fixed size (bypass scaling)
      familyOverrides.polybar = "Tamzen";
    };

    # UI dimensions
    ui = {
      gaps = 15;
      border = 2;
      barHeight = 23;
      barPadding = 2;
      cornerRadius = 2;
      shadowRadius = 18;
      floatingBar = true;
      bottomBar = true;              # Bottom bar with VM metrics
      polybarStyle = "modular";      # unibar, modular, or pills

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
        rules = { "Polybar" = 95; }; # Per-window-class opacity rules
        exclude = [ "Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc" ];
      };

      # Rofi/Dunst dimensions
      rofiWidth = 800;
      rofiHeight = 400;
      dunstWidth = 300;
      dunstOffset = 300;

      # Compositor animations
      compositor.animations = "modern"; # "none" or "modern" (bouncy picom v12)
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
      internalResolution = "1920x1200";
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

    # Splash screen
    splash = {
      enable = true;
      title = "HYDRIX";
      text = "initializing...";
      maxTimeout = 15;
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
| **microvm** | VM with `standalone = false` | Theming only: pywal, wpgtk, feh, imagemagick, xrdb, pulseaudio, xclip/xsel |
| **standalone** | VM with `standalone = true` | Adds: polybar, rofi, picom, xdotool, unclutter, xcape, scrot, flameshot, X11 tools |
| **host** | `vmType = "host"` | Adds: i3lock, brightnessctl, libvibrant, xorg.xinit, xorg.xorgserver |

**Why:** MicroVMs forward apps to the host via waypipe or xpra, they have no local window manager and no physical display. Installing a compositor (picom), screenshot tools (flameshot, scrot), or hardware controls (brightnessctl, libvibrant) would be dead weight. Standalone libvirt VMs run a full desktop via virt-manager and need the WM stack, but still have no physical backlight or lockscreen. Only the host needs those.

The `standalone` option on a VM config is the switch:

```nix
hydrix.graphical.standalone = true;   # libvirt VM with own display -> full WM tier
hydrix.graphical.standalone = false;  # microVM -> theming only, display forwarded via waypipe or xpra (default)
```

### Shared Modules

The `modules/` directory in your `hydrix-config` holds settings that apply to all machines. Each file is a NixOS module imported by every machine (and, where relevant, by VMs via `hostConfig`). Settings use `lib.mkDefault` so individual machine configs can override with plain assignment.

| File | What it controls |
|------|-----------------|
| `common.nix` | Locale, shared system packages |
| `wifi.nix` | WiFi credentials for the router VM |
| `fonts.nix` | Font packages and per-app size relations |
| `graphical.nix` | Opacity, bluelight filter, DPI scaling |
| `polybar.nix` | Bar style, workspace labels, module layout |
| `i3.nix` | i3 keybindings |
| `fish.nix` | Shell abbreviations and functions |
| `alacritty.nix` | Terminal cursor shape, keyboard overrides |
| `dunst.nix` | Notification dimensions and urgency settings |
| `ranger.nix` | File manager keybindings and rifle rules |
| `rofi.nix` | Launcher dimensions, key bindings, fuzzy matching |
| `zathura.nix` | PDF viewer options |
| `starship.nix` | Full prompt configuration (TOML inlined as Nix string) |
| `vim.nix` | Editor configuration (vimrc inlined as Nix string) |
| `firefox.nix` | Host Firefox toggle and user-agent spoofing |
| `obsidian.nix` | Host Obsidian toggle and vault CSS theme deployment |
| `tor-hardening.nix` | Tor anonymity: bridges, Firefox hardening, no-swap enforcement |

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

#### obsidian.nix

```nix
# Install Obsidian on the host
hydrix.graphical.obsidian.hostEnable = lib.mkDefault false;

# Vaults to deploy the Hydrix CSS theme snippet to (paths relative to $HOME)
# hydrix.graphical.obsidian.vaultPaths = lib.mkDefault [ "notes" "hack_the_world" ];
```

The framework auto-generates a CSS snippet from the active colorscheme and font settings, deploying it to each vault's `.obsidian/snippets/` directory and enabling it via `appearance.json`.

#### polybar.nix

```nix
hydrix.graphical.ui.polybarStyle = lib.mkDefault "modular";  # or "unibar"
hydrix.graphical.ui.floatingBar  = lib.mkDefault true;
hydrix.graphical.ui.bottomBar    = lib.mkDefault true;

# Override module layout (null = style default)
# hydrix.graphical.ui.bar.top.right   = "pomo-dynamic git-dynamic battery-dynamic date-dynamic";
# hydrix.graphical.ui.bar.bottom.right = "rproc-bottom vm-ram-bottom vm-cpu-bottom";
```

Available modules for the modular style:
```
pomo-dynamic  sync-dynamic  git-dynamic  mvms-dynamic  vms-dynamic
volume-dynamic  temp-dynamic  ram-dynamic  cpu-dynamic  fs-dynamic
uptime-dynamic  date-dynamic  battery-dynamic  battery-time-dynamic
focus-dynamic  xworkspaces  workspace-desc  spacer  power-profile-dynamic

(bottom bar)
rproc-bottom  cproc-bottom  vm-ram-bottom  vm-cpu-bottom
vm-sync-dev-bottom  vm-sync-stg-bottom  vm-fs-bottom  vm-tun-bottom  vm-up-bottom
```

### Polybar VM Integration

**workspace-desc** - Shows current workspace label (e.g., "BROWSING", "PENTEST") read from `/etc/hydrix/vm-registry.json` at runtime. Works automatically for any VM added to your config.

Labels can be overridden temporarily at runtime with `ws-name`:

```bash
ws-name encryption   # current workspace shows "ENCRYPTION" in the status bar
ws-name              # reset, reverts to registry label (e.g. "DEV")
```

Overrides are written to `/tmp/ws-names/<number>` and cleared automatically on reboot. The status bar module checks this directory before falling back to the vm-registry, so workspace names are never changed.

**focus-dynamic** - Shows which VM type is currently focused on each workspace. Uses the same vm-registry lookup.

**Bottom bar modules** (vm-ram-bottom, vm-cpu-bottom, etc.) - Query running VMs by polling vm-registry, then fetch metrics via vsock from each VM's CID (port 14501).

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

For detailed runtime data flow, see `POLYBAR-VM-INTEGRATION.md` in your config directory.

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

### Polybar Styles

| Style | Description |
|-------|-------------|
| `unibar` | Classic solid bar with `//` separators |
| `modular` | Transparent background with module backgrounds (default) |
| `pills` | Multiple small rounded floating bars |

Note: on Hyprland, waybar is used instead of polybar.

### Secrets Management

Hydrix uses [sops](https://github.com/getsops/sops) with age keys derived from the SSH host key. Encrypted files are safe to commit to your hydrix-config repo; only your machine can decrypt them.

#### Initial setup

```bash
# 1. Enable secrets and rebuild to generate the age key
#    In machines/<serial>.nix:
#      hydrix.secrets.enable = true;
rebuild

# 2. Initialize secrets/.sops.yaml with your machine's age public key
hydrix-sops-setup

# 3. Commit the sops config
cd ~/hydrix-config && git add -f secrets/.sops.yaml && git commit -m 'feat(secrets): init sops'
```

After the first rebuild, the age key is automatically made available to user-level sops commands via `~/.config/sops/age/keys.txt`. No manual key management is required.

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

# Per-VM opt-in: only listed VMs receive each secret type
hydrix.microvmHost.vms."microvm-browsing".secrets = [ "discord" ];
hydrix.microvmHost.vms."microvm-router".secrets   = [ "wifi" ];
hydrix.microvmHost.vms."microvm-dev".secrets      = [ "github" ];
```

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
sudo systemctl restart hydrix-secrets-microvm-router
# The router VM sees the change immediately via virtiofs.
# If the VM has a consuming oneshot service, restart it too:
# (inside router VM) systemctl restart hydrix-wifi-from-sops
```

#### Adding a new machine

On a fresh machine, the age key is derived automatically at first boot. To decrypt existing secrets on the new machine:

```bash
# On the new machine after first rebuild:
sops-age-pubkey           # prints the machine's age public key

# On a machine that can already decrypt:
# Add the new key to secrets/.sops.yaml recipients, then:
sops updatekeys secrets/*.yaml
git add secrets/.sops.yaml secrets/*.yaml && git commit -m 'feat(secrets): add new machine key'
```

Until re-keyed, decrypt services exit with a warning and VMs start without secrets.

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
│  Drives pywal palette inside the VM: alacritty, rofi, dunst, GTK    │
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

This scheme is used for the VM's own terminals, rofi, dunst, GTK, and any other pywal-aware apps running inside the VM. It acts as the base palette, which colors are actually applied depends on Layer 2.

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
                              sudo -u user refresh-colors (pywalfox, dunst, xsetroot)

walrgb / wal-sync / restore-colorscheme (inside VM - fully contained)
  -> updates VM's own ~/.cache/wal/ only, never touches host
  -> refresh-colors: regenerates colors-runtime.toml
                     pushes sequences to all owned /dev/pts/*
                     updates pywalfox, dunst, xsetroot
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
- **Dunst**  notification colors
- **Firefox**  via pywalfox

On the host (after `walrgb` / `randomwalrgb` / `restore-colorscheme`):
- **compositor**  window borders
- **status bar**  all bar colors
- **Alacritty**  all ANSI colors + cursor color (via `colors-runtime.toml`)
- **Running terminals**  ANSI palette + cursor via sequences to all `/dev/pts/*`
- **Dunst**  notification colors
- **Firefox**  via pywalfox extension
- **RGB lighting**  ASUS Aura / OpenRGB

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

1. **wal-cache-link service**  copies host colors into VM's local `~/.cache/wal` before xpra starts, so colors exist from the first shell
2. **Pre-generated `colors-runtime.toml`**  built at VM boot from the copied `colors.json` via jq; available before any terminal opens
3. **Stylix fish target disabled**  prevents OSC escape sequences from overriding colors on every shell start (`stylix.targets.fish.enable = mkForce false`)
4. **xpra-vsock ordering**  xpra only accepts connections after `wal-cache-link` completes
5. **Conflicting services disabled**  `vm-colorscheme`, `wal-sync` timer, and `init-wal-cache` are disabled so they cannot overwrite the VM's local cache

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

The focus border is the window border color shown **on the host** when a VM application window is focused. It works on all supported WMs. It is entirely independent from what colors the VM uses internally, you can have a VM running `nord` internally while its host-side border is bright orange.

**Implementation note (Sway):** Sway has no IPC command to change `client.focused` at runtime - the only mechanism is writing `~/.config/sway/colors.conf` and calling `swaymsg reload`. To avoid a visible freeze during focus switches, the reload is scheduled asynchronously on a background thread with a 40ms debounce. The focus event handler returns immediately (no compositor pause), and the border color updates imperceptibly shortly after. Rapid workspace switches are coalesced into a single reload.

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
      polybar = 1.0;
      rofi = 1.2;
      dunst = 0.9;
    };
    familyOverrides = {               # Per-app font family override
      polybar = "Tamzen";             # Use different font for polybar
    };
  };
}
```

### Host Font Pipeline

On the host, `alacritty-dpi` launches terminals with DPI-aware font settings:

1. `dynamic-scaling` detects monitor DPI and writes `~/.config/hydrix/scaling.json`
2. `scaling.json` contains calculated font sizes (fractional, e.g. 10.5) and the font family
3. `alacritty-dpi` reads `scaling.json` at launch time and passes `-o font.size=X -o font.normal.family=Y`
4. This overrides `alacritty.toml` (which has static build-time values from Stylix)

The `scaling.json` font_name is patched by a system activation script on every `rebuild`, so it always reflects the current config even before a display event triggers `dynamic-scaling`.

### VM Font Pipeline

VMs use their own `alacritty.toml` directly - no wrapper overrides:

1. Stylix generates `alacritty.toml` with font family and size from `hydrix.graphical.font`
2. The VM's xpra session sets `WINIT_X11_SCALE_FACTOR=1` globally
3. When launched via xpra (`microvm app` / `ws-app`), plain `alacritty` runs inside the VM
4. Alacritty reads its own config with the correct font

### Updating Fonts

| Action | Host | VMs |
|--------|------|-----|
| Change `font.family` | `rebuild` | `rebuild` + `microvm update <vm>` |
| Change `font.size` | `rebuild` (scaling.json updates) | `rebuild` + `microvm update <vm>` |
| DPI change (new monitor) | Automatic via `dynamic-scaling` | N/A (xpra handles display) |

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

### Live Switch (microvm update)

`microvm update` performs a live config switch that includes home-manager activation. This means font changes in `alacritty.toml` are applied without VM restart. The host dumps nix store registration info to the VM before switching so home-manager can realise new store paths.

New terminal windows pick up the updated font. Already-running terminals keep their current font (alacritty inotify doesn't detect nix store symlink changes).

---

## MicroVM Management

### Commands

```bash
# Lifecycle
microvm build <name>       # Build/rebuild VM image
microvm start <name>       # Start VM (polls PING→OK, then starts display tunnel (waypipe or xpra))
microvm stop <name>        # Stop VM
microvm restart <name>     # Restart VM

# Applications (just press Super+Return on the VM workspace in Hyprland/Sway)
microvm app <name> <cmd>   # Launch app via xpra (i3/X11 only)
microvm attach <name>      # Attach to xpra session (i3/X11 only)
microvm console <name>     # Serial console (headless VMs)

# Status
microvm status [name]      # Show status
microvm list               # List all VMs
microvm logs <name>        # View logs

# Data Management
microvm snapshot create <name> <snap>  # Create snapshot
microvm snapshot list <name>           # List snapshots
microvm snapshot revert <name> <snap>  # Revert to snapshot
microvm purge <name>                   # Delete all data (fresh start)

# Encrypted home volume
microvm encrypt-setup <name>           # First-time setup (run once, VM must be stopped)
microvm start <name>                   # Prompts for passphrase, then starts normally
microvm stop <name>                    # Stops VM and locks volume automatically
```

### Encrypted Home Volumes

Persistent home volumes can be LUKS-encrypted so data is locked at rest whenever the VM is not running. The passphrase is prompted as part of `microvm start`, no separate unlock step needed.

**How it works:**

- `microvm encrypt-setup` creates a raw LUKS2 container (`home.luks`) in `/var/lib/microvms/<name>/`
- `microvm start` runs `cryptsetup luksOpen` before QEMU starts, presenting `/dev/mapper/vm-<name>-home` to the VM
- `microvm stop` runs `cryptsetup luksClose` after the VM halts - data is locked immediately
- If the host is powered off mid-session, the container is locked automatically on reboot (the mapper device never persists across boots)

**Enabling encryption for a VM:**

```bash
# 1. Stop the VM if running
microvm stop microvm-pentest

# 2. Create the LUKS container (prompts for passphrase, formats ext4 inside)
microvm encrypt-setup microvm-pentest

# 3. Enable in your VM profile (hydrix-config/profiles/pentest/default.nix):
#    hydrix.microvm.encryption.enable = true;

# 4. Rebuild to point the VM at the encrypted volume
microvm build microvm-pentest

# 5. Start - passphrase prompt appears before QEMU launches
microvm start microvm-pentest
```

**Notes:**

- Any existing `home.qcow2` is **not** migrated - it remains on disk and can be mounted manually for data recovery (see below), then deleted once you've confirmed the encrypted volume is working
- Snapshots (`microvm snapshot`) do not apply to encrypted volumes - use a filesystem-level backup of `home.luks` while the mapper is closed instead
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
| `microvm-pentest` | 102 | 2 | br-pentest | 192.168.102 | persistent, LUKS-encrypted |
| `microvm-browsing` | 103 | 3 | br-browse | 192.168.103 | 10GB home |
| `microvm-comms` | 104 | 4 | br-comms | 192.168.104 | Ephemeral |
| `microvm-dev` | 105 | 5 | br-dev | 192.168.105 | 50GB + 20GB docker |
| `microvm-lurking` | 106 | 6 | br-lurking | 192.168.106 | Ephemeral |

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

1. Declare the VM in `machines/<serial>.nix`:
```nix
hydrix.microvmHost.vms."microvm-myprofile" = { enable = true; };
```

2. Customise `profiles/myprofile/default.nix` - set colorscheme, RAM/vCPUs, packages.

   Optionally set a custom hostname (what you see at the shell prompt inside the VM).
   The default is the profile name suffixed with `-vm` (e.g. `myprofile-vm`).
   This only affects the internal hostname - host scripts, window titles, and storage paths
   always use the nixosConfiguration key (`microvm-myprofile`):

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
mvm rebuild router files      # router picks up new subnet TAP; files VM picks up new bridge leg
microvm build microvm-myprofile
microvm start microvm-myprofile
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
| `microvm-vault` | 213 | Isolated KeepassXC credential store |
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
  tapMac   = "02:00:00:02:xx:01";  # unique MAC
  tapBridges = { "mv-myinfra" = "br-myinfra"; };
  # routerTap = "mv-router-myinfra";  # add if the VM needs internet via the router
}
```

2. Create `infra/<name>/default.nix` - standard NixOS module; `mkInfraVm` provides the headless base.

3. Declare in `machines/<serial>.nix`:
```nix
hydrix.microvmHost.vms."microvm-myinfra" = { enable = true; };
```

4. Rebuild and start:
```bash
rebuild                              # creates bridge, configures TAP wiring, writes registry
mvm rebuild router                   # only needed if routerTap was declared
microvm build microvm-myinfra
microvm start microvm-myinfra
```

If `routerTap` is set, the flake feeds it into `extraNetworks`, which automatically wires a router TAP and routes that subnet - no changes to router config required. If omitted, the VM is isolated and only reachable from other VMs sharing its bridge (like usb-sandbox).

### TUI Launcher

```bash
hydrix-tui              # Interactive TUI for VM management
# Or press Mod+m for the launcher
```

The TUI's MicroVM menu includes task pentest slots. Task slots display their active engagement name and offer a **Snapshots** sub-menu when stopped.

### Task Pentest VMs (per-engagement)

For work that benefits from isolation per target or engagement, Hydrix supports **task slots**: a fixed pool of pre-declared pentest VMs that can be assigned to named engagements without a host rebuild.

**How it works:**
- Three task slots (`microvm-pentest-task1/2/3`, CIDs 115–117) are declared permanently in the host config via `hydrix-config/tasks/task*.nix`
- Service units, TAP interfaces, and bridges are created once during the initial rebuild
- `microvm pentest create <name>` assigns an engagement to a free slot and builds its closure - no rebuild needed

**One-time setup** (done during any normal rebuild window):

```bash
# Add tasks/task1.nix, task2.nix, task3.nix to your hydrix-config
# See hydrix-config/tasks/ for the slot configs
rebuild    # Registers the slot service units permanently
```

**Engagement workflow:**

```bash
# Start a new engagement
microvm pentest create google           # Assign 'google' to a free slot
microvm start microvm-pentest-task1     # Service unit already exists
microvm snapshot create microvm-pentest-task1 google-clean  # Baseline
microvm app microvm-pentest-task1 alacritty

# Between sessions (revert to known-good state)
microvm stop microvm-pentest-task1
microvm snapshot revert microvm-pentest-task1 google-clean
microvm start microvm-pentest-task1

# Close engagement (volume and snapshots preserved, slot freed)
microvm pentest close google

# Reopen from snapshot
microvm pentest create google --slot 1
microvm snapshot revert microvm-pentest-task1 google-clean
microvm start microvm-pentest-task1

# Purge all data for an engagement
microvm pentest purge google

# View all slots and their status
microvm pentest list
```

**Task slot table:**

| Slot | CID | TAP | Bridge |
|------|-----|-----|--------|
| `microvm-pentest-task1` | 115 | `mv-task-1` | `br-pentest` |
| `microvm-pentest-task2` | 116 | `mv-task-2` | `br-pentest` |
| `microvm-pentest-task3` | 117 | `mv-task-3` | `br-pentest` |

**Adding more slots:** Create `tasks/task4.nix` with CID 118 and `tapId = "mv-task-4"`, then rebuild once. The `microvm pentest` command will discover it automatically.

**Engagement registry:** `hydrix-config/tasks/.engagement-registry` is a JSON file mapping slot names to engagement names. Commit it to track which slot held which engagement.

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

**Transfer flow** (`microvm files transfer pentest/projects/report comms/pentest/`):

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

**Store flow** (`microvm files store pentest/projects/report`):

Steps 1–4 are identical. After the files VM has the ciphertext, the host sends the passphrase via vsock and the files VM decrypts in-place into `/storage/pentest/`. Ciphertext is deleted after successful decryption.

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
hydrix.microvmHost.vms."microvm-files".enable = true;
hydrix.microvmFiles.enable = true;
```

**Commands:**

```bash
# Move files between VMs (source files untouched)
microvm files transfer pentest/projects/report comms/pentest/
microvm files transfer dev/src/tool pentest/tools/

# Archive to files VM /storage/ (encrypted, then decrypted in-place)
microvm files store pentest/projects/report

# List stored files
microvm files list
microvm files list pentest
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
 ├── mv-files-usb  → br-usb-sandbox (192.168.209.2)  [usb-sandbox, explicit]
 └── mv-files-hsy  → br-hostsync    (192.168.214.2)  [hostsync, explicit]

Profile/infra VMs: static .10 IPs on their bridge
 port 8888: ephemeral HTTP server (serve or receive), files VM IP only
 vsock 14506: vm-files-agent (receives host ENCRYPT/SERVE/RECEIVE_PREPARE/DECRYPT/CLEANUP commands)
```

The files VM's TAP list is **auto-discovered** at build time from `infra/files/meta.nix`, which reads `profiles/*/meta.nix` and includes explicit entries for infra VMs like usb-sandbox and hostsync. Adding a new profile automatically adds a new TAP after rebuilding the files VM.

### Hostsync VM (Host File Inbox)

`microvm-hostsync` (CID 214) is a minimal infra VM that bridges the encrypted file transfer system to the host filesystem. It has no internet access and no persistent storage of its own, its only writable surface is a virtiofs share pointing at `~/vm-inbox/` on the host.

**Security model:**

- Regular VMs have no direct host filesystem access whatsoever
- Only hostsync can write to the host, and only to `~/vm-inbox/` - blast radius is one directory
- Files arrive at hostsync already encrypted; the passphrase is released via vsock only after three-way SHA-256 verification passes
- Port 8888 accepts connections only from the files VM (`192.168.214.2`), enforced by nftables

**VM → Host** (`microvm files transfer browsing/wallpapers/Sunset.png hostsync/wallpapers`):

```
browsing VM  →  [encrypted, br-browse]  →  files VM  →  [encrypted, br-hostsync]  →  hostsync VM
                                                                                           │
                                                                                     virtiofs (rw)
                                                                                           │
                                                                                    ~/vm-inbox/wallpapers/
```

The standard `microvm files transfer` protocol is used unmodified. hostsync's vsock agent (port 14506) is compatible with the same `RECEIVE_PREPARE` / `DECRYPT` / `CLEANUP` commands sent to any destination VM.

**Host -> VM** (drop a file into `~/vm-inbox/`, then transfer out):

```bash
cp ~/somefile.txt ~/vm-inbox/
microvm files transfer hostsync/somefile.txt pentest/
```

hostsync's agent also implements `ENCRYPT` and `SERVE`, so it can act as a transfer source.

**Commands:**

```bash
# VM -> Host
microvm files transfer <src-vm>/<path> hostsync/            # extract to ~/vm-inbox/
microvm files transfer <src-vm>/<path> hostsync/<subdir>    # extract to ~/vm-inbox/<subdir>/

# Host -> VM (drop file into ~/vm-inbox/ first)
microvm files transfer hostsync/<filename> <dst-vm>/<path>
```

**Enable in your machine config** (included in the default template):

```nix
hydrix.microvmHost.vms."microvm-hostsync".enable = true;

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

Ephemeral VM for safely handling USB storage devices. USB drives are passed through via QEMU block device hotplug, isolated from all networks except the files VM.

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
1. Host -> usb-sandbox (vsock 14506): `ENCRYPT <passphrase> usb/vdb1/file` encrypts AES-256-CBC to `~/shared/xfer.enc`
2. Host -> usb-sandbox (vsock 14506): `SERVE` starts HTTP server on port 8888
3. Host -> files VM (vsock 14505): `FETCH 192.168.209.10 xfer.enc` files VM pulls ciphertext over br-usb-sandbox
4. Host -> files VM (vsock 14505): `DELIVER <dest-ip> xfer.enc` files VM pushes to destination VM
5. Host -> dest VM (vsock 14506): `DECRYPT <passphrase> ...` destination VM decrypts


The passphrase is generated on the host and sent exclusively over vsock -> it never crosses a bridge network.

**Setup** in your `machines/<serial>.nix`:

```nix
hydrix.microvmHost.vms."microvm-usb-sandbox".enable = true;
```

Then rebuild and start:

```bash
rebuild
microvm start microvm-usb-sandbox
```

**Host-side USB device pass-through:**

```bash
# List USB storage devices (format: BUS-ADDR, e.g., 002-003)
usb list

# Pass device to VM (QEMU USB hotplug)
usb-sandbox add 002-003

# Detach device from VM
usb-sandbox remove 002-003
```

The `usb-sandbox add` command hotplugs the USB storage as `/dev/vdb` (read-only) into the VM via QEMU `drive_add` + `device_add virtio-blk-pci`. The device persists until explicitly removed or VM restart.

**Inside the VM (auto-logged in as `sandbox`):**

```bash
# List block devices
usb list

# Scan for filesystems
usb scan

# Mount partition (e.g., /dev/vdb1)
usb mount /dev/vdb1

# View mounted files
ls ~/usb/vdb1/

# Unmount
usb umount /dev/vdb1

# USB device info
lsusb

# Block device tree
lsblk
```

**File transfer (from host):**

```bash
# Archive from USB to files VM (encrypted)
microvm files store usb-sandbox/usb/vdb1/<path>

# Transfer to another VM
microvm files transfer usb-sandbox/usb/vdb1/<path> dev/<dest>
```

Paths are relative to `/home/sandbox/` inside the VM. USB drives mount at `/home/sandbox/usb/`.

**Security model:**

| Protection | Status |
|------------|--------|
| Network isolation from host |  Isolated bridge, no host IP, no internet |
| Network isolation from other VMs |  Only files VM access via br-usb-sandbox (port 8888) |
| Read-only USB access |  USB passed as `/dev/vdb` read-only |
| Encrypted file transfers |  AES-256-CBC via files VM |
| Block device hotplug |  QEMU monitor socket, no libusb on host |
| **Host USB driver vulnerabilities** |  **Not protected** |
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

### Vault VM (microvm-vault)

`microvm-vault` (CID 213) is a fully offline KeepassXC credential store. KeePassXC runs inside the VM, the host communicates over vsock, and credentials travel to the host clipboard via `wl-copy`. The master password and decrypted credentials never reside in plaintext on the host filesystem or in any other VM.

#### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Host (Hyprland / Wayland)                                          │
│                                                                     │
│  vault-pick (launcher dmenu - runs on host)                         │
│  vault-cli  (shell script - runs on host)                           │
│                                                                     │
│  ~/vault/Passwords.kdbx  ◄── AES-256 encrypted blob                │
│       │  virtiofs (live mount, R/W)                                 │
│       ▼                                                             │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  microvm-vault (CID 213)  - NO network interface              │  │
│  │                                                              │  │
│  │  /var/lib/vault/Passwords.kdbx  (virtiofs of ~/vault/)       │  │
│  │  vault-agent: socat VSOCK-LISTEN:14514 (runs as vault user)  │  │
│  │  /run/vault-session/token  (tmpfs, 600 \- cleared on reboot)  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│       │ vsock 14514                                                 │
│  vault-pick / vault-cli                                             │
│       │                                                             │
│  wl-copy ──► Wayland clipboard (30s auto-clear)                     │
│                                                                     │
│  ~/vault/ (git repo)  ──virtiofs──►  microvm-gitsync (CID 211)     │
│                                         git push ──► GitHub         │
└─────────────────────────────────────────────────────────────────────┘
```

#### Security Boundaries

**Boundary 1 \- Network isolation**

The vault VM has no TAP interface and no bridge. `networking.useDHCP` and `networking.firewall` are force-disabled. The VM cannot initiate or receive any network connection regardless of what runs inside it.

*Protects against:* A compromised keepassxc binary or vsock handler cannot exfiltrate credentials over the network. The only data exit is vsock back to the host.

**Boundary 2 \- vsock CID addressing**

vsock uses CID addressing. Only the host (CID 2) can connect to CID 213's ports \- other VMs (browsing CID 103, pentest CID 102, etc.) cannot address the vault VM.

*Protects against:* Compromised profile VMs cannot request credentials from the vault agent even if they attempt to.

**Boundary 3 \- Session token in VM tmpfs**

The master password is stored in `/run/vault-session/token` inside the vault VM. This is a tmpfs filesystem \- never written to disk, owned by `vault:vault` (mode 700 dir, 600 file), inaccessible to the host via virtiofs, cleared on VM reboot.

*Protects against:* A host process, even as root, cannot read the master password from disk. It exists only in vault VM RAM after `UNLOCK`.

**Boundary 4 \- Wayland clipboard isolation**

Credentials flow: vault VM → vsock → host → `wl-copy`. The Wayland compositor manages clipboard access \- only the focused window can read it. The 30-second auto-clear (`wl-copy --clear`) limits the exposure window.

*Protects against:* Unfocused VM windows cannot silently harvest copied passwords.

**Boundary 5 \- AES-256 at rest**

`~/vault/Passwords.kdbx` is world-readable and committed to git. This is intentional \- the file is an opaque ciphertext without the master password.

*Protects against:* Physical disk theft, git repository compromise, or a host process reading the file directly yields only ciphertext.

#### Data Flow

**Unlock:**
```
launcher password prompt (host)
  │  master password typed - never stored on host
  ▼
vault-pick-tui
  │  printf '%s' "UNLOCK <password>" | socat → VSOCK-CONNECT:213:14514
  ▼
vault-agent (vault VM, vault user)
  │  keepassxc-cli ls Passwords.kdbx  ← verifies password
  │  write password → /run/vault-session/token (mode 600)
  │  rm -f /run/vault-session/locked
  ▼
host receives: "OK"
```

**GET credential:**
```
vault-pick-tui
  │  echo "GET <entry> password" | socat → VSOCK-CONNECT:213:14514
  ▼
vault-agent
  │  touch /run/vault-session/token  (resets idle timer)
  │  cat token | keepassxc-cli show --show-protected Passwords.kdbx "<entry>"
  ▼
host receives: "OK <value>"
  │
  ▼
printf '%s' "$val" | wl-copy        (host only \- never enters VM clipboard)
(sleep 30; wl-copy --clear) &       (background auto-clear)
```

**Sync:**
```
vault-cli sync
  │  echo "SYNC vault" | socat → VSOCK-CONNECT:211:14512  (gitsync VM)
  ▼
gitsync VM: git add -A && git commit && git push ~/vault/ → GitHub
```

#### vsock Protocol (port 14514)

One command per connection. Line-based text.

| Command | Response | Notes |
|---------|----------|-------|
| `PING` | `PONG` | Connectivity check |
| `UNLOCK <password>` | `OK` / `ERROR <reason>` | Stores pw in session tmpfs |
| `LOCK` | `OK` | Touches lockfile; leaves token intact |
| `STATUS` | `LOCKED` / `UNLOCKED <n>` | `<n>` = entry count |
| `LIST` | `OK\n<entry>\n...` / `ERROR` | `OK` on first line, one entry per line after |
| `GET <entry> <field>` | `OK <value>` / `ERROR` | field: `password` `username` `url` `notes` |

Every command except `UNLOCK` and `PING` triggers an idle check: if `mtime(token) + 300s < now`, the lockfile is set before handling the command.

#### Session Lifecycle

```
VM boot → tmpfs mounted at /run/vault-session/ (empty) → vault-agent listening

UNLOCK  → token written (mode 600) → locked file removed
Active  → each GET/LIST touches token → 1-min timer checks mtime
Idle >5m → lockfile created (token preserved for re-unlock without retype? No \- UNLOCK rewrites)
Locked  → GET/LIST return ERROR vault is locked
VM reboot / shutdown → tmpfs destroyed → starts locked
```

#### Host Tools

| Command | Description |
|---------|-------------|
| `vault-cli unlock` | Unlock vault (prompts for master password) |
| `vault-cli lock` | Lock vault immediately |
| `vault-cli status` | Show `LOCKED` / `UNLOCKED <count>` |
| `vault-cli list` | List all entries |
| `vault-cli get <entry> <field>` | Get field value |
| `vault-cli sync` | Commit + push via gitsync VM |
| `vault-cli pull` | Pull from git via gitsync VM |
| `vault-cli ping` | Check vault VM connectivity |
| `vault-pick` | Interactive Wayland picker (`Mod+Shift+P`) |

#### Setup

**1. Add vault infra and host modules** (already in the flake template):

```bash
cp -r ~/Hydrix/templates/user-config/infra/vault ~/hydrix-config/infra/
cp ~/Hydrix/templates/user-config/modules/vault*.nix ~/hydrix-config/modules/
```

**2. Import in your machine config:**

```nix
imports = [ ../modules/vault.nix ];
```

**3. Add to machine autostart:**

```nix
hydrix.microvmHost.vms."microvm-vault" = { autostart = true; };
```

**4. Add keybind** in your WM keybindings module (`modules/hyprland.nix`, `modules/sway.nix`, or `modules/i3.nix`):

```
bind = $mod SHIFT, P, exec, vault-pick        # Hyprland
"${mod}+Shift+p" = "exec vault-pick";         # Sway
```

**5. Rebuild and initialize the database:**

```bash
rebuild
mvm rebuild vault && microvm start vault
microvm console microvm-vault
# Inside VM:
keepassxc-cli db-create /var/lib/vault/Passwords.kdbx --set-password
exit
# Fix ownership (DB created as root via console autologin):
sudo chown $USER:users ~/vault/Passwords.kdbx && chmod 644 ~/vault/Passwords.kdbx
vault-cli unlock
```

**6. Initialize git repo** (for multi-machine sync):

```bash
cd ~/vault && git init
git add Passwords.kdbx && git commit -m "init vault"
git remote add origin git@github.com:youruser/vault-private.git
git push -u origin master
```

#### Multi-Machine Setup

On a new machine after `rebuild`:

```bash
vault-cli pull   # pulls ~/vault/ from GitHub via gitsync VM
vault-cli unlock # enter master password
```

#### Adding Entries

Via KeePassXC GUI (recommended):

```bash
nix shell nixpkgs#keepassxc -c keepassxc ~/vault/Passwords.kdbx
```

Via vault VM console:

```bash
microvm console microvm-vault
keepassxc-cli add /var/lib/vault/Passwords.kdbx "GitHub" --username myuser -p
exit
```

#### What It Does NOT Protect Against

| Threat | Notes |
|--------|-------|
| Compromised Wayland compositor | Controls clipboard; malicious compositor could intercept wl-copy |
| Host keylogger | Master password typed on host before reaching vault-pick |
| Host root ptrace | Could inspect vault-pick or wl-copy memory at credential-in-memory moment |
| Weak master password | Security only as strong as the password chosen |

#### Troubleshooting

**"ERROR wrong password" despite correct password** \- DB created as root, unreadable by vault agent:
```bash
sudo chown $USER:users ~/vault/Passwords.kdbx && chmod 644 ~/vault/Passwords.kdbx
```

**vault-cli ping returns nothing** \- vault VM not running:
```bash
microvm status microvm-vault
microvm start vault
```

**microvm start vault hangs / virtiofsd error `/home/user/vault does not exist`** \- missing username fix in `infraVMConfigs` in `flake.nix`. Ensure the block passes `{ hydrix.username = hostUsername; }`:
```nix
modules = [
  { hydrix.username = hostUsername; }
  (./infra + "/${m._infraName}/default.nix")
];
```

**Clipboard shows `PROTECTED`** \- vault VM runner is stale, rebuild it:
```bash
mvm rebuild vault
```

---

### In-VM Development (vm-dev workflow)

Test packages without nixos-rebuild using per-package flakes:

```bash
# === Inside VM ===
vm-dev build https://github.com/owner/repo   # Create flake from GitHub
vm-dev run repo                               # Test it works
vm-dev fix repo                               # Analyze build errors, suggest fixes
vm-dev list                                   # List local packages
vm-sync push --name repo                      # Stage for host integration

# === On host ===
vm-sync list                                  # List staged packages from running VMs
vm-sync pull repo --target pentest            # Pull to profiles/pentest/packages/
vm-sync status                                # Show packages per profile
microvm build microhack                       # Rebuild VM with new package
```

**Package locations:**
- VM development: `~/dev/packages/<name>/flake.nix`
- VM staging: `~/staging/<name>/package.nix`
- Host profiles: `~/hydrix-config/profiles/<type>/packages/<name>.nix`

The `vm-sync pull` command automatically:
1. Copies package to your user config's profile
2. Regenerates `packages/default.nix`
3. Stages for git tracking

### Live Switch (microvm update)

`microvm update` builds a new VM config and applies it without restart. 

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
   microvm build microvm-router && microvm restart microvm-router
   ```

### How It Works

At router boot, `vpn-boot-assign` brings up a `wg-<bridge>` WireGuard interface for each entry in the bridges map and routes that bridge's traffic through it. Bridges not in the map go direct. The router uses policy routing (one table per subnet, table ID = CID) so each bridge is fully isolated, a browsing VM and a pentest VM can exit through different countries simultaneously.

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
3. Rebuild the router: `microvm build microvm-router && microvm restart microvm-router`

---

## Vsock Communication

All host-VM communication uses virtio-vsock. No SSH or network access to VMs. Each VM has a unique CID (Context ID).

### Port Assignments

| Port | Service | Direction | Purpose |
|------|---------|-----------|---------|
| 14500 | xpra-vsock | Host -> VM | GUI app forwarding and display (X11 mode) |
| 14501 | vm-metrics | Host -> VM | Poll CPU, RAM, disk, uptime |
| 14502 | vm-staging | Host -> VM | List/pull staged packages (vm-sync) |
| 14503 | vm-colorscheme | Host -> VM | Push colorscheme updates (REFRESH) |
| 14504 | vm-switch | Host -> VM | Live NixOS config switch (SWITCH/TEST/STATUS/PING) |
| 14505 | files-agent | Host -> Files VM | File transfer ops (FETCH/DELIVER/STORE/LIST) |
| 14506 | vm-files-agent | Host -> any VM | Per-VM file ops (ENCRYPT/DECRYPT/SERVE/CLEANUP) |
| 14505 | pulse-vsock | VM -> Host | PulseAudio/PipeWire audio bridge (VM→host, proxied to TCP:4713) |
| 14508 | waypipe-launch | Host -> VM | App launch commands (Wayland mode) |
| 14509 | display-mode | Host -> VM | Display mode selector / readiness gate: `PING`/`waypipe-reconnect`/`STATUS`/`stop` |
| 14510 | builder-build | Host -> Builder | Send build commands |
| 14511 | builder-status | Host -> Builder | Query builder status |
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

| Tag | Source (Host) | Mount (VM) | Protocol | Purpose |
|-----|---------------|------------|----------|---------|
| `nix-store` | `/nix/store` | `/nix/.ro-store` | virtiofs | Shared nix store (read-only base) |
| `vm-config` | `/var/lib/microvms/<vm>/config` | `/mnt/vm-config` | 9p | VM config, live switch registration |
| `hydrix-config` | `~/.config/hydrix` | `/mnt/hydrix-config` | 9p | Host config (scaling.json for DPI) |
| `vm-secrets` | `/run/hydrix-secrets/<vm>` | `/mnt/vm-secrets` | virtiofs | GitHub SSH keys |

### Nix DB Registration

Paths exist in the VM's `/nix/store` via virtiofs but the VM's local nix database (`/nix/var/nix/db/db.sqlite`) doesn't know about them. This matters during `microvm update` \- home-manager's `nix-store --realise` queries the local DB. The host dumps registration info before switching, and the VM loads it with `nix-store --load-db`.

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
rebuild -m              # Pre-build microVM runners
rebuild -v              # Verbose output

# Backwards-compat alias
nixbuild                # Same as rebuild
```

### Builder VM (Lockdown Mode)

The builder VM enables nix builds in lockdown mode when the host has no internet. It fetches dependencies via the router VM and writes build outputs directly to the host's `/nix/store`.

**Commands:**

```bash
# Build a single target
microvm builder build browsing
microvm builder build host

# Build multiple targets in one session (eval cache stays warm)
microvm builder build browsing pentest dev

# Build and immediately switch host config
microvm builder switch                 # Switches to current specialisation
microvm builder switch administrative  # Switch to specific specialisation

# Prefetch only (keep builder running for batch operations)
microvm builder fetch browsing
microvm builder fetch pentest
microvm builder stop                  # Stop when done

# Manual control
microvm builder start                 # Start builder (stops host nix-daemon)
microvm builder shell                 # Attach to builder console
microvm builder status                # Check builder state
microvm builder stop                  # Stop builder (restarts host nix-daemon)
```

**Named targets:**

| Target | Resolves To |
|--------|-------------|
| `browsing` | `microvm-browsing` |
| `pentest` | `microvm-pentest` |
| `dev` | `microvm-dev` |
| `comms` | `microvm-comms` |
| `lurking` | `microvm-lurking` |
| `router` | `microvm-router` |
| `builder` | `microvm-builder` |
| `host` | Host NixOS config |

**Operational flow:**

```
microvm builder build browsing

1. Host nix-daemon stops, /nix/store remounted R/W
2. Builder VM starts with virtiofs /nix/store access
3. Builder evaluates flake (cached after first build)
4. Dependencies fetched via router VM (has internet)
5. Build happens in builder, outputs written to host's /nix/store
6. Builder stops, /nix/store remounted R/O
7. Host nix-daemon restarts
8. Host builds packages instantly (all deps already in store)
```

**Builder shell access:**

```bash
microvm builder shell

# Inside builder:
nix flake metadata            # Check flake inputs
nix build .#microvm-browsing  # Manual build
exit                          # Return to host, builder stops
```

**Status checking:**

```bash
microvm builder status

# Output:
# Builder state: running
# Process ID: 12345
# Target: browsing
# Progress: building...
```

**Recovery if builder crashes:**

```bash
# If builder is stuck
microvm stop microvm-builder  # This also restores host nix-daemon

# If store is still rw after crash
sudo mount -o remount,ro /nix/store
sudo systemctl start nix-daemon
```

**Persistent eval cache:**

The builder maintains an 8GB persistent volume (`builder-cache.img` at `/root/.cache/nix`) that survives restarts. First build after purge is slow (2+ min for flake eval); subsequent builds skip evaluation entirely.

To reset:
```bash
microvm builder purge          # Remove builder-cache.img
microvm builder start          # Rebuild clean cache
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
```

---

## Shell

Fish shell with babelfish for fast environment variable sourcing.

### Abbreviations & Aliases

The Hydrix framework provides several shell abbreviations for common commands:

| Abbreviation | Expands to | Purpose |
|--------------|------------|---------|
| `mvm` | `microvm` | Multi-VM command runner |
| `za` | `zenaudio` | Audio device switcher (ASUS ZenBook) |
| `zas` | `zenaudio speakers` | Enable internal speakers |
| `zah` | `zenaudio headphones` | Enable headphones |
| `zab` | `zenaudio bluetooth` | Enable Bluetooth headset |
| `za` | `zenaudio toggle` | Toggle speakers/headphones |
| `rvm` | `rebuildvms` | Rebuild multiple VMs at once |

**Multi-VM commands** - `mvm` expands to `microvm mvm`, allowing you to run commands on multiple VMs:

```fish
# Build multiple VMs at once
mvm build files pentest browsing

# Restart multiple VMs
mvm restart files pentest browsing dev

# Rebuild (build + restart) multiple VMs
mvm rebuild vault files pentest browsing

# Same as: microvm mvm build files pentest browsing
# The 'microvm mvm' subcommand also works for non-fish shells
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

Workspaces are mapped to VMs via the `ws-app` script. Pressing `Super+Return` launches a terminal in the correct context, host or VM, based on the focused workspace.

### Workspace Mapping

| Workspace | Target | Behavior |
|-----------|--------|----------|
| WS1 | Host | Always host terminal |
| WS2 | Pentest VM | Active VM tracking |
| WS3 | Browsing VM | Active VM tracking |
| WS4 | Comms VM | Fixed (microvm-comms) |
| WS5 | Dev VM | Active VM tracking |
| WS6 | Lurking VM | Fixed (microvm-lurking) |
| WS7-9 | Host | Always host terminal |
| WS10 | Router | Serial console |

> **Note**: VM workspaces are dynamic \- they're read from `/etc/hydrix/vm-registry.json` at runtime. Adding a new profile VM automatically adds its workspace mapping. No hardcoded workspace→VM tables in scripts.

### vm-registry Integration

All workspace→VM routing reads from `/etc/hydrix/vm-registry.json` at runtime:

```
ws-app (Super+Return)
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

**focus-dynamic module** (status bar) - Shows which VM type is focused on each workspace, using the same registry lookup.

**focus menu** (launcher) - Press `Mod+F4` to enter focus mode. The menu is built by scanning vm-registry for all profile VMs.

### Active VM Tracking

For workspace types that support multiple VMs (pentest, browsing, dev), `ws-app` remembers your last-used VM in `~/.cache/hydrix/active-vms.json`.

**Selection logic**:
1. If active VM is set and still running → use it
2. If active VM stopped → find all running VMs of that type
   - Exactly one → use it, update active
   - Multiple -> show launcher selection menu, update active
   - None → fall back to host, clear active

**Manual VM selection**: Use `ws-rofi` (or `Mod+d` on a VM workspace) to choose which VM is "active" for that type.

### Launch Flow

**X11 / i3 (xpra mode):**
```
Super+Return
  -> ws-app alacritty
  -> detect focused workspace (i3-msg)
  -> query /etc/hydrix/vm-registry.json for workspace→profile mapping
  -> if profile found:
       -> get active VM for type (or show menu)
       -> xpra control vsock://<CID>:14500 start -- alacritty
       -> auto-attach xpra if not attached
  -> if no profile (WS1, WS7-9, or missing registry):
       -> alacritty-dpi (DPI-aware host terminal)

Super+Shift+Return
  -> alacritty-dpi (always host, regardless of workspace)
```

**Wayland / Hyprland or Sway (waypipe mode):**
```
Super+Return
  -> hypr-ws-app alacritty  (or sway-ws-app on Sway)
  -> detect focused workspace
  -> query vm-registry for workspace->VM mapping
  -> if VM not running: notify "use microvm start <vm>", exec host terminal
  -> if waypipe-connect not running: start it (setsid, background), wait 1s
  -> poll vsock:14509 STATUS every 1s until "waypipe" (up to 20s)
  -> send "alacritty" to vsock:14508 (waypipe-launch)
  -> VM runs alacritty with WAYLAND_DISPLAY=waypipe-0
  -> window appears on host desktop, compositor routes it to correct workspace
```

### waypipe VM Forwarding (Wayland)

waypipe is used when the host runs a Wayland compositor (Hyprland or Sway). VM apps appear as individual windows on the host desktop with no visible border between "VM app" and "host app".

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
| `microvm start <vm>` | Polls `PING` on vsock:14509 until VM responds `OK`, then starts `waypipe-connect <vm>` in background + sends notification |
| `waypipe-connect` starts | Starts host-side `waypipe client` listener, sends `waypipe-reconnect` to VM via vsock:14509 |
| VM receives `waypipe-reconnect` | Restarts `waypipe-vsock`; VM's waypipe server connects out to host vsock port |
| Compositor starts (VMs already running) | `waypipe-connect-all` spawns one poller per running VM; each polls `PING->OK` then starts `waypipe-connect` immediately |
| App launched | ws-app sends command to vsock:14508; VM runs app under `WAYLAND_DISPLAY=waypipe-0` |
| Connection drops | VM `waypipe-vsock` has `Restart=always`; host `waypipe-connect` has restart loop - both self-heal |
| `exit-wayland` | Kills all `waypipe-connect` processes; pushes `stop` to VMs; unsets `WAYLAND_DISPLAY` |

**Display mode selection (vsock:14509):**

The `display-mode` service on each VM accepts these commands:

| Command | Effect |
|---------|--------|
| `xpra` | Stops waypipe services, starts xpra-vsock |
| `waypipe` | Stops xpra-vsock, starts/restarts waypipe-vsock + waypipe-launch |
| `STATUS` | Returns `"waypipe"`, `"xpra"`, or `"none"` |
| `stop` | Stops all display services (WM exiting) |
| `PING` | Returns `"OK"` (VM readiness check) |

**Known gotcha \- `set -e` and the restart loop:**

`waypipe-connect` uses `set -euo pipefail`. The `waypipe client` command exits non-zero when the VM disconnects cleanly. Without `|| true` on the waypipe invocation, the bash wrapper exits silently and the restart loop never runs - leaving the host with no active tunnel while `pgrep` still finds nothing, causing the ws-app script to keep trying to start the tunnel from scratch. The fix: `waypipe client || true` in the while loop.

**Known gotcha \- STATUS false positive:**

`STATUS` checks both `[[ -S /run/user/1000/waypipe-0 ]]` AND `systemctl is-active --quiet waypipe-vsock`. Checking only the socket file is insufficient, it can persist after the service has stopped (crashed, or stopped by `stop` push). If STATUS incorrectly returns `"waypipe"`, the ws-app script proceeds to launch the app which then fails silently (app starts in VM but no window appears on host).

### Adding a New Profile VM

**Use the scaffold script**, it auto-discovers the next free CID/workspace, creates all files, and stages them for git:

```bash
new-profile myprofile
```

The script scans existing profiles for the next free CID (starts at 107), prompts for any values it can't auto-derive, copies `templates/profiles/_template/`, substitutes `__PLACEHOLDER__` values, and runs `git add`. Profile VMs are **auto-discovered** by the flake, no manual wiring in `flake.nix` required.

**After scaffolding, complete integration manually:**

1. Declare in `machines/<serial>.nix`: `hydrix.microvmHost.vms."microvm-myprofile" = { enable = true; };`
2. Customise `profiles/myprofile/default.nix` ,colorscheme, RAM/vCPUs, packages
3. Add VPN if needed: `hydrix.router.vpn.mullvad.bridges.myprofile = ./conf;`
4. Rebuild in order (router and files VM have TAPs baked into their QEMU runner):
```bash
rebuild                       # creates bridge, updates tapLookupScript + vm-registry
mvm rebuild router files      # picks up new subnet TAP + new bridge leg
microvm build microvm-myprofile && microvm start microvm-myprofile
```

**What auto-adapts after rebuild** (no manual wiring needed):
- `ws-app` routes workspace -> new VM (reads vm-registry at runtime)
- status bar `workspace-desc` shows new label; `focus-dynamic` shows new VM type
- focus menu includes new VM
- `hydrix-switch` and `router-status` include the new bridge

**What you add manually:**
- Dedicated keybindings (e.g., `Mod+Control+b` always opens browser on browsing VM)
- App-specific shortcuts if you want them beyond workspace-routing

For detailed runtime data flow, see `POLYBAR-VM-INTEGRATION.md` in your config directory.

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
| `Mod+F12` | Screenshot |

### Configuration Editing

| Key | Action |
|-----|--------|
| `Mod+Shift+i` | Edit i3 config |
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
| `wifi-sync poll` | Query router VM for current networks, compare with local config |
| `wifi-sync pull` | Pull credentials from router, update `modules/wifi.nix` |
| `wifi-sync status` | Quick sync status check |

### MicroVM

| Command | Purpose |
|---------|---------|
| `microvm <cmd>` | MicroVM management CLI |
| `microvm build <name>` | Build/rebuild VM |
| `microvm start <name>` | Start VM (polls PING->OK, starts display tunnel) |
| `microvm app <name> <cmd>` | Launch app in VM |
| `microvm stop <name>` | Stop VM |

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
From the files VM console (`microvm console microvm-files`), ping the target VM:
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
microvm logs <name>

# Verify vsock CID is unique
microvm list

# Ensure host modules are loaded
lsmod | grep vhost_vsock
```

### No Display in VM

```bash
# Check xpra status (i3/X11 only)
xpra info vsock://<CID>:14500

# Re-attach manually (i3/X11 only)
microvm attach <name>
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
| STATUS returns `"none"` indefinitely | `display-mode` not receiving push, or VM not booted | Check `pgrep -af waypipe-connect`; restart `microvm start` |

### Waypipe: ws-app Errors "waypipe not ready after 20s"

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
microvm console microrouter

# Verify NetworkManager
nmcli device status
```

### New WiFi Network Not Connecting After Rebuild

Rebuilding and restarting the router VM is not enough when you add or remove a network from `wifi.nix`. NetworkManager's persistent state in `/var/lib/NetworkManager/` survives VM restarts and takes precedence over the newly generated `/run/` connections.

Fix: purge the router VM so it starts with a clean NM state:

```bash
microvm purge microvm-router --force
microvm build microvm-router
microvm start microvm-router
```

After a purge, only the connections declared in `wifi.nix` (written to `/run/` at boot) exist, and NM connects normally.

### Host Has No Internet (Expected in Lockdown)

This is the intended behavior. Use the builder VM:

```bash
microvm builder build <target>
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

## Wayland Stack (Hyprland / Sway)

Hydrix supports Hyprland (primary) and Sway as Wayland compositors. VM apps are forwarded to the host desktop via **waypipe**, appearing as individual native windows. i3 is also available as an X11 option. All three default to disabled - enable exactly one.

### Enabling

```nix
# machines/<serial>.nix - enable exactly one
hydrix.hyprland.enable = true;  # Wayland, VM apps forwarded via waypipe (recommended)
# hydrix.sway.enable = true;    # Wayland, VM apps forwarded via waypipe
# hydrix.i3.enable = true;      # X11, VM apps forwarded via xpra
```

### Programs per WM

| Component | Hyprland | Sway | i3 |
|-----------|----------|------|----|
| Compositor/WM | Hyprland | Sway | i3 |
| Status bar | waybar | waybar | polybar |
| Launcher | wofi | wofi | rofi |
| Lockscreen | hyprlock | swaylock | xss-lock |
| VM forwarding | waypipe | waypipe | xpra |

Start the session:
```bash
hyprland-session   # Hyprland - cleans up waypipe + env on exit
sway-session       # Sway - cleans up waypipe + env on exit
```

### Module Overview

| Module | Location | What it provides |
|--------|----------|-----------------|
| `wm/sway.nix` | `modules/wm/sway.nix` | NixOS Sway enablement, polkit, portals, packages |
| `graphical/programs/sway.nix` | `modules/graphical/programs/sway.nix` | Home-manager Sway config: gaps, input, startup, colors |
| `wm/waypipe-host.nix` | `modules/wm/waypipe-host.nix` | Host-side scripts: `waypipe-connect`, `waypipe-connect-all`, `sway-ws-app`, `hypr-ws-app`, `vm-push-display-mode`, `exit-wayland`, `exit-i3`; PipeWire vsock audio bridge (`pulse-vsock`) |
| `vm/waypipe-vm.nix` | `modules/vm/waypipe-vm.nix` | VM-side systemd services: `display-mode` (vsock:14509), `waypipe-vsock`, `waypipe-launch` (vsock:14508), `pulse-vsock` (PulseAudio bridge to host) |

**`waypipe-host.nix`** is auto-imported by `core.nix` and activates when `sway.enable` or `hyprland.enable` is true. No explicit import needed in your machine config.

**`waypipe-vm.nix`** is auto-imported by `vm-base.nix` for all profile VMs. It coexists with xpra \- the `display-mode` handler (vsock:14509) switches between them at runtime based on what the host pushes.

### Display Mode Switching

The host connects to each VM's `display-mode` service (vsock:14509) to switch display services:

**Wayland (Hyprland/Sway):** `waypipe-connect` sends `waypipe-reconnect` directly to the VM, bypassing `vm-push-display-mode`. The VM unconditionally restarts `waypipe-vsock` and connects to the host listener.

**X11 (i3):** `vm-push-display-mode` sends `xpra` to the VM, which starts `xpra-vsock`.

```
microvm start <vm>  [Wayland]
  → polls PING→OK on vsock:14509
  → starts waypipe-connect (sends waypipe-reconnect internally)

microvm start <vm>  [X11]
  → polls PING→OK on vsock:14509
  → vm-push-display-mode sends "xpra" to vsock:14509
```

Manual overrides:
```bash
vm-push-display-mode            # auto-detect from env (xpra only)
vm-push-display-mode xpra       # force xpra on all VMs
vm-push-display-mode stop       # stop all display services in all VMs
waypipe-connect <vm>            # manually start/restart waypipe for one VM
waypipe-connect-all             # connect waypipe for all running profile VMs
```

### Keybindings

User keybindings live in `modules/hyprland.nix`, `modules/sway.nix`, or `modules/i3.nix` in your hydrix-config depending on which WM is enabled. Sway and i3 modules mirror each other - same workspace bindings, same VM routing pattern.

### Internal Display Scaling (Wayland)

Unlike i3 (which uses xrandr), Sway and Hyprland use per-output scale. External monitors are unaffected.

```nix
# machines/<serial>.nix
hydrix.graphical.scaling.swayInternalScale  = 1.25;   # 25% larger UI (crisp, native res kept)
hydrix.graphical.scaling.swayInternalMode   = "1280x800"; # OR: change actual hw resolution
hydrix.graphical.scaling.swayInternalOutput = "eDP-1";    # default; run: swaymsg -t get_outputs
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
                                           socat VSOCK-LISTEN:14505 → UNIX-CLIENT:pulse/native
                                                                              │
                                                                    PipeWire (host)
                                                                    (auth.anonymous = true)
```

**Host side (`waypipe-host.nix`):**

- `pulse-vsock` user service: bridges `VSOCK-LISTEN:14505` -> `UNIX-CLIENT:/run/user/1000/pulse/native` (host PipeWire)
- PipeWire anonymous auth enabled on its unix socket so VM clients (which have no host cookie) are accepted:
  ```nix
  services.pipewire.extraConfig.pipewire-pulse."10-vm-audio" = {
    "pulse.properties"."server.address" = [
      { "address" = "unix:native"; "auth.anonymous" = true; }
    ];
  };
  ```
  Any client that can reach the socket is accepted without a cookie. The only clients that can reach it are VMs on this machine via vsock \- so on a single-user machine where you own all VMs, there is no meaningful threat. On a shared machine with untrusted VMs, you would want proper auth instead.

**VM side (`waypipe-vm.nix`):**

- `pulse-vsock` system service: creates `/run/user/1000/pulse/host-native` → `VSOCK-CONNECT:2:14505`
- Waits for `/run/user/1000/pulse/native` (the VM's own PipeWire socket) before creating its socket. This avoids a race where `systemd --user` initialises the user session and wipes `/run/user/1000` after the socket was created.
- Uses a separate path (`host-native`) to avoid conflicting with the VM's own `pipewire-pulse` which owns `pulse/native`.
- `PULSE_SERVER=unix:/run/user/1000/pulse/host-native` is injected into the environment of every app launched via `waypipe-launch`.

**Lifecycle:**

| Event | Audio action |
|-------|-------------|
| `display-mode` receives `waypipe` or `waypipe-reconnect` | Starts `pulse-vsock` in VM |
| `display-mode` receives `xpra` | Stops `pulse-vsock` (xpra handles audio internally) |
| `display-mode` receives `stop` | Stops `pulse-vsock` alongside all display services |

No configuration required \- audio works automatically for all profile VMs as soon as they are started in waypipe mode.

### Status Bar Notes

**Hyprland:** waybar is used as the status bar, managed via a systemd user service and restarted automatically on monitor add/remove events.

**Sway:** polybar runs under XWayland. The `xworkspaces` module uses `type = internal/i3` (polybar's Sway-compatible mode). The bar is launched by `display-setup --no-move` from the Sway startup command, with `I3SOCK=$SWAYSOCK` so the workspace module connects to Sway's IPC.

**i3:** polybar runs natively under X11.

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
| `~/.cache/hydrix/active-vms.json` | Workspace-VM tracking (ws-app) |
| `/var/lib/microvms/<name>/` | MicroVM persistent data |
| `/var/lib/microvms/<name>/config/.switch-reg` | Nix DB registration for live switch |
| `/var/lib/libvirt/base-images/` | Libvirt base images |
| `/etc/HYDRIX_MODE` | Current boot mode (lockdown/administrative/fallback) |

---

## Related Documentation

- [secrets/README.md](./secrets/README.md) - Secrets management setup

---
