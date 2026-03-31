#!/usr/bin/env fish
# installer/install-wizard.fish
# Interactive NixOS installation wizard with disko

set -g RED (set_color red)
set -g GREEN (set_color green)
set -g BLUE (set_color blue)
set -g YELLOW (set_color yellow)
set -g BOLD (set_color --bold)
set -g RESET (set_color normal)

function banner
    clear
    echo "$BOLD╔════════════════════════════════════════════════════════════╗$RESET"
    echo "$BOLD║     NixOS Interactive Installer with BTRFS & Disko         ║$RESET"
    echo "$BOLD╚════════════════════════════════════════════════════════════╝$RESET"
    echo ""
end

function error
    echo "$RED✗ ERROR: $argv$RESET" >&2
    exit 1
end

function warn
    echo "$YELLOW⚠ WARNING: $argv$RESET"
end

function info
    echo "$BLUE→ $argv$RESET"
end

function success
    echo "$GREEN✓ $argv$RESET"
end

function prompt_yn
    set -l question $argv[1]
    read -P "$BOLD$question (y/n): $RESET" -n 1 answer
    echo ""
    test "$answer" = "y" -o "$answer" = "Y"
end

function select_from_list
    set -l prompt_text $argv[1]
    set -l options $argv[2..-1]
    
    echo "$BOLD$prompt_text$RESET"
    for i in (seq (count $options))
        echo "  $i) $options[$i]"
    end
    echo ""
    
    while true
        read -P "Select (1-"(count $options)"): " choice
        if test -n "$choice" -a "$choice" -ge 1 -a "$choice" -le (count $options)
            echo $options[$choice]
            return 0
        end
        warn "Invalid selection, try again"
    end
end

# Check if running as root
if test (id -u) -ne 0
    error "This installer must be run as root. Use: sudo fish $argv[0]"
end

banner

# Welcome
echo "This wizard will guide you through installing NixOS with:"
echo "  • BTRFS filesystem with reflink support for VMs"
echo "  • Declarative disk management via disko"
echo "  • Your custom configuration"
echo ""

if not prompt_yn "Continue with installation?"
    info "Installation cancelled"
    exit 0
end

banner

# Step 1: Detect hardware
info "Detecting hardware..."
echo ""

set available_disks (lsblk -d -n -p -o NAME,SIZE,TYPE,MODEL | grep disk)
if test (count $available_disks) -eq 0
    error "No disks detected!"
end

echo "$BOLD Available disks:$RESET"
set disk_list
for line in $available_disks
    set disk_info (echo $line | string split -n " ")
    set disk_path $disk_info[1]
    set disk_size $disk_info[2]
    set disk_model $disk_info[4..-1]
    echo "  • $disk_path ($disk_size) - $disk_model"
    set -a disk_list "$disk_path|$disk_size|$disk_model"
end
echo ""

# Step 2: Installation type
set install_type (select_from_list "Select installation type:" \
    "Full disk (wipe entire disk)" \
    "Dual-boot (manual partitioning required)" \
    "VM-optimized (full disk with VM reflinking)")

banner

# Step 3: Disk selection
set selected_disk_info (select_from_list "Select target disk:" $disk_list)
set selected_disk (echo $selected_disk_info | cut -d'|' -f1)
set disk_size (echo $selected_disk_info | cut -d'|' -f2)

info "Selected disk: $selected_disk ($disk_size)"
echo ""

# Show current partitions if any
if test (lsblk -n $selected_disk | wc -l) -gt 1
    warn "Current partition table on $selected_disk:"
    lsblk $selected_disk
    echo ""
end

# Step 4: Confirm destructive operation
if test "$install_type" != "Dual-boot (manual partitioning required)"
    echo "$RED$BOLD╔════════════════════════════════════════════════════════════╗$RESET"
    echo "$RED$BOLD║                    ⚠️  DANGER ZONE  ⚠️                      ║$RESET"
    echo "$RED$BOLD║  ALL DATA ON $selected_disk WILL BE PERMANENTLY ERASED!  ║$RESET"
    echo "$RED$BOLD╚════════════════════════════════════════════════════════════╝$RESET"
    echo ""
    
    if not prompt_yn "Type 'yes' to confirm data destruction (anything else cancels)"
        info "Installation cancelled - no changes made"
        exit 0
    end
end

banner

# Step 5: Configuration parameters
info "Configure installation parameters..."
echo ""

# Swap size
read -P "$BOLD Swap size in GB (0 for no swap, default: 8): $RESET" swap_size
set swap_size (test -n "$swap_size"; and echo $swap_size; or echo 8)
if test "$swap_size" -gt 0
    success "Swap: {$swap_size}GB"
else
    info "Swap: disabled"
end

# Hostname
read -P "$BOLD Hostname for this system: $RESET" hostname
test -z "$hostname"; and set hostname "nixos"
success "Hostname: $hostname"

# Username
read -P "$BOLD Primary user name: $RESET" username
test -z "$username"; and set username "user"
success "Username: $username"

# Timezone
read -P "$BOLD Timezone (e.g., America/New_York): $RESET" timezone
test -z "$timezone"; and set timezone "UTC"
success "Timezone: $timezone"

# Additional config repo (optional)
if prompt_yn "Do you want to clone a git repository with your NixOS config?"
    read -P "$BOLD Git repository URL: $RESET" git_repo
    if test -n "$git_repo"
        success "Will clone: $git_repo"
    end
else
    set git_repo ""
end

banner

# Step 6: Generate disko configuration
info "Generating disko configuration..."

set disko_config /tmp/disko-install.nix

switch "$install_type"
    case "Full disk (wipe entire disk)"
        set template /etc/installer/templates/single-disk.nix
    case "Dual-boot (manual partitioning required)"
        set template /etc/installer/templates/dual-boot.nix
        warn "Dual-boot requires manual partitioning first!"
        warn "Please partition the disk and note partition numbers"
        read -P "Press Enter when ready..." _
    case "VM-optimized (full disk with VM reflinking)"
        set template /etc/installer/templates/vm-optimized.nix
end

# Copy and customize template
cp $template $disko_config
sed -i "s|device ? \"/dev/sda\"|device ? \"$selected_disk\"|g" $disko_config
sed -i "s|swapSize ? \"8G\"|swapSize ? \"{$swap_size}G\"|g" $disko_config

success "Disko config generated: $disko_config"

# Step 7: Apply disko
info "Applying disk configuration (this may take a minute)..."

if not nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
    --mode disko $disko_config
    error "Disk setup failed!"
end

success "Disk partitioning complete!"

# Step 8: Generate NixOS configuration
info "Generating hardware configuration..."

if not nixos-generate-config --root /mnt
    error "Failed to generate configuration"
end

success "Hardware configuration generated"

# Step 9: Clone git repo if provided
if test -n "$git_repo"
    info "Cloning configuration repository..."
    rm -rf /mnt/etc/nixos/*
    if git clone $git_repo /mnt/etc/nixos
        success "Repository cloned successfully"
    else
        error "Failed to clone repository"
    end
else
    # Create basic configuration
    info "Creating basic configuration..."
    
    cat > /mnt/etc/nixos/configuration.nix << EOF
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    $disko_config
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking
  networking.hostName = "$hostname";
  networking.networkmanager.enable = true;

  # Time zone
  time.timeZone = "$timezone";

  # Localization
  i18n.defaultLocale = "en_US.UTF-8";

  # User account
  users.users.$username = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "libvirtd" ];
    packages = with pkgs; [
      firefox
      fish
    ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    fish
  ];

  # Fish shell
  programs.fish.enable = true;
  users.users.$username.shell = pkgs.fish;

  # Enable QEMU/KVM for VMs
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      ovmf.enable = true;
    };
  };

  # Enable btrfs auto-scrub
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
  };

  system.stateVersion = "25.11";
}
EOF
    
    success "Basic configuration created"
end

# Copy disko config to installation
cp $disko_config /mnt/etc/nixos/disko.nix

banner

# Step 10: Final confirmation and install
info "Configuration summary:"
echo "  • Disk: $selected_disk"
echo "  • Type: $install_type"
echo "  • Swap: {$swap_size}GB"
echo "  • Hostname: $hostname"
echo "  • User: $username"
echo "  • Timezone: $timezone"
if test -n "$git_repo"
    echo "  • Config: $git_repo"
end
echo ""

info "You can review the configuration at: /mnt/etc/nixos/"
echo ""

if prompt_yn "Proceed with NixOS installation?"
    info "Starting installation (this will take several minutes)..."
    
    if nixos-install --no-root-password
        banner
        success "Installation complete!"
        echo ""
        info "Next steps:"
        echo "  1. Set root password: nixos-enter --root /mnt -c 'passwd'"
        echo "  2. Set user password: nixos-enter --root /mnt -c 'passwd $username'"
        echo "  3. Reboot: reboot"
        echo ""
        
        if prompt_yn "Set passwords now?"
            info "Setting root password..."
            nixos-enter --root /mnt -c 'passwd'
            info "Setting $username password..."
            nixos-enter --root /mnt -c "passwd $username"
            success "Passwords set!"
        end
        
        echo ""
        if prompt_yn "Reboot now?"
            reboot
        end
    else
        error "Installation failed!"
    end
else
    info "Installation cancelled"
    info "Unmounting filesystems..."
    umount -R /mnt
end
