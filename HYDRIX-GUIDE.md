# Hydrix - VM Isolation System

Hydrix is a NixOS-based VM automation system that provides network isolation through virtualization. The host machine passes its network interface to a router VM, which handles all routing, NAT, and optionally VPN policy routing for complete traffic isolation.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ HOST MACHINE                                                                │
│                                                                             │
│  Physical NIC ──► VFIO Passthrough ──► Router VM                           │
│                                                                             │
│  Host creates BRIDGES ONLY - Router VM handles ALL networking              │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ UNIFIED BRIDGES (same names in all modes)                            │   │
│  │                                                                      │   │
│  │   br-mgmt    → Management (host ↔ router communication)             │   │
│  │   br-pentest → Pentest VMs                                          │   │
│  │   br-office  → Office/Comms VMs                                     │   │
│  │   br-browse  → Browsing VMs                                         │   │
│  │   br-dev     → Development VMs                                      │   │
│  │                                                                      │   │
│  │ Router/Maximalism: 192.168.100-104.x (simple NAT)                   │   │
│  │ Lockdown:          10.100.0-4.x (VPN policy routing)                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │ Pentest  │  │  Comms   │  │ Browsing │  │   Dev    │                   │
│  │   VM     │  │   VM     │  │    VM    │  │   VM     │                   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘                   │
│       │             │             │             │                          │
│       └─────────────┴──────┬──────┴─────────────┘                          │
│                            │                                                │
│                    ┌───────┴───────┐                                       │
│                    │  Router VM    │                                       │
│                    │  (has NIC)    │                                       │
│                    │               │                                       │
│                    │ DHCP/NAT/     │                                       │
│                    │ VPN Routing   │                                       │
│                    └───────────────┘                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Operating Modes

### Base Mode
- Normal laptop operation
- WiFi/Ethernet on host directly
- No passthrough, no router VM
- Standard networking

### Router Mode
- NIC passed to router VM via VFIO
- Router VM handles NAT for host
- Basic bridge setup (virbr1-5)
- Host gets internet through router

### Maximalism Mode
- Same as router mode
- All VM types available
- Standard 192.168.x.x networks
- Default boot target

### Lockdown Mode
- Same NIC passthrough as router/maximalism
- **Isolated bridges** (br-pentest, br-office, br-browse, br-dev)
- **No inter-VM traffic** (network isolation)
- **VPN policy routing** - each network can route through different VPN
- **Kill switch** - traffic blocked if VPN is down
- Host has **zero internet access**

## Mode Switching

```
                    ┌─────────┐
                    │  BASE   │
                    │  MODE   │
                    └────┬────┘
                         │
                    REQUIRES REBOOT
                    (kernel params)
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
   ┌─────────┐     ┌───────────┐    ┌──────────┐
   │ ROUTER  │◄───►│MAXIMALISM │◄──►│ LOCKDOWN │
   │  MODE   │     │   MODE    │    │   MODE   │
   └─────────┘     └───────────┘    └──────────┘
        │                │                │
        └────────────────┴────────────────┘
                         │
               NO REBOOT NEEDED
            (same kernel params)
```

**Switch between passthrough modes (instant):**
```bash
sudo nixos-rebuild switch --specialisation router
sudo nixos-rebuild switch --specialisation maximalism
sudo nixos-rebuild switch --specialisation lockdown
```

**Switch to/from base mode (requires reboot):**
```bash
sudo nixos-rebuild boot --flake ~/Hydrix#<machine>
sudo reboot
```

## Setup on New Machine

### Prerequisites
- Fresh NixOS installation
- Nix flakes enabled
- Git installed
- IOMMU-capable CPU (Intel VT-d or AMD-Vi)
- Network card that supports passthrough

### Step 1: Enable Flakes

```bash
# Edit /etc/nixos/configuration.nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];

sudo nixos-rebuild switch
```

### Step 2: Clone and Setup

```bash
cd ~
git clone <hydrix-repo-url> Hydrix
cd Hydrix
git checkout lockdown-isolation

# Run automated setup
./scripts/setup-machine.sh
```

The setup script automatically:
1. Detects hostname and CPU type (Intel/AMD)
2. Identifies network hardware for passthrough
3. Generates machine-specific configuration
4. Updates flake.nix with new machine entry
5. Builds router VM image
6. Creates autostart scripts
7. Builds system with all boot entries

### Step 3: Reboot

```bash
sudo reboot
```

On first boot:
- System boots into maximalism mode (default)
- NIC driver is blacklisted for passthrough
- Bridges are created
- Router VM auto-deploys and starts
- Internet available through router VM

### Step 4: Verify

```bash
# Check current mode and status
vm-status

# Check router VM
sudo virsh list

# Test internet (through router)
ping google.com
```

## Lockdown Mode Usage

### Enter Lockdown Mode

```bash
sudo nixos-rebuild switch --specialisation lockdown
```

### Router VM Management

The lockdown router VM auto-starts. Access it via:

```bash
# SSH from any VM on management network
ssh traum@10.100.0.253

# Or via console
sudo virsh console lockdown-router
```

### VPN Configuration

Place WireGuard configs in `/etc/wireguard/` on the router:

```bash
# On router VM
sudo nano /etc/wireguard/mullvad.conf
```

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY
Address = 10.x.x.x/32
DNS = 10.64.0.1

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = server:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### VPN Assignment

```bash
# On router VM

# Check status
vpn-status

# Connect a VPN
vpn-assign connect mullvad

# Assign network to VPN
vpn-assign pentest client-vpn    # Pentest traffic → client VPN
vpn-assign browse mullvad        # Browsing → Mullvad
vpn-assign office corp-vpn       # Office → Corporate VPN
vpn-assign dev direct            # Dev → Direct internet (no VPN)

# Block a network entirely
vpn-assign pentest blocked       # Kill switch - no traffic allowed
```

### Deploy VMs in Lockdown

```bash
# From host - auto-detects lockdown mode
./scripts/build-vm.sh --type pentest --name engagement1
./scripts/build-vm.sh --type browsing --name personal

# VMs automatically use correct isolated bridges
```

## Network Reference

### Unified Bridges (All Modes)

All passthrough modes use the same bridge names. The router VM assigns different subnets based on detected mode.

| Bridge | Purpose | Standard Mode | Lockdown Mode |
|--------|---------|---------------|---------------|
| br-mgmt | Management | 192.168.100.0/24 | 10.100.0.0/24 |
| br-pentest | Pentesting | 192.168.101.0/24 | 10.100.1.0/24 (VPN) |
| br-office | Office/Comms | 192.168.102.0/24 | 10.100.2.0/24 (VPN) |
| br-browse | Browsing | 192.168.103.0/24 | 10.100.3.0/24 (VPN) |
| br-dev | Development | 192.168.104.0/24 | 10.100.4.0/24 |

### IP Assignments

| Role | Standard Mode | Lockdown Mode |
|------|---------------|---------------|
| Host (br-mgmt) | 192.168.100.1 | 10.100.0.1 |
| Router (br-mgmt) | 192.168.100.253 | 10.100.0.253 |
| Host Internet | Via router | **NONE** |

### Architecture Principle

**Host responsibilities (minimal):**
- Create bridge interfaces
- Assign IP on br-mgmt only
- Trust bridges in firewall
- Block outbound traffic (lockdown)

**Router VM responsibilities (all networking):**
- Configure IPs on bridge interfaces
- Run DHCP (dnsmasq) for all networks
- NAT to internet via passthrough NIC
- VPN policy routing (lockdown mode)
- Inter-network isolation

## File Structure

```
Hydrix/
├── flake.nix                      # Main flake - machine configs
├── modules/
│   ├── base/                      # Base system modules
│   │   ├── virt.nix              # Libvirt/QEMU setup
│   │   └── ...
│   ├── lockdown/                  # Lockdown mode modules
│   │   ├── bridges.nix           # Isolated bridge definitions
│   │   ├── host-lockdown.nix     # Host lockdown config
│   │   ├── vpn-routing.nix       # VPN policy routing
│   │   └── router-vm-config.nix  # Lockdown router config
│   ├── router-vm-unified.nix     # Unified router (both modes)
│   └── ...
├── profiles/
│   ├── machines/                  # Per-machine configs
│   │   └── <hostname>.nix
│   ├── pentest-full.nix          # VM profiles
│   ├── comms-full.nix
│   └── ...
├── scripts/
│   ├── setup-machine.sh          # Automated machine setup
│   ├── build-vm.sh               # VM deployment
│   ├── deploy-router.sh          # Router VM deployment
│   ├── vpn-assign.sh             # VPN management (router)
│   └── vpn-status.sh             # VPN status (router)
├── generated/
│   ├── modules/                   # Generated machine configs
│   └── scripts/                   # Generated autostart scripts
└── vpn-profiles/                  # VPN config templates
    ├── wireguard/
    └── openvpn/
```

## Key Commands

```bash
# System status
vm-status                    # Show current mode and VMs

# Mode switching (passthrough modes - no reboot)
sudo nixos-rebuild switch --specialisation router
sudo nixos-rebuild switch --specialisation maximalism
sudo nixos-rebuild switch --specialisation lockdown

# Mode switching (to base - requires reboot)
sudo nixos-rebuild boot --flake ~/Hydrix#<machine>
sudo reboot

# VM deployment
./scripts/build-vm.sh --type pentest --name <name>
./scripts/build-vm.sh --type comms --name <name>
./scripts/build-vm.sh --type browsing --name <name>
./scripts/build-vm.sh --type dev --name <name>

# Router management
sudo virsh console lockdown-router
ssh traum@10.100.0.253

# VPN management (on router)
vpn-status
vpn-assign <network> <vpn|direct|blocked>
vpn-assign connect <vpn>
vpn-assign disconnect <vpn>

# Mode-specific status
router-status      # Router mode
maximalism-status  # Maximalism mode
lockdown-status    # Lockdown mode
```

## Goals & Future Work

### Completed
- [x] NIC passthrough to router VM
- [x] Multiple operating modes (base/router/maximalism/lockdown)
- [x] Isolated bridge networks for lockdown
- [x] VPN policy routing per network
- [x] Kill switch (block if VPN down)
- [x] Network isolation (no inter-VM traffic)
- [x] Automated machine setup
- [x] VM deployment with auto mode detection

### Potential Enhancements
- [ ] DNS-over-HTTPS/TLS per network
- [ ] Traffic monitoring/logging on router
- [ ] Automatic VPN failover
- [ ] Web UI for VPN management
- [ ] GPU passthrough support
- [ ] Snapshot/restore for VMs
- [ ] Encrypted VM storage

## Troubleshooting

### Router VM won't start
```bash
# Check if image exists
ls -la /var/lib/libvirt/images/router-vm.qcow2

# Check libvirt
sudo systemctl status libvirtd

# Check passthrough
lspci -nnk | grep -A3 Network
```

### No internet in VMs
```bash
# On router, check WAN
ip addr show

# Check VPN status
vpn-status

# Check routing tables
ip route show table pentest
```

### Can't switch modes
```bash
# Check current mode
vm-status

# If going to/from base, must reboot
sudo nixos-rebuild boot --flake ~/Hydrix#<machine>
sudo reboot
```

---

## Quick Reference

```
┌────────────────────────────────────────────────────────────────┐
│                        HYDRIX MODES                            │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  BASE         Normal laptop, WiFi on host                     │
│               ↕ REBOOT REQUIRED                                │
│  ROUTER       NIC passthrough, 192.168.x.x                    │
│               ↕ switch --specialisation                        │
│  MAXIMALISM   Same as router (default boot)                   │
│               ↕ switch --specialisation                        │
│  LOCKDOWN     NIC passthrough, 10.100.x.x, VPN routing        │
│               Host has NO internet                             │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│                     UNIFIED BRIDGES                            │
├────────────────────────────────────────────────────────────────┤
│  br-mgmt     Management    192.168.100.x / 10.100.0.x         │
│  br-pentest  Pentesting    192.168.101.x / 10.100.1.x (VPN)   │
│  br-office   Office        192.168.102.x / 10.100.2.x (VPN)   │
│  br-browse   Browsing      192.168.103.x / 10.100.3.x (VPN)   │
│  br-dev      Development   192.168.104.x / 10.100.4.x         │
├────────────────────────────────────────────────────────────────┤
│                      KEY COMMANDS                              │
├────────────────────────────────────────────────────────────────┤
│  vm-status                    Current mode & VMs               │
│  router-status                Router mode info                 │
│  maximalism-status            Maximalism mode info             │
│  lockdown-status              Lockdown mode info               │
│  vpn-status                   VPN routing (on router)          │
│  vpn-assign <net> <vpn>       Assign network to VPN           │
│  ./scripts/build-vm.sh        Deploy new VM                    │
└────────────────────────────────────────────────────────────────┘
```
