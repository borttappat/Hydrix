# Hydrix Options Reference

All `hydrix.*` options available in the framework, organized by module.
Use this as a companion to `machines/installer.nix` and the templates in
`templates/user-config/` when setting up or customizing a machine.

## Sweep Progress

| Directory | mkDefault sweep | Documented |
|-----------|----------------|------------|
| `host/` | ✓ | ✓ |
| `theming/programs/` | — | — |
| `theming/wm/` | — | — |
| `theming/graphical/` | — | — |
| `vm/base/` | — | — |
| `vm/infra/` | — | — |
| `vm/pentest/` + `vm/dev/` | — | — |
| `vm/profiles/` | — | — |

---

## Conventions

- **mkDefault**: framework-provided values use `lib.mkDefault`. Plain assignment in
  `hydrix-config` always wins. `lib.mkForce` is only needed to override structural
  plumbing (virtiofs mounts, kernel modules, things that must match framework internals).
- **Template**: options marked ✓ appear as commented examples in the installer template.
  Options marked — are set to sensible defaults and rarely need overriding.

---

## Shared Options (`shared/options.nix`)

These options apply to both the host machine and all VMs.

### Identity

#### `hydrix.username`
| | |
|---|---|
| Type | `str` |
| Default | `"user"` |
| Template | ✓ `@USERNAME@` placeholder |

Primary username. Used for home directory, user creation, and paths throughout the config.

---

#### `hydrix.hostname`
| | |
|---|---|
| Type | `str` |
| Default | `"hydrix"` |
| Template | ✓ set to `"hydrix"` (visual hostname is always hydrix; machine is identified by serial) |

System hostname. The config file is named by hardware serial, not hostname.

---

#### `hydrix.user.hashedPassword`
| | |
|---|---|
| Type | `nullOr str` |
| Default | `null` |
| Template | ✓ `@PASSWORD_HASH@` placeholder |

Hashed password (`mkpasswd -m sha-512`). If null, user must set password manually on first login.

---

#### `hydrix.user.description`
| | |
|---|---|
| Type | `str` |
| Default | `cfg.username` |
| Template | — |

User account display name/full name.

---

#### `hydrix.user.sshPublicKeys`
| | |
|---|---|
| Type | `listOf str` |
| Default | `[]` |
| Template | — (add in machine config) |

SSH authorized keys for the primary user.

---

#### `hydrix.user.extraGroups`
| | |
|---|---|
| Type | `listOf str` |
| Default | `[]` |
| Template | — |

Additional groups beyond the framework defaults (`docker`, `audio`, `networkmanager`, `wheel`, `wireshark`, `adbusers`).

---

#### `hydrix.user.autologin`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | — |

Enable automatic console login for the primary user (TTY1). VMs override this to `true`.

---

### Paths

#### `hydrix.paths.configDir`
| | |
|---|---|
| Type | `str` |
| Default | `"/home/${username}/hydrix-config"` |
| Template | — |

Path to the user's hydrix-config repository. Override if you cloned it elsewhere.

---

#### `hydrix.paths.hydrixDir`
| | |
|---|---|
| Type | `str` |
| Default | `"/home/${username}/Hydrix"` |
| Template | — |

Path to the local Hydrix framework clone. Used by scripts that do layered lookups (colorschemes, profiles).

---

### Appearance

#### `hydrix.colorscheme`
| | |
|---|---|
| Type | `str` |
| Default | `"nord"` |
| Template | ✓ `@COLORSCHEME@` placeholder |

Colorscheme name. Must exist in `colorschemes/` (user dir checked first, then framework).
Affects pywal, Stylix, VM focus borders, alacritty, and all UI elements.

---

#### `hydrix.userColorschemesDir`
| | |
|---|---|
| Type | `nullOr path` |
| Default | `null` |
| Template | — |

Path to a custom colorschemes directory. User colorschemes take priority over the framework's built-in set.

---

### Default Applications

#### `hydrix.terminal`
| | |
|---|---|
| Type | `str` |
| Default | `"alacritty"` |
| Template | — |

Terminal emulator command. Used by WM keybindings.

---

#### `hydrix.shell`
| | |
|---|---|
| Type | `enum ["fish" "bash" "zsh"]` |
| Default | `"fish"` |
| Template | — |

Default user shell.

---

#### `hydrix.editor`
| | |
|---|---|
| Type | `str` |
| Default | `"vim"` |
| Template | — |

Default editor. Sets `EDITOR` and `VISUAL` environment variables.

---

### Services

#### `hydrix.services.tailscale.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ commented example in services section |

Enable Tailscale VPN mesh. After enabling, run `tailscale up` to authenticate.
Also available per-VM in each profile's `default.nix`.

---

### Networking (host)

#### `hydrix.networking.bridges`
| | |
|---|---|
| Type | `listOf str` |
| Default | `["br-mgmt" "br-pentest" "br-comms" "br-browse" "br-dev" "br-builder" "br-lurking" "br-files"]` |
| Template | — (auto-managed) |

Network bridges created on the host. The framework creates these automatically.
Do not remove entries that have active VMs.

---

#### `hydrix.networking.hostIp`
| | |
|---|---|
| Type | `str` |
| Default | `"192.168.100.1"` |
| Template | — |

Host IP on the management bridge (`br-mgmt`). Default gateway for host→router traffic.

---

#### `hydrix.networking.routerIp`
| | |
|---|---|
| Type | `str` |
| Default | `"192.168.100.253"` |
| Template | — |

Router VM's IP on the management bridge. Used as the host's default gateway in administrative mode.

---

#### `hydrix.networking.extraNetworks`
| | |
|---|---|
| Type | `listOf submodule` |
| Default | `[]` |
| Template | — |

Extra VM networks beyond the built-in 5. Each entry creates a host bridge, udev TAP rules, and a router subnet.
Fields: `name` (e.g. `"office"`), `subnet` (e.g. `"192.168.109"`), `routerTap` (e.g. `"mv-router-offi"`).

---

### Secrets

#### `hydrix.secrets.enable`
| | |
|---|---|
| Type | `bool` (mkEnableOption) |
| Default | `false` |
| Template | ✓ `secrets = { enable = false; ... }` |

Enable sops-nix secrets management. Requires setup: generate age key, configure `.sops.yaml`, encrypt secrets.

---

#### `hydrix.secrets.github.enable`
| | |
|---|---|
| Type | `bool` (mkEnableOption) |
| Default | `false` |
| Template | ✓ |

Enable GitHub SSH key provisioning to VMs. Requires `secrets.enable = true` and a configured `githubSecretsFile`.

---

#### `hydrix.secrets.githubSecretsFile`
| | |
|---|---|
| Type | `nullOr path` |
| Default | `null` |
| Template | ✓ commented example `../secrets/github.yaml` |

Path to the encrypted GitHub secrets YAML file in your hydrix-config.

---

### VM Color Inheritance

#### `hydrix.colorschemeInheritance`
| | |
|---|---|
| Type | `enum ["full" "dynamic" "none"]` |
| Default | `"dynamic"` |
| Template | — |

VM color inheritance mode. `full` = all colors from host; `dynamic` = host background, VM text colors; `none` = VM uses own colorscheme.

---

#### `hydrix.vmColors.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ in profile `default.nix` as `hydrix.vmColors.enable = true` |

Enable color inheritance from host for this VM. Set in each profile's `default.nix`.

---

#### `hydrix.vmColors.hostColorscheme`
| | |
|---|---|
| Type | `nullOr str` |
| Default | `null` |
| Template | — (set by flake.nix at build time) |

Host colorscheme name for VM inheritance. Set automatically by `flake.nix` from the host machine's `hydrix.colorscheme`. Do not set manually.

---

## Host Options (`host/options.nix`)

These options are host-only (not available in VMs).

### Router

#### `hydrix.router.type`
| | |
|---|---|
| Type | `enum ["microvm" "libvirt" "none"]` |
| Default | `"microvm"` |
| Template | ✓ `@ROUTER_TYPE@` placeholder |

Router VM type. `microvm` is the current standard. `libvirt` is legacy (being phased out). `none` for hosts that don't need a router VM.

---

#### `hydrix.router.autostart`
| | |
|---|---|
| Type | `bool` |
| Default | `true` |
| Template | ✓ set via `microvmHost.vms."microvm-router" = { autostart = true; }` |

Auto-start router VM at boot.

---

#### `hydrix.router.wifi.ssid` / `.password`
| | |
|---|---|
| Type | `str` |
| Default | `""` |
| Template | — (set in `shared/wifi.nix`) |

WiFi credentials for the router VM. Set in `shared/wifi.nix` shared across machines.

---

#### `hydrix.router.wifi.networks`
| | |
|---|---|
| Type | `listOf submodule` |
| Default | `[]` |
| Template | — |

Multiple WiFi networks for the router. Each entry has `ssid` and `password`. Used when roaming between networks.

---

#### `hydrix.router.wan.mode`
| | |
|---|---|
| Type | `enum ["auto" "pci-passthrough" "macvtap" "none"]` |
| Default | `"auto"` |
| Template | ✓ `@WAN_MODE@` placeholder |

WAN interface mode. `auto` detects PCI passthrough vs macvtap. `pci-passthrough` requires VFIO setup. `macvtap` for non-VFIO systems.

---

#### `hydrix.router.wan.device`
| | |
|---|---|
| Type | `nullOr str` |
| Default | `null` |
| Template | ✓ `@WAN_DEVICE@` placeholder |

Specific WAN device (PCI address for passthrough, interface name for macvtap). `null` = auto-detect.

---

#### `hydrix.router.wan.preferWireless`
| | |
|---|---|
| Type | `bool` |
| Default | `true` |
| Template | — |

In auto mode, prefer wireless WAN over wired when both are available.

---

#### `hydrix.router.microvm.dnsmasq.servers`
| | |
|---|---|
| Type | `listOf str` |
| Default | `["1.1.1.1" "8.8.8.8"]` |
| Template | — |

Upstream DNS servers used by the router's dnsmasq. Override for custom DNS.

---

#### `hydrix.router.vpn.mullvad.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ commented example `vpn.mullvad = import ../vpn/mullvad.nix` |

Enable Mullvad VPN on the router VM. Requires WireGuard config files in `vpn/`.

---

### Hardware

#### `hydrix.hardware.platform`
| | |
|---|---|
| Type | `enum ["intel" "amd" "generic"]` |
| Default | `"intel"` |
| Template | ✓ `@PLATFORM@` placeholder |

CPU platform. Loads the appropriate microcode and IOMMU settings.

---

#### `hydrix.hardware.isAsus`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ `@IS_ASUS@` placeholder |

Enable ASUS hardware-specific support (platform profile, battery charge limit, fan control).

---

#### `hydrix.hardware.asus.acProfile`
| | |
|---|---|
| Type | `enum ["Quiet" "Balanced" "Performance"]` |
| Default | `"Balanced"` |
| Template | — |

ASUS platform profile when plugged in. Affects CPU/GPU boost and fan behavior.

---

#### `hydrix.hardware.asus.batteryProfile`
| | |
|---|---|
| Type | `enum ["Quiet" "Balanced" "Performance"]` |
| Default | `"Quiet"` |
| Template | — |

ASUS platform profile on battery.

---

#### `hydrix.hardware.vfio.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `true` |
| Template | ✓ `@VFIO_ENABLE@` placeholder |

Enable VFIO/IOMMU for PCI passthrough (required for WiFi card passthrough to router VM).

---

#### `hydrix.hardware.vfio.pciIds`
| | |
|---|---|
| Type | `listOf str` |
| Default | `[]` |
| Template | ✓ `["@WIFI_PCI_ID@"]` |

PCI vendor:device IDs to bind to VFIO driver. Get with: `lspci -nn | grep -i wifi`.

---

#### `hydrix.hardware.vfio.wifiPciAddress`
| | |
|---|---|
| Type | `str` |
| Default | `""` |
| Template | ✓ `@WIFI_PCI_ADDRESS@` placeholder |

PCI address of the WiFi card (format `XX:XX.X`). Get with: `lspci | grep -i wifi`.

---

#### `hydrix.hardware.bluetooth.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `true` |
| Template | ✓ commented default `bluetooth.enable = true` |

Enable Bluetooth hardware support and Blueman manager.

---

#### `hydrix.hardware.i2c.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `true` |
| Template | ✓ commented default `i2c.enable = true` |

Enable I²C bus access (for DDC/CI monitor control, RGB controllers).

---

#### `hydrix.hardware.touchpad.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `true` |
| Template | ✓ commented default `touchpad.enable = true` |

Enable libinput touchpad support.

---

#### `hydrix.hardware.grub.gfxmodeEfi`
| | |
|---|---|
| Type | `str` |
| Default | `"1920x1200"` |
| Template | ✓ `@GRUB_GFXMODE@` placeholder |

GRUB EFI graphics mode. Set to your display's native resolution.

---

### Disk Layout (disko)

#### `hydrix.disko.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ `disko.enable = true` |

Enable declarative disk partitioning via disko. Required for automated installs.

---

#### `hydrix.disko.device`
| | |
|---|---|
| Type | `str` |
| Default | `"/dev/nvme0n1"` |
| Template | ✓ `@DEVICE@` placeholder |

Target disk for disko partitioning (e.g. `/dev/nvme0n1`, `/dev/sda`).

---

#### `hydrix.disko.swapSize`
| | |
|---|---|
| Type | `str` |
| Default | `"16G"` |
| Template | ✓ `@SWAP_SIZE@` placeholder |

Swap partition size. Recommended ≥ RAM for hibernate support.

---

#### `hydrix.disko.layout`
| | |
|---|---|
| Type | `enum ["full-disk-plain" "full-disk-luks" "dual-boot-plain" "dual-boot-luks"]` |
| Default | `"full-disk-plain"` |
| Template | ✓ `@LAYOUT@` placeholder |

Disk partitioning layout. `-luks` variants enable full-disk encryption.
`dual-boot-*` variants preserve a Windows partition.

---

#### `hydrix.disko.nixosPartition` / `.efiPartition`
| | |
|---|---|
| Type | `str` |
| Default | `""` |
| Template | ✓ placeholders |

Partition paths for dual-boot layouts (e.g. `/dev/nvme0n1p5`). Leave empty for full-disk layouts.

---

#### `hydrix.disko.efiBootloaderId`
| | |
|---|---|
| Type | `str` |
| Default | `"nixos"` |
| Template | ✓ `@EFI_BOOTLOADER_ID@` placeholder |

EFI bootloader entry identifier.

---

### Power Management

#### `hydrix.power.defaultProfile`
| | |
|---|---|
| Type | `enum ["powersave" "balanced" "performance"]` |
| Default | `"balanced"` |
| Template | — |

Default power profile.

---

#### `hydrix.power.chargeLimit`
| | |
|---|---|
| Type | `nullOr int (20-100)` |
| Default | `null` |
| Template | — (set in machine config) |

Battery charge limit percentage. `null` = no limit (charges to 100%). ASUS only.
Example: `60` to limit charge to 60% for laptop longevity.

---

#### `hydrix.power.autoCpuFreq`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ commented `autoCpuFreq = false` |

Enable `auto-cpufreq` daemon for dynamic CPU frequency scaling. Usually unnecessary with HWP/EPP.

---

### MicroVM Host

#### `hydrix.microvmHost.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ `microvmHost.enable = true` |

Enable microVM host support (TAP interfaces, udev rules, systemd units, etc.).

---

#### `hydrix.microvmHost.infrastructureOnly`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | — |

During first install, build only infrastructure VMs (router, builder) and skip profile VMs. Useful when profile VMs are not yet configured.

---

#### `hydrix.microvmHost.knownVms`
| | |
|---|---|
| Type | `listOf str` |
| Default | `[]` |
| Template | — (auto-populated by flake.nix from profiles/*/meta.nix) |

List of microVM names to auto-enable with defaults. Populated automatically by the flake from discovered profiles. Do not set manually.

---

#### `hydrix.microvmHost.vms`
| | |
|---|---|
| Type | `attrsOf submodule` |
| Default | `{}` |
| Template | ✓ explicit entries for router, hostsync, vault |

Per-VM configuration: `{ enable, autostart, secrets }`.
- `enable`: whether the VM is declared (default `true` for knownVms)
- `autostart`: start at boot (default `false`)
- `secrets`: list of secret types to provision (e.g. `["github"]`)

---

#### `hydrix.microvmHost.profileOverrides`
| | |
|---|---|
| Type | `attrsOf deferredModule` |
| Default | `{}` |
| Template | ✓ commented examples in `machines/installer.nix` |

Per-machine NixOS module overrides for profile VMs, keyed by profile name. Applied only on the machine where they are declared — not on other machines sharing the same flake.

Use cases:
- Tuning `microvm.virtiofsd.threadPoolSize` on lower-spec machines
- USB/webcam passthrough via `microvm.qemu.extraArgs`
- Any VM option that should differ per machine, not per profile

```nix
# machines/<serial>.nix
hydrix.microvmHost.profileOverrides = {
  browsing = { lib, ... }: {
    microvm.virtiofsd.threadPoolSize = lib.mkForce 1;
  };
  comms = { ... }: {
    microvm.qemu.extraArgs = [
      "-device" "qemu-xhci,id=usb-ctrl"
      "-device" "usb-host,vendorid=0x046d,productid=0x0825"
    ];
  };
};
```

Multiple modules for the same profile (e.g. from a helper module and the machine config directly) are merged by the NixOS module system.

---

### Builder / Git-Sync

#### `hydrix.builder.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ `builder.enable = true` |

Enable lockdown-mode nix builds via the microvm-builder VM. Enabled automatically by specialisations.nix.

---

#### `hydrix.gitsync.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ `gitsync.enable = true` |

Enable lockdown-mode git push/pull via microvm-gitsync VM.

---

### Libvirt (Legacy)

#### `hydrix.libvirt.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | — |

Enable libvirt/QEMU virtualization stack. Only needed if still using libvirt VMs.
The microvm router is the current standard; libvirt is being phased out.

---

## VM Options (`vm/options.nix` + `vm/infra/microvm-base.nix`)

These options are available inside microVM configurations.

### VM Identity

#### `hydrix.vm.hostname`
| | |
|---|---|
| Type | `str` |
| Default | same as `storeName` (e.g. `"microvm-lurking"`) |
| Template | ✓ commented in each profile's `default.nix` |

Hostname visible inside the VM — shown at the shell prompt, in logs, etc. Safe to override in `profiles/<name>/default.nix` with a plain assignment:

```nix
hydrix.vm.hostname = "minilurk";
```

**Warning:** changing this after the VM has run will orphan any persistent home volume (the volume path is derived from `storeName`, not this option, so data is safe — but you should rebuild before first use).

---

#### `hydrix.vm.storeName`
| | |
|---|---|
| Type | `str` |
| Default | nixosConfiguration key (e.g. `"microvm-lurking"`) |
| Template | — (set by framework via `lib.mkForce` — do not override) |

Structural identifier for this VM. Used for:
- Host-side storage paths (`/var/lib/microvms/<storeName>/`)
- Systemd service name (`microvm@<storeName>`)
- Waypipe window title prefix (`[lurking] …`)
- TAP interface default (`mv-<storeName>`)

Must stay in sync with the nixosConfiguration attribute name. Set automatically by the flake.

---

### VM Type

#### `hydrix.vmType`
| | |
|---|---|
| Type | `nullOr str` |
| Default | `null` |
| Template | — (set by framework, not user-configurable) |

VM type identifier (e.g. `"browsing"`, `"pentest"`). Read-only at runtime.

---

### Tor Hardening

#### `hydrix.tor.hardening.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ (lurking profile) |

Enable Tor traffic routing and hardening. Required for the lurking profile.

---

#### `hydrix.tor.hardening.level`
| | |
|---|---|
| Type | `enum ["minimal" "moderate" "paranoid"]` |
| Default | `"minimal"` |
| Template | — |

Tor hardening level. `paranoid` disables JavaScript in Firefox and enforces strictest exit node policies.

---

#### `hydrix.tor.hardening.bridgeType`
| | |
|---|---|
| Type | `enum ["none" "obfs4" "meek-azure" "snowflake"]` |
| Default | `"none"` |
| Template | — |

Tor bridge type for censored networks. `obfs4`/`snowflake` for high-censorship environments.

---

### VM Metrics

#### `hydrix.vmMetrics.vmCollectInterval`
| | |
|---|---|
| Type | `int` |
| Default | `5` |
| Template | ✓ commented in machine config `vmMetrics.vmCollectInterval = 5` |

How often (seconds) the VM collects metrics (CPU, RAM, disk).

---

#### `hydrix.vmMetrics.hostPollInterval`
| | |
|---|---|
| Type | `int` |
| Default | `5` |
| Template | ✓ commented |

How often (seconds) the host polls VMs for metrics.

---

#### `hydrix.vmMetrics.staleThreshold`
| | |
|---|---|
| Type | `int` |
| Default | `15` |
| Template | — |

Seconds without metrics before a VM is considered offline.

---

### MicroVM Resources

#### `hydrix.microvm.vcpu`
| | |
|---|---|
| Type | `int` |
| Default | `2` |
| Template | ✓ set per-profile (e.g. `vcpu = 4` for dev) |

Number of virtual CPU cores.

---

#### `hydrix.microvm.mem`
| | |
|---|---|
| Type | `int` |
| Default | `2304` |
| Template | ✓ set per-profile |

Memory in MiB. Balloon reclaims idle memory, so over-provisioning is fine.

---

#### `hydrix.microvm.vsockCid`
| | |
|---|---|
| Type | `int` |
| Default | `100` |
| Template | ✓ set via `meta.nix` |

VM vsock Context ID. Must be unique per VM. Convention: matches subnet last octet and workspace number.

---

#### `hydrix.microvm.bridge`
| | |
|---|---|
| Type | `str` |
| Default | `"br-browse"` |
| Template | ✓ set via `meta.nix` |

Network bridge for this VM (e.g. `"br-pentest"`, `"br-dev"`).

---

#### `hydrix.microvm.tapId`
| | |
|---|---|
| Type | `str` |
| Default | auto-generated |
| Template | ✓ set via `meta.nix` |

TAP interface name (max 15 chars). Convention: `mv-<bridge-suffix>` (e.g. `mv-pentest`).

---

#### `hydrix.microvm.persistence.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ set per-profile |

Enable persistent home volume. When false, home is ephemeral (reset on restart).
Use `false` for privacy-sensitive VMs (comms, lurking).

---

#### `hydrix.microvm.persistence.homeSize`
| | |
|---|---|
| Type | `int` |
| Default | `10240` |
| Template | ✓ set per-profile (e.g. `51200` for dev = 50GB) |

Home volume size in MiB.

---

#### `hydrix.microvm.persistence.extraVolumes`
| | |
|---|---|
| Type | `listOf submodule` |
| Default | `[]` |
| Template | ✓ used in dev profile for docker volume |

Additional persistent volumes. Fields: `name`, `size` (MiB), `mountPoint`.

---

#### `hydrix.microvm.encryption.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | ✓ commented example in tasks |

Encrypt the home volume with a passphrase (prompted at VM start).

---

#### `hydrix.microvm.staticIp`
| | |
|---|---|
| Type | `nullOr str` |
| Default | `null` |
| Template | — |

Override DHCP with a static IP for this VM. Rarely needed for profile VMs.

---

### VM Shared Store

#### `hydrix.vm.sharedStore.enable`
| | |
|---|---|
| Type | `bool` |
| Default | `false` |
| Template | — (set by framework) |

Mount host `/nix/store` as read-only virtiofs share. Enabled automatically for all microVMs.

---

## Theming Options (`theming/options.nix`)

*To be documented in Pass 2–4 (theming sweep).*

Options in this section cover:
- `hydrix.graphical.*` — display, scaling, UI, lockscreen, bluelight
- `hydrix.i3.enable` / `hydrix.sway.enable` / `hydrix.hyprland.enable`
- `hydrix.graphical.font.*`
- `hydrix.graphical.ui.*`
- `hydrix.graphical.firefox.*`
- `hydrix.graphical.alacritty.*`
- `hydrix.graphical.scaling.*`

See `machines/installer.nix` for the currently documented graphical options.

---

## Notes on Override Precedence

```
lib.mkForce > plain assignment > lib.mkDefault > lib.mkOptionDefault (type default)
```

In practice:
- **Framework modules** use `lib.mkDefault` → users always win with plain assignment
- **`hydrix-config/shared/*.nix`** uses plain assignment → overrides framework defaults
- **`hydrix-config/machines/<serial>.nix`** uses plain assignment → overrides shared defaults
- `lib.mkForce` is only needed for: complete service replacement, security-critical isolation, VM structural constraints
