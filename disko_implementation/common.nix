# hosts/common.nix - Shared configuration across all hosts
{ config, pkgs, ... }:

{
  # Nix settings
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # Boot settings
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    # Support for most filesystems
    supportedFilesystems = [ "btrfs" "ntfs" "exfat" ];
    
    # Kernel parameters for performance
    kernelParams = [ 
      "quiet" 
      "splash"
      # For SSD/NVMe
      "nvme_core.default_ps_max_latency_us=0"
    ];

    # For dual-boot setups
    loader.grub = {
      enable = false;  # Using systemd-boot by default
      # Uncomment for dual-boot:
      # enable = true;
      # device = "nodev";
      # efiSupport = true;
      # useOSProber = true;
    };
    
    loader.systemd-boot = {
      enable = true;
      configurationLimit = 10;  # Keep last 10 generations
    };
    
    loader.efi.canTouchEfiVariables = true;
  };

  # Networking
  networking = {
    networkmanager.enable = true;
    firewall.enable = true;
  };

  # Localization
  time.timeZone = "UTC";  # Override per-host
  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # Sound
  sound.enable = true;
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # X11 and i3
  services.xserver = {
    enable = true;
    
    displayManager = {
      lightdm.enable = true;
      defaultSession = "none+i3";
    };
    
    windowManager.i3 = {
      enable = true;
      package = pkgs.i3-gaps;
      extraPackages = with pkgs; [
        dmenu
        i3status
        i3lock
        i3blocks
      ];
    };
    
    xkb.layout = "us";
  };

  # Fish shell globally
  programs.fish.enable = true;

  # Essential system packages
  environment.systemPackages = with pkgs; [
    # Editors
    vim
    neovim
    
    # Terminal utilities
    alacritty
    fish
    tmux
    
    # System monitoring
    htop
    btop
    iotop
    
    # Network tools
    wget
    curl
    rsync
    nmap
    
    # Development
    git
    gh
    
    # File management
    ranger
    fzf
    ripgrep
    fd
    tree
    
    # Btrfs tools
    btrfs-progs
    compsize
    
    # Virtualization
    virt-manager
    qemu_kvm
    
    # Misc
    unzip
    zip
    p7zip
  ];

  # Virtualization support
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = false;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
  };

  # Docker (optional)
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
  };

  # Btrfs auto-scrub
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/" ];
  };

  # Auto-upgrade system
  system.autoUpgrade = {
    enable = false;  # Enable if you want automatic updates
    allowReboot = false;
  };

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Sudo without password for wheel group
  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "24.11";
}
