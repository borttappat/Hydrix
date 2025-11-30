{ config, pkgs, lib, ... }:

let
  inherit (pkgs.lib) mkForce;
in
{
  # Import router-generated configuration (VFIO + specializations)
  # This contains router VM setup, maximalism mode, etc.
  imports = [
    ../../generated/modules/zephyrus-consolidated.nix
  ];

  # Override hostname for this machine
  networking.hostName = mkForce "zeph";

  # ========== ASUS-SPECIFIC PACKAGES ==========
  environment.systemPackages = with pkgs; [
    # Battery management
    (writeShellScriptBin "set-battery-limit" ''
      #!/bin/sh
      echo "Setting battery charge limit to 80%..."
      ${pkgs.asusctl}/bin/asusctl -c 80
      echo "Battery charge limit set."
    '')

    # Power management tools
    powertop
    acpi
    acpid
    s-tui
    intel-gpu-tools

    # CUDA and NVIDIA Tools
    cudatoolkit
    linuxPackages.nvidia_x11
    clinfo
    nvtopPackages.full
    glmark2
    vulkan-tools
    vulkan-validation-layers
    xorg.xdriinfo
    mesa-demos

    # Development Tools
    gcc
    gdb
    cmake
    gnumake
    python3
    python3Packages.numpy
    python3Packages.pytorch

    # NVIDIA offload wrapper
    (writeShellScriptBin "nvidia-offload" ''
      export __NV_PRIME_RENDER_OFFLOAD=1
      export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
      export __GLX_VENDOR_LIBRARY_NAME=nvidia
      export __VK_LAYER_NV_optimus=NVIDIA_only
      exec "$@"
    '')

    # Performance mode script
    (writeShellScriptBin "performance-mode" ''
      #!/bin/sh
      echo "Switching to performance mode..."
      sudo cpupower frequency-set -g performance
      echo "1" | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
      echo "CPU set to performance mode"
      echo "Starting services..."
      sudo systemctl start docker.service
      sudo systemctl start libvirtd.service
      echo "Done! System optimized for performance."
    '')

    # Bluetooth
    bluez
    blueman

    # ASUS control
    asusctl

    # VM management (adding to existing packages)
    virt-manager
    virt-viewer
    pciutils
    libosinfo
    guestfs-tools
    OVMF
    swtpm
    spice-gtk
    win-virtio
    looking-glass-client
    qemu
    libvirt
    bridge-utils
    iptables
    tcpdump
    nftables
    os-prober
    obs-studio
    vim
  ];

  # ========== ASUS SERVICES ==========
  services.asusd.enable = true;

  # Bluetooth
  services.blueman.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        FastConnectable = false;
        JustWorksRepairing = "always";
        Privacy = "device";
        Experimental = false;
      };
    };
  };

  # ========== POWER MANAGEMENT ==========
  powerManagement = {
    enable = true;
    powertop.enable = true;
    cpuFreqGovernor = "powersave";
  };

  # TLP for advanced power management
  services.tlp = {
    enable = true;
    settings = {
      # CPU settings
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 100;
      CPU_MIN_PERF_ON_BAT = 0;
      CPU_MAX_PERF_ON_BAT = 60;

      # Platform profile
      PLATFORM_PROFILE_ON_AC = "performance";
      PLATFORM_PROFILE_ON_BAT = "low-power";

      # PCIe power management
      PCIE_ASPM_ON_AC = "default";
      PCIE_ASPM_ON_BAT = "powersupersave";

      # Kernel NMI watchdog
      NMI_WATCHDOG = 0;

      # Runtime Power Management
      RUNTIME_PM_ON_AC = "on";
      RUNTIME_PM_ON_BAT = "auto";

      # Audio power management
      SOUND_POWER_SAVE_ON_AC = 0;
      SOUND_POWER_SAVE_ON_BAT = 1;
      SOUND_POWER_SAVE_CONTROLLER = "Y";

      # WiFi power saving
      WIFI_PWR_ON_AC = "off";
      WIFI_PWR_ON_BAT = "on";

      # USB autosuspend
      USB_AUTOSUSPEND = 1;

      # Battery care settings
      START_CHARGE_THRESH_BAT0 = 40;
      STOP_CHARGE_THRESH_BAT0 = 80;
    };
  };

  # Auto-cpufreq
  services.auto-cpufreq = {
    enable = true;
    settings = {
      battery = {
        governor = "powersave";
        turbo = "never";
      };
      charger = {
        governor = "performance";
        turbo = "auto";
      };
    };
  };

  # Thermald
  services.thermald.enable = true;

  # ========== GRAPHICS CONFIGURATION ==========
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
      nvidia-vaapi-driver
    ];
  };

  # ========== BOOT AND KERNEL OVERRIDES ==========
  # Override kernel version from configuration.nix
  boot.kernelPackages = mkForce pkgs.linuxPackages_6_1;

  boot.kernelParams = [
    "quiet"
    "splash"

    # Power management
    "intel_pstate=active"
    "intel_idle.max_cstate=3"
    "pcie_aspm=force"
    "mem_sleep_default=deep"
    "nvme.noacpi=1"
    "i915.enable_psr=1"

    # Basic parameters
    "ipv6.disable=1"
    "nvidia-drm.modeset=1"
    "module_blacklist=nouveau"
    "acpi_osi=Linux"
    "acpi_rev_override=1"
  ];

  boot.kernelModules = [
    "kvm"
    "kvm_intel"
    "nvidia"
    "nvidia_modeset"
    "nvidia_uvm"
    "nvidia_drm"
  ];

  boot.extraModulePackages = [ config.boot.kernelPackages.nvidia_x11 ];

  # Kernel sysctl
  boot.kernel.sysctl = {
    "vm.laptop_mode" = mkForce 5;
    "vm.dirty_writeback_centisecs" = mkForce 1500;
    "vm.swappiness" = mkForce 10;
  };

  # Runtime PM for PCI devices
  services.udev.extraRules = ''
    # Enable runtime power management for all PCI devices
    ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="auto"

    # Enable ASPM for PCIe devices
    ACTION=="add", SUBSYSTEM=="pci", ATTR{power/aspm_policy}="powersupersave"

    # Autosuspend USB devices
    ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="auto", ATTR{power/autosuspend}="1"
  '';

  # ========== NVIDIA CONFIGURATION ==========
  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
    powerManagement = {
      enable = true;
      finegrained = true;
    };

    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };

      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";

      sync.enable = false;
    };
  };

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia-container-toolkit.enable = true;

  # CUDA environment
  environment = {
    variables = {
      CUDA_PATH = "${pkgs.cudatoolkit}";
      EXTRA_LDFLAGS = "-L/lib -L${pkgs.linuxPackages.nvidia_x11}/lib";
      EXTRA_CCFLAGS = "-I/usr/include";
    };

    extraInit = ''
      export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:${pkgs.linuxPackages.nvidia_x11}/lib:${pkgs.cudatoolkit}/lib
    '';
  };

  # ========== POWER COMMANDS ==========
  powerManagement.powerDownCommands = ''
    systemctl stop docker.service || true
    systemctl stop libvirtd.service || true
  '';

  powerManagement.powerUpCommands = ''
    systemctl start docker.service || true
    systemctl start libvirtd.service || true
  '';

  # ========== NETWORKING OVERRIDES ==========
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 5900 5901 5902 ];
  };

  # ========== BOOTLOADER OVERRIDE ==========
  # Override systemd-boot from configuration.nix to use GRUB
  boot.loader = {
    systemd-boot.enable = mkForce false;
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;

      extraConfig = ''
        function os_prober {
          ( /usr/bin/os-prober || true ) 2>/dev/null
        }
      '';
    };
    efi.canTouchEfiVariables = true;
  };

  # Enable dconf for virt-manager
  programs.dconf.enable = true;
}
