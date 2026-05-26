# Machine Configuration
# Serial: @SERIAL@
# Generated: @GEN_DATE@
#
# This file configures your machine. Edit it to customise Hydrix for this machine.
# All hydrix.* options are shown below with defaults and examples.
# Rebuild to apply changes: rebuild

{ config, lib, pkgs, hydrix, ... }:

{
  # =========================================================================
  # SPECIALISATIONS (Boot Modes)
  # =========================================================================
  # The Hydrix framework defines the infrastructure for each mode:
  #   - Base config = LOCKDOWN (no host internet, builder VM for builds)
  #   - Administrative = adds gateway, libvirtd, full packages
  #   - Fallback = emergency direct WiFi (requires reboot)
  #
  # The files below are for YOUR extra packages/settings per mode.
  # You can safely leave them empty or add packages as needed.

  imports = [
    @HARDWARE_IMPORT@
    ../specialisations/lockdown.nix
  ];

  # Administrative mode - your extra packages
  specialisation.administrative.configuration = {
    imports = [ ../specialisations/administrative.nix ];
  };

  # Fallback mode - your extra packages
  specialisation.fallback.configuration = {
    imports = [ ../specialisations/fallback.nix ];
  };

  # Custom modes: uncomment to add your own specialisation
  # specialisation.leisure.configuration = {
  #   imports = [ ../specialisations/leisure.nix ];
  # };

  # =========================================================================
  # USER CREDENTIALS (Optional)
  # =========================================================================
  # By default, your existing password is preserved from /etc/shadow.
  # Only set this if you want to manage password declaratively:
  #
  # hydrix.user.hashedPassword = "$6$...";  # Generate with: mkpasswd -m sha-512

  # Auto-login on console (default: false on host, true in VMs)
  # hydrix.user.autologin = true;

  # SSH public keys for authorized_keys (optional)
  # hydrix.user.sshPublicKeys = [
  #   "ssh-ed25519 AAAA... user@host"
  # ];

  # Extra groups beyond defaults (wheel, audio, video, etc.)
  # hydrix.user.extraGroups = [ "libvirtd" "kvm" ];

  # Display name shown in finger, etc. (defaults to username)
  # hydrix.user.description = "Jane Doe";

  # =========================================================================
  # HYDRIX CONFIGURATION
  # =========================================================================
  hydrix = {
    # ─────────────────────────────────────────────────────────────────────
    # IDENTITY
    # ─────────────────────────────────────────────────────────────────────
    username = "@USERNAME@";
    hostname = "hydrix";         # Visual hostname (config file identified by serial)
    colorscheme = "@COLORSCHEME@";
    graphical.wallpaper = "${hydrix}/wallpapers/WindowRain.png";

    # Window manager selection — Hyprland is the default Wayland compositor.
    # Enable i3 or sway alongside it if needed (each starts from a separate TTY).
    hyprland.enable = true;   # Wayland/Hyprland stack — start with: hyprland-session
    # sway.enable = true;     # Wayland/Sway stack — start with: sway-session
    # i3.enable = true;       # X11/i3/polybar/rofi/picom stack — start with: startx

    # vmThemeSync.focusDaemon.mode = "dynamic";  # "static" or "dynamic" focus border colors

    # ─────────────────────────────────────────────────────────────────────
    # PATHS
    # ─────────────────────────────────────────────────────────────────────
    # Baked into scripts at build time. Only override if your repos are not
    # in the standard locations (~/hydrix-config, ~/Hydrix).
    # paths.configDir = "/home/@USERNAME@/hydrix-config";  # DEFAULT: ~/hydrix-config
    # paths.hydrixDir = "/home/@USERNAME@/Hydrix";         # DEFAULT: ~/Hydrix

    # ─────────────────────────────────────────────────────────────────────
    # DEFAULT APPLICATIONS
    # ─────────────────────────────────────────────────────────────────────
    # These options are wired across the graphical environment (sway, i3, scripts).
    # Override here to change which programs the WM keybinds launch.
    #
    # terminal = "alacritty";   # DEFAULT: alacritty (used by Super+Return in sway/i3)
    # shell    = "fish";        # DEFAULT: fish  (options: fish, bash, zsh)
    # editor   = "vim";         # DEFAULT: vim   (sets EDITOR/VISUAL env vars)

    # ─────────────────────────────────────────────────────────────────────
    # DISKO - Disk Partitioning (only for fresh installs)
    # ─────────────────────────────────────────────────────────────────────
    disko = {
      enable = false;  # Set true only when partitioning a fresh disk
      device = "@DISKO_DEVICE@";  # Run: lsblk -d to find your disk
      swapSize = "16G";           # Match your RAM, or half for hibernation

      # Layout options:
      # ┌─────────────────────┬──────────────────────────────────────────────┐
      # │ full-disk-plain     │ BTRFS, no encryption (fastest, simplest)     │
      # │ full-disk-luks      │ BTRFS + LUKS full-disk encryption            │
      # │ dual-boot-luks      │ Preserve existing EFI + LUKS for NixOS part  │
      # │ dual-boot-plain     │ Preserve existing EFI, no encryption         │
      # └─────────────────────┴──────────────────────────────────────────────┘
      layout = "full-disk-plain";

      # Dual-boot only: set by the installer, do not edit manually.
      # nixosPartition = "";
      # efiPartition = "";
    };

    # ─────────────────────────────────────────────────────────────────────
    # ROUTER
    # ─────────────────────────────────────────────────────────────────────
    # WiFi credentials are in shared/wifi.nix (shared across all machines).
    router = {
      type = "@ROUTER_TYPE@";  # "microvm" (recommended), "libvirt", or "none"
      autostart = true;        # Start router VM automatically

      # ─── Mullvad VPN (optional) ────────────────────────────────────────
      # 1. mullvad.net → Account → WireGuard config → select server → download .conf
      # 2. Place downloaded files in ~/hydrix-config/vpn/
      # 3. Copy vpn/mullvad.nix.example → vpn/mullvad.nix, map bridges to files
      # 4. Uncomment the line below and rebuild the router
      #
      # vpn.mullvad = import ../vpn/mullvad.nix;

      # ─── Router VM user (microvm router) ─────────────────────────────
      # username       = "@USERNAME@";  # DEFAULT: inherits hydrix.username
      # hashedPassword = null;          # DEFAULT: null (inherits host password if set)

      # ─── Multi-network WiFi (alternative to shared/wifi.nix) ──────────
      # wifi.networks = [
      #   { ssid = "HomeNetwork"; password = "secret"; priority = 100; }
      #   { ssid = "WorkNetwork"; password = "secret2"; priority = 50; }
      # ];

      # ─── libvirt router (if type = "libvirt") ──────────────────────────
      # router.libvirt.vmName  = "router";        # DEFAULT: "router"
      # router.libvirt.wan.mode = "auto";         # DEFAULT: "auto"
      #   # Options: "auto", "pci-passthrough", "macvtap", "none"
    };

    # ─────────────────────────────────────────────────────────────────────
    # HARDWARE
    # ─────────────────────────────────────────────────────────────────────
    hardware = {
      platform = "@PLATFORM@";  # "intel", "amd", or "generic"
      isAsus = @IS_ASUS@;       # true → asus-linux (asusctl, supergfxctl, ROG features)

      vfio = {
        enable = true;
        pciIds = [ "@WIFI_PCI_ID@" ];           # Your WiFi card's vendor:device ID
        wifiPciAddress = "@WIFI_PCI_ADDRESS@";  # Your WiFi card's PCI address
      };

      # bluetooth.enable = true;     # DEFAULT: true - Bluetooth + Blueman
      # i2c.enable = true;           # DEFAULT: true - DDC/CI monitor control
      # touchpad.enable = true;      # DEFAULT: true - libinput touchpad

      grub.gfxmodeEfi = "1920x1200";  # Your display resolution for GRUB
    };

    # ─────────────────────────────────────────────────────────────────────
    # POWER
    # ─────────────────────────────────────────────────────────────────────
    power = {
      defaultProfile = "balanced";  # "powersave", "balanced", "performance"
      # chargeLimit = 60;           # Battery charge limit (20-100, preserves battery)
      # autoCpuFreq = true;         # DEFAULT: true - auto-cpufreq service
    };

    # ─────────────────────────────────────────────────────────────────────
    # SERVICES
    # ─────────────────────────────────────────────────────────────────────
    # services = {
    #   tailscale.enable = true;   # DEFAULT: true  - Tailscale VPN mesh
    #   ssh.enable = true;         # DEFAULT: true  - OpenSSH daemon
    # };

    # ─────────────────────────────────────────────────────────────────────
    # SECRETS (optional - for GitHub SSH keys, etc.)
    # ─────────────────────────────────────────────────────────────────────
    # Setup workflow:
    #   1. Rebuild once (generates /etc/ssh/ssh_host_ed25519_key)
    #   2. Run: sops-age-pubkey          (prints your age public key)
    #   3. Add key to secrets/.sops.yaml in your hydrix-config
    #   4. Fill secrets/github.yaml, encrypt: cd secrets && sops -e -i github.yaml
    #   5. Set enable = true + github.enable = true, then rebuild
    secrets = {
      enable = false;
      github.enable = false;
      # githubSecretsFile = ../secrets/github.yaml;
    };

    # ─────────────────────────────────────────────────────────────────────
    # MICROVM HOST
    # ─────────────────────────────────────────────────────────────────────
    microvmHost = {
      enable = true;
      vms = {
        "microvm-router"   = { enable = true; autostart = true; };
        "microvm-browsing" = { enable = true; };
        "microvm-pentest"  = { enable = true; };
        "microvm-dev"      = { enable = true; secrets = [ "github" ]; };
        "microvm-comms"    = { enable = true; };
        "microvm-lurking"  = { enable = true; };
        "microvm-builder"  = { enable = true; };
        "microvm-gitsync"  = { enable = true; secrets = [ "github" ]; };
        "microvm-files"       = { enable = true; };
        "microvm-usb-sandbox" = { enable = true; };
        "microvm-hostsync"    = { enable = true; };
      };
      # autostart = true  starts VM at boot (default: false — start manually)
      # secrets = [ "github" ]  provisions SSH key from secrets/github.yaml into the VM
    };

    # ─────────────────────────────────────────────────────────────────────
    # BUILDER (lockdown mode nix builds via microvm-builder)
    # ─────────────────────────────────────────────────────────────────────
    builder.enable = true;

    # ─────────────────────────────────────────────────────────────────────
    # GIT-SYNC (lockdown mode git push/pull via microvm-gitsync)
    # ─────────────────────────────────────────────────────────────────────
    gitsync.enable = true;

    # ─────────────────────────────────────────────────────────────────────
    # GRAPHICAL
    # ─────────────────────────────────────────────────────────────────────
    # Shared UI preferences live in shared/graphical.nix (imported for all machines).
    # Uncomment anything here to override the shared value for this machine only.
    graphical = {
      enable = true;

      # polarity = "dark";  # DEFAULT: "dark"

      # colorscheme = "nord";  # DEFAULT: inherits hydrix.colorscheme

      # ─── Font ────────────────────────────────────────────────────────
      # font.family = "Iosevka";
      # font.size   = 10;
      # font.overrides = { alacritty = 10.5; };
      # font.familyOverrides = { alacritty = "Tamzen"; };

      # ─── UI layout ───────────────────────────────────────────────────
      # ui.gaps        = 15;          # DEFAULT: 15 - i3 inner gaps
      # ui.barHeight   = 23;          # DEFAULT: 23
      # ui.border      = 2;           # DEFAULT: 2  - window border width
      # ui.floatingBar = true;        # DEFAULT: true
      # ui.polybarStyle = "modular";  # DEFAULT: "modular" - unibar, modular, pills
      # ui.cornerRadius = 2;          # DEFAULT: 2  - picom corner radius

      # ─── Workspace labels ────────────────────────────────────────────
      # ui.workspaceLabels = { "1" = "web"; "2" = "code"; "3" = "term"; };

      # ─── Opacity / transparency ──────────────────────────────────────
      # ui.opacity.overlay  = 0.85;   # DEFAULT: 0.85
      # ui.opacity.active   = 1.0;    # DEFAULT: 1.0
      # ui.opacity.inactive = 1.0;    # DEFAULT: 1.0

      # ─── Hyprland display scaling ────────────────────────────────────
      # scaling.hyprInternalScale  = 1.5;       # UI scale (1.5→1280×800, 1.25→1536×960 logical)
      # scaling.hyprInternalOutput = "eDP-1";   # DEFAULT: "eDP-1" (run: hyprctl monitors)

      # ─── Hyprland keyboard remapping ─────────────────────────────────
      # Custom xkb keymap — takes precedence over layout/variant from shared/common.nix.
      # Use for key remapping (e.g. § → ~, CapsLock → Ctrl):
      # keyboard.xkbFile = pkgs.writeText "my-keymap" ''
      #   xkb_keymap {
      #     xkb_keycodes { include "evdev+aliases(qwerty)" };
      #     xkb_types    { include "complete" };
      #     xkb_compat   { include "complete" };
      #     xkb_symbols  {
      #       include "pc+se+inet(evdev)"
      #       key <CAPS> { [ Control_L, Control_L ] };
      #       key <TLDE> { [ asciitilde, grave ] };
      #     };
      #     xkb_geometry { include "pc(pc105)" };
      #   };
      # '';

      # ─── X11/i3 settings ─────────────────────────────────────────────
      # scaling.internalResolution = "1920x1200";  # i3/xrandr: standalone display mode
      # ui.polybarStyle = "modular";               # "unibar", "modular", "pills"
      # keyboard.xmodmap = ''
      #   clear lock
      #   clear control
      #   keycode 66 = Control_L
      #   add control = Control_L Control_R
      # '';

      # ─── Sway display scaling ─────────────────────────────────────────
      # scaling.swayInternalScale  = 1.25;       # UI scale (1.25→1536×960, 1.5→1280×800 logical)
      # scaling.swayInternalMode   = "1280x800"; # OR: change actual hardware resolution
      # scaling.swayInternalOutput = "eDP-1";    # DEFAULT: "eDP-1" (run: swaymsg -t get_outputs)

      # ─── Lockscreen ──────────────────────────────────────────────────
      # lockscreen.idleTimeout = 600;   # DEFAULT: 600 seconds
      # lockscreen.text      = "Locked";
      # lockscreen.wrongText = "Wrong password";

      # ─── Blue light filter (blugon) ──────────────────────────────────
      # bluelight.enable      = true;   # DEFAULT: true
      # bluelight.defaultTemp = 4500;   # DEFAULT: 4500K

      # ─── Startup splash screen ───────────────────────────────────────
      # splash.enable = false;         # DEFAULT: false
    };

    # ─────────────────────────────────────────────────────────────────────
    # NETWORKING (advanced - defaults work for most setups)
    # ─────────────────────────────────────────────────────────────────────
    # networking = {
    #   hostIp   = "192.168.100.1";
    #   routerIp = "192.168.100.253";
    #   subnets  = {
    #     mgmt    = "192.168.100";
    #     pentest = "192.168.101";
    #     comms   = "192.168.102";
    #     browse  = "192.168.103";
    #     dev     = "192.168.104";
    #     shared  = "192.168.105";
    #     builder = "192.168.106";
    #     lurking = "192.168.107";
    #   };
    # };

    # ─────────────────────────────────────────────────────────────────────
    # FILES VM
    # ─────────────────────────────────────────────────────────────────────
    # microvmFiles.enable = true;
    # microvmFiles.accessFrom = [ "pentest" "dev" "browsing" ];
  };

  # Pre-create ~/vm-inbox so virtiofsd for microvm-hostsync doesn't crash on first boot
  systemd.tmpfiles.rules = let u = config.hydrix.username; in [
    "d /home/${u}/vm-inbox 0755 ${u} users -"
  ];

  # ─────────────────────────────────────────────────────────────────────
  # LOCALE — native NixOS options (set per machine in shared/common.nix or here)
  # ─────────────────────────────────────────────────────────────────────
  # time.timeZone = "@TIMEZONE@";
  # i18n.defaultLocale = "@LANGUAGE@";
  # console.keyMap = "@CONSOLE_KEYMAP@";
  # services.xserver.xkb.layout = "@XKB_LAYOUT@";
  # services.xserver.xkb.variant = "@XKB_VARIANT@";
}
