#!/usr/bin/env fish
# vm-manager.fish - Helper script for managing VMs with btrfs reflinks

set -g VM_BASE_DIR /var/lib/libvirt/bases
set -g VM_INSTANCE_DIR /var/lib/libvirt/images

function vm_create_base
    set image_name $argv[1]
    
    if test -z "$image_name"
        echo "Usage: vm_create_base <image_name>"
        return 1
    end
    
    set base_path "$VM_BASE_DIR/$image_name"
    
    if test -f $base_path
        echo "Base image already exists: $base_path"
        return 1
    end
    
    echo "Creating base VM image: $base_path"
    echo "Use virt-install or copy an existing image here"
    echo ""
    echo "Example:"
    echo "  virt-install --name base-kali \\"
    echo "    --disk path=$base_path,size=20 \\"
    echo "    --cdrom /path/to/kali.iso ..."
end

function vm_clone
    set base_image $argv[1]
    set new_vm_name $argv[2]
    
    if test -z "$base_image" -o -z "$new_vm_name"
        echo "Usage: vm_clone <base_image> <new_vm_name>"
        echo ""
        echo "Available base images:"
        ls -1 $VM_BASE_DIR 2>/dev/null | sed 's/^/  /'
        return 1
    end
    
    set base_path "$VM_BASE_DIR/$base_image"
    set new_path "$VM_INSTANCE_DIR/$new_vm_name.qcow2"
    
    if not test -f $base_path
        echo "Base image not found: $base_path"
        return 1
    end
    
    if test -f $new_path
        echo "Instance already exists: $new_path"
        return 1
    end
    
    echo "Cloning VM via reflink (instant)..."
    set start_time (date +%s)
    
    sudo cp --reflink=always $base_path $new_path
    
    set end_time (date +%s)
    set duration (math "$end_time - $start_time")
    
    echo "✓ VM cloned in {$duration}s: $new_path"
    echo "  Space used: ~0 bytes (copy-on-write)"
    echo ""
    echo "To use this VM:"
    echo "  1. Edit VM XML to use this disk"
    echo "  2. Or create new VM: virt-install --import --disk $new_path ..."
end

function vm_list
    echo "Base images:"
    ls -lh $VM_BASE_DIR 2>/dev/null | tail -n +2 | awk '{print "  " $9 " (" $5 ")"}'
    echo ""
    echo "VM instances:"
    ls -lh $VM_INSTANCE_DIR 2>/dev/null | tail -n +2 | awk '{print "  " $9 " (" $5 ")"}'
end

function vm_disk_usage
    if not command -v compsize &>/dev/null
        echo "Installing compsize for accurate disk usage..."
        sudo nix-env -iA nixos.compsize
    end
    
    echo "Disk usage for VMs:"
    sudo compsize $VM_BASE_DIR $VM_INSTANCE_DIR
    echo ""
    echo "Btrfs filesystem stats:"
    sudo btrfs filesystem df /
end

function vm_snapshot
    set vm_name $argv[1]
    set snapshot_name $argv[2]
    
    if test -z "$vm_name" -o -z "$snapshot_name"
        echo "Usage: vm_snapshot <vm_name> <snapshot_name>"
        return 1
    end
    
    set vm_path "$VM_INSTANCE_DIR/$vm_name.qcow2"
    
    if not test -f $vm_path
        echo "VM not found: $vm_path"
        return 1
    end
    
    # Create btrfs snapshot
    set snapshot_dir "/.snapshots/vms"
    sudo mkdir -p $snapshot_dir
    
    echo "Creating snapshot: $snapshot_name"
    sudo btrfs subvolume snapshot $VM_INSTANCE_DIR "$snapshot_dir/$snapshot_name"
    
    echo "✓ Snapshot created: $snapshot_dir/$snapshot_name"
end

function vm_help
    echo "VM Manager - Btrfs Reflink Helper"
    echo ""
    echo "Commands:"
    echo "  vm_create_base <name>              - Create a new base image"
    echo "  vm_clone <base> <new_name>         - Clone VM instantly via reflink"
    echo "  vm_list                            - List all VMs and bases"
    echo "  vm_disk_usage                      - Show actual disk usage"
    echo "  vm_snapshot <vm> <snapshot_name>   - Create btrfs snapshot"
    echo ""
    echo "Example workflow:"
    echo "  1. Create base: vm_create_base kali-base.qcow2"
    echo "  2. Clone VMs: vm_clone kali-base.qcow2 kali-test-01"
    echo "  3. Check usage: vm_disk_usage"
end

# Auto-run help if no args
if test (count $argv) -eq 0
    vm_help
end
