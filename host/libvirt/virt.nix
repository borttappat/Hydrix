# Virtualization configuration (for hosts, not VMs)
{ config, pkgs, lib, ... }:
let
  consoleCfg = config.hydrix.libvirt.console;

  # hydrix.libvirt.console.chromeless: VM windows without decoration, menu bar or toolbar
  # until menuKey is tapped (virt-manager-chromeless.patch, Python only).
  virtManager =
    if consoleCfg.chromeless
    then
      pkgs.virt-manager.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./virt-manager-chromeless.patch];
        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace virtManager/vmwindow.py \
              --replace-fail '@menuKey@' ${lib.escapeShellArg consoleCfg.menuKey}
          '';
      })
    else pkgs.virt-manager;

  # The virtio-win ISO itself (the package unpacks it; its src is the ISO). Windows guests
  # install the virtio drivers and the SPICE guest tools (QXL driver, SPICE agent) from it.
  virtioWinIso = pkgs.virtio-win.src;
  # Attached through a link outside /nix/store: virt-install looks every disk path up in a
  # libvirt storage pool for its directory, and a pool over /nix/store has too many entries
  # (and would be left behind). relabel=no: libvirt must not chown the read-only store file;
  # it is world-readable already.
  virtioWinLink = "/var/lib/hydrix/libvirt/virtio-win.iso";
  virtioWinDisk = "path=${virtioWinLink},device=cdrom,bus=sata,readonly=on,source.seclabel.model=dac,source.seclabel.relabel=no";

  # deploy-windows: a new Windows VM with the Hydrix display and USB defaults. The SPICE
  # guest tools come from the attached virtio-win CD after setup; then the guest resolution
  # follows the window.
  deployWindowsScript = pkgs.writeShellScriptBin "deploy-windows" ''
    set -euo pipefail
    usage() {
      cat <<EOF
    Usage: deploy-windows --name <name> --iso <windows.iso> [options]

      --memory <MB>     RAM (default 8192)
      --vcpus <N>       vCPUs (default 4)
      --disk <GB>       disk size (default 80)
      --bridge <br>     network bridge (default: hydrix.libvirt.defaultBridge, else the
                        libvirt "default" network)
      --unattend <iso>  extra CD with autounattend.xml in its root; Windows Setup finds it
                        on its own and runs unattended
      --no-console      do not open the console window (it opens by default, in time for
                        the "Press any key to boot from CD" prompt)

    UEFI, TPM 2.0 and SATA disk (no driver needed during setup), e1000e NIC, QXL with a
    64 MB framebuffer, no SPICE USB redirection (use: usb attach), and the virtio-win CD.
    After Windows setup, run virtio-win-guest-tools.exe from that CD and reboot: the
    display then follows the window size.
    EOF
    }
    NAME="" ISO="" UNATTEND="" CONSOLE=1 MEM=8192 CPUS=4 DISK=80 BRIDGE=${lib.escapeShellArg (toString config.hydrix.libvirt.defaultBridge)}
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) NAME=$2; shift 2 ;;
        --iso) ISO=$2; shift 2 ;;
        --unattend) UNATTEND=$2; shift 2 ;;
        --no-console) CONSOLE=0; shift ;;
        --memory) MEM=$2; shift 2 ;;
        --vcpus) CPUS=$2; shift 2 ;;
        --disk) DISK=$2; shift 2 ;;
        --bridge) BRIDGE=$2; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "deploy-windows: unknown argument $1" >&2; usage >&2; exit 1 ;;
      esac
    done
    [ -n "$NAME" ] && [ -n "$ISO" ] || { usage >&2; exit 1; }
    [ -f "$ISO" ] || { echo "deploy-windows: no such ISO: $ISO" >&2; exit 1; }
    extra=()
    if [ -n "$UNATTEND" ]; then
      [ -f "$UNATTEND" ] || { echo "deploy-windows: no such ISO: $UNATTEND" >&2; exit 1; }
      extra=(--disk "path=$(readlink -f "$UNATTEND"),device=cdrom,bus=sata,readonly=on")
    fi
    if [ -n "$BRIDGE" ]; then net="bridge=$BRIDGE,model=e1000e"; else net="network=default,model=e1000e"; fi
    virt-install --connect qemu:///system \
      --name "$NAME" --memory "$MEM" --vcpus "$CPUS" \
      --os-variant win11 --boot uefi \
      --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
      --disk "size=$DISK,format=qcow2,bus=sata" \
      --cdrom "$(readlink -f "$ISO")" \
      --disk "${virtioWinDisk}" \
      "''${extra[@]}" \
      --network "$net" \
      --graphics spice,listen=none \
      --video model.type=qxl,model.vgamem=65536 \
      --channel spicevmc \
      --redirdev none \
      --noautoconsole
    echo
    # The VM boots as soon as it exists: open its console right away so the firmware's
    # "Press any key to boot from CD" prompt is still on screen.
    if [ "$CONSOLE" = 1 ] && [ -n "''${WAYLAND_DISPLAY:-''${DISPLAY:-}}" ]; then
      setsid virt-manager --connect qemu:///system --show-domain-console "$NAME" >/dev/null 2>&1 &
      echo "Created $NAME; its console is opening. Press a key there when it asks to boot from CD."
    else
      echo "Created $NAME. Open it: virt-manager --connect qemu:///system --show-domain-console $NAME"
    fi
    echo "After Windows setup: run virtio-win-guest-tools.exe from the virtio-win CD, then reboot."
  '';

  # libvirt-tune <vm>: give an existing VM (e.g. one made in the virt-manager wizard) the same
  # defaults: 64 MB QXL framebuffer, no SPICE USB redirection, and the virtio-win CD for a
  # Windows guest that has none. Shows the changes and asks first; the VM must be shut off.
  libvirtTuneScript = pkgs.writeShellScriptBin "libvirt-tune" ''
    set -euo pipefail
    C=qemu:///system
    vm=''${1:-}
    [ -n "$vm" ] || { echo "usage: libvirt-tune <vm> [-y]" >&2; exit 1; }
    state=$(virsh --connect $C domstate "$vm" 2>/dev/null) || { echo "libvirt-tune: no domain $vm" >&2; exit 1; }
    [ "$state" = "shut off" ] || { echo "libvirt-tune: shut $vm down first (it is $state)" >&2; exit 1; }
    xml=$(virsh --connect $C dumpxml --inactive "$vm")
    todo=()
    if grep -q "<model type='qxl'" <<< "$xml" && ! grep -q "vgamem='65536'" <<< "$xml"; then
      todo+=("video: QXL framebuffer to 64 MB (vgamem 65536)")
    fi
    if grep -q "<redirdev " <<< "$xml"; then
      todo+=("redirdev: remove SPICE USB redirection (USB goes in through: usb attach)")
    fi
    windows=0
    grep -q 'microsoft.com/win' <<< "$xml" && windows=1
    if [ "$windows" = 1 ] && ! grep -q 'virtio-win' <<< "$xml"; then
      todo+=("cdrom: attach the virtio-win CD (guest tools: QXL driver, SPICE agent)")
    fi
    if [ ''${#todo[@]} -eq 0 ]; then echo "$vm already has the Hydrix defaults."; exit 0; fi
    echo "Changes for $vm:"
    printf '  - %s\n' "''${todo[@]}"
    if [ "''${2:-}" != -y ]; then
      read -rp "Apply? [y/N] " a
      case "$a" in y | Y | yes) ;; *) echo "Cancelled."; exit 1 ;; esac
    fi
    for t in "''${todo[@]}"; do
      case "$t" in
        video:*) virt-xml --connect $C "$vm" --edit --video model.vgamem=65536 >/dev/null ;;
        redirdev:*) virt-xml --connect $C "$vm" --remove-device --redirdev all >/dev/null ;;
        cdrom:*) virt-xml --connect $C "$vm" --add-device --disk "${virtioWinDisk}" >/dev/null ;;
      esac
    done
    echo "Done. In a Windows guest, run virtio-win-guest-tools.exe from the virtio-win CD once, then reboot."
  '';

  buildBaseScript = pkgs.writeShellScriptBin "build-base" ''
    # Build base images for VM deployment
    #
    # Base images contain the COMPLETE system pre-built.
    # Deploying from base images is instant (~5 seconds).
    #
    # Usage:
    #   build-base --type browsing
    #   build-base --type pentest --type comms  # Multiple
    #   build-base --all                        # All types
    #
    set -uo pipefail

    readonly PROJECT_DIR="''${HYDRIX_FLAKE_DIR:-$HOME/hydrix-config}"
    readonly BASE_IMAGE_DIR="/var/lib/libvirt/base-images"

    log()     { echo "[$(date +%H:%M:%S)] $*"; }
    error()   { echo "[ERROR] $*" >&2; exit 1; }
    success() { echo "[SUCCESS] $*"; }

    VALID_TYPES=("pentest" "browsing" "comms" "dev" "lurking" "transfer")
    BUILD_TYPES=()
    BUILD_ALL=false

    print_usage() {
        cat <<EOF
    Usage: $(basename "$0") [options]

    Build pre-configured base images for instant VM deployment.

    Options:
      --type <type>    VM type to build: pentest, browsing, comms, dev
                       Can be specified multiple times
      --all            Build all VM types
      -h, --help       Show this help

    Examples:
      $(basename "$0") --type browsing
      $(basename "$0") --type pentest --type dev
      $(basename "$0") --all
    EOF
        exit 0
    }

    parse_args() {
        [[ $# -eq 0 ]] && print_usage
        while [[ $# -gt 0 ]]; do
            case $1 in
                --type)
                    [[ -z "''${2:-}" ]] && error "Missing value for --type"
                    local type="$2"
                    local valid=false
                    for t in "''${VALID_TYPES[@]}"; do
                        [[ "$t" == "$type" ]] && valid=true && break
                    done
                    $valid || error "Invalid type: $type (valid: ''${VALID_TYPES[*]})"
                    BUILD_TYPES+=("$type")
                    shift 2
                    ;;
                --all)
                    BUILD_ALL=true
                    shift
                    ;;
                -h|--help) print_usage ;;
                *) error "Unknown option: $1" ;;
            esac
        done
        if [[ "$BUILD_ALL" == true ]]; then BUILD_TYPES=("''${VALID_TYPES[@]}"); fi
        if [[ ''${#BUILD_TYPES[@]} -eq 0 ]]; then error "No types specified. Use --type or --all"; fi
    }

    ensure_base_dir() {
        if [[ ! -d "$BASE_IMAGE_DIR" ]]; then
            log "Creating base image directory: $BASE_IMAGE_DIR"
            sudo mkdir -p "$BASE_IMAGE_DIR"
            sudo chown root:libvirtd "$BASE_IMAGE_DIR"
            sudo chmod 775 "$BASE_IMAGE_DIR"
        fi
    }

    build_base_image() {
        local type="$1"
        local output_name="base-''${type}"
        local output_path="$BASE_IMAGE_DIR/''${output_name}.qcow2"

        log "Building base image: $output_name"
        cd "$PROJECT_DIR"
        git add -A 2>/dev/null || true

        local start_time
        start_time=$(date +%s)

        if command -v nom &>/dev/null; then
            nom build ".#''${output_name}" --out-link "result-''${output_name}" \
                || error "Failed to build $output_name"
        else
            nix build ".#''${output_name}" --out-link "result-''${output_name}" \
                || error "Failed to build $output_name"
        fi

        local end_time duration
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        local built_image=""
        local result_dir="result-''${output_name}"
        for candidate in \
            "$result_dir/nixos.qcow2" \
            "$result_dir/qcow/nixos.qcow2" \
            "$result_dir"/*.qcow2; do
            if [[ -f "$candidate" ]]; then
                built_image="$candidate"
                break
            fi
        done

        if [[ -z "$built_image" ]] || [[ ! -f "$built_image" ]]; then
            log "  Result directory contents:"
            find "$result_dir" -type f 2>/dev/null | head -20 || true
            error "Build succeeded but no qcow2 image found in $result_dir"
        fi

        local size
        size=$(du -h "$built_image" | cut -f1)
        log "  Built in ''${duration}s, size: $size"

        log "  Copying to: $output_path"
        sudo cp "$built_image" "$output_path"
        sudo chown root:libvirtd "$output_path"
        sudo chmod 644 "$output_path"

        local current_rev=""
        if [[ -d "$PROJECT_DIR/.git" ]]; then
            current_rev=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        fi
        if [[ -n "$current_rev" ]]; then
            echo "$current_rev" | sudo tee "$BASE_IMAGE_DIR/.''${output_name}.rev" >/dev/null
            log "  Revision marker: $current_rev"
        fi

        local vm_config_dir="/var/lib/libvirt/vm-configs"
        if [[ -d "$vm_config_dir" ]]; then
            local timestamp
            timestamp=$(date +%s)
            echo "''${timestamp}:''${current_rev}" \
                | sudo tee "$vm_config_dir/.profile-rev-''${type}" >/dev/null
        fi

        rm -f "result-''${output_name}"
        success "Base image ready: $output_path ($size)"
    }

    main() {
        parse_args "$@"
        log "=== Building Base Images ==="
        log "Types: ''${BUILD_TYPES[*]}"
        ensure_base_dir

        local failed=()
        for type in "''${BUILD_TYPES[@]}"; do
            log "----------------------------------------"
            build_base_image "$type" || failed+=("$type")
        done

        if [[ ''${#failed[@]} -eq 0 ]]; then
            success "All base images built successfully!"
        else
            error "Failed to build: ''${failed[*]}"
        fi
    }

    main "$@"
  '';

  deployVmScript = pkgs.writeShellScriptBin "deploy-vm" ''
    # Deploy VM from pre-built base image
    #
    # Instant deployment (~5 seconds) from base images.
    #
    # Usage:
    #   deploy-vm --type browsing --name myvm
    #   deploy-vm --type pentest --name target1 --encrypt
    #
    set -uo pipefail

    readonly BASE_IMAGE_DIR="/var/lib/libvirt/base-images"
    readonly VM_IMAGE_DIR="/var/lib/libvirt/images"
    readonly VM_CONFIG_DIR="/var/lib/libvirt/vm-configs"
    readonly VM_STAGING_DIR="/var/lib/libvirt/vm-staging"

    log()     { echo "[$(date +%H:%M:%S)] $*" >&2; }
    error()   { echo "[ERROR] $*" >&2; exit 1; }
    success() { echo "[SUCCESS] $*" >&2; }

    secure_cleanup() { unset pass1 pass2 luks_password password; }
    trap secure_cleanup EXIT

    VM_TYPE=""
    VM_NAME=""
    VM_USER="''${SUDO_USER:-''${USER:-user}}"
    VM_PASS=""
    VM_BRIDGE=""
    VM_VCPUS="auto"
    VM_MEMORY="auto"
    NO_CONNECT=false
    FORCE=false
    SHARE_STORE=true
    ENCRYPT=false
    ENCRYPT_SECRET_UUID=""

    HOST_USER="''${SUDO_USER:-''${USER}}"
    HOST_HOME=$(eval echo "~$HOST_USER")
    HYDRIX_DIR="$HOST_HOME/hydrix-config"

    declare -A TYPE_BRIDGES=(
        ["pentest"]="br-pentest"
        ["browsing"]="br-browse"
        ["comms"]="br-comms"
        ["dev"]="br-dev"
        ["lurking"]="br-lurking"
        ["transfer"]="br-shared"
    )

    declare -A TYPE_RESOURCES=(
        ["pentest"]="75"
        ["dev"]="75"
        ["browsing"]="50"
        ["comms"]="25"
        ["lurking"]="25"
        ["transfer"]="25"
    )

    HOST_CORES=""
    HOST_RAM_MB=""

    detect_host_resources() {
        HOST_CORES=$(nproc)
        HOST_RAM_MB=$(free -m | grep '^Mem:' | awk '{print $2}')
    }

    calculate_resources() {
        local percent=''${TYPE_RESOURCES[$VM_TYPE]:-50}
        if [[ "$VM_VCPUS" == "auto" ]]; then
            VM_VCPUS=$((HOST_CORES * percent / 100))
            [[ $VM_VCPUS -lt 2 ]] && VM_VCPUS=2
            [[ $VM_VCPUS -ge $HOST_CORES ]] && VM_VCPUS=$((HOST_CORES - 1))
            [[ $VM_VCPUS -lt 2 ]] && VM_VCPUS=2
        fi
        if [[ "$VM_MEMORY" == "auto" ]]; then
            VM_MEMORY=$((HOST_RAM_MB * percent / 100))
            [[ $VM_MEMORY -lt 2048 ]] && VM_MEMORY=2048
            local max_mem=$((HOST_RAM_MB - 4096))
            [[ $VM_MEMORY -gt $max_mem ]] && VM_MEMORY=$max_mem
            [[ $VM_MEMORY -lt 2048 ]] && VM_MEMORY=2048
        fi
    }

    print_usage() {
        cat <<EOF
    Usage: $(basename "$0") --type <type> --name <name> [options]

    Deploy a VM from a pre-built base image.

    Required:
      --type <type>     VM type: pentest, browsing, comms, dev, lurking, transfer
      --name <name>     Instance name (e.g., target1, personal)

    Options:
      --user <user>     Username in VM (default: current user)
      --pass <pass>     Password for user (prompted if omitted)
      --bridge <br>     Network bridge (default: type-based)
      --vcpus <n>       vCPUs (default: auto)
      --memory <mb>     Memory in MB (default: auto)
      --no-connect      Don't attach console after launch
      --force           Overwrite existing VM without prompting
      --no-share-store  Disable host /nix/store sharing
      --encrypt         LUKS-encrypt the VM disk
      -h, --help        Show this help
    EOF
        exit 0
    }

    parse_args() {
        [[ $# -eq 0 ]] && print_usage
        while [[ $# -gt 0 ]]; do
            case $1 in
                --type)        VM_TYPE="$2";   shift 2 ;;
                --name)        VM_NAME="$2";   shift 2 ;;
                --user)        VM_USER="$2";   shift 2 ;;
                --pass)        VM_PASS="$2";   shift 2 ;;
                --bridge)      VM_BRIDGE="$2"; shift 2 ;;
                --vcpus)       VM_VCPUS="$2";  shift 2 ;;
                --memory)      VM_MEMORY="$2"; shift 2 ;;
                --no-connect)  NO_CONNECT=true; shift ;;
                --force)       FORCE=true;      shift ;;
                --no-share-store) SHARE_STORE=false; shift ;;
                --encrypt)     ENCRYPT=true;    shift ;;
                -h|--help)     print_usage ;;
                *)             error "Unknown option: $1" ;;
            esac
        done
        [[ -z "$VM_TYPE" ]] && error "Missing --type"
        [[ -z "$VM_NAME" ]] && error "Missing --name"
        [[ -z "''${TYPE_BRIDGES[$VM_TYPE]:-}" ]] \
            && error "Invalid type: $VM_TYPE (valid: ''${!TYPE_BRIDGES[*]})"
        if [[ -z "$VM_BRIDGE" ]]; then VM_BRIDGE="${
          if config.hydrix.libvirt.defaultBridge != null
          then config.hydrix.libvirt.defaultBridge
          else "\${TYPE_BRIDGES[$VM_TYPE]}"
        }"; fi
    }

    check_base_image() {
        local base_image="$BASE_IMAGE_DIR/base-''${VM_TYPE}.qcow2"
        if [[ ! -f "$base_image" ]]; then
            error "Base image not found: $base_image
    Build it first with: build-base --type $VM_TYPE"
        fi
        echo "$base_image"
    }

    create_vm_config() {
        local config_dir="$VM_CONFIG_DIR/''${VM_TYPE}-''${VM_NAME}"
        local staging_dir="$VM_STAGING_DIR/''${VM_TYPE}-''${VM_NAME}"
        local hostname="''${VM_TYPE}-''${VM_NAME}"

        sudo mkdir -p "$config_dir"
        sudo mkdir -p "$staging_dir/profiles"

        local persist_dir="$HOME/persist/$VM_TYPE"
        mkdir -p "$persist_dir/dev/packages"
        mkdir -p "$persist_dir/staging/packages"
        chmod -R 777 "$persist_dir"

        local profile_src="$HYDRIX_DIR/profiles/''${VM_TYPE}.nix"
        if [[ -f "$profile_src" ]]; then
            sudo cp "$profile_src" "$staging_dir/profiles/"
            sudo chmod -R 777 "$staging_dir"
            sudo chmod 666 "$staging_dir/profiles/"*.nix 2>/dev/null || true
        fi

        echo "$hostname" | sudo tee "$config_dir/hostname" >/dev/null
        echo "$VM_USER"  | sudo tee "$config_dir/username" >/dev/null
        if [[ -n "$VM_PASS" ]]; then
            echo "$VM_PASS" | sudo tee "$config_dir/password" >/dev/null
            sudo chmod 600 "$config_dir/password"
        fi

        success "Config created: $hostname (user: $VM_USER)"
        echo "$config_dir"
    }

    create_vm_disk() {
        local base_image="$1"
        local vm_disk="$VM_IMAGE_DIR/''${VM_TYPE}-''${VM_NAME}.qcow2"

        if [[ -f "$vm_disk" ]]; then
            if $FORCE; then
                sudo rm -f "$vm_disk"
            else
                read -p "VM disk exists: $vm_disk. Overwrite? [y/N] " -n 1 -r
                echo >&2
                [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted"
                sudo rm -f "$vm_disk"
            fi
        fi

        sudo qemu-img create -f qcow2 -b "$base_image" -F qcow2 "$vm_disk" 50G >&2
        success "VM disk created: $vm_disk"
        echo "$vm_disk"
    }

    check_bridge() {
        if ! ip link show "$VM_BRIDGE" &>/dev/null; then
            error "Bridge $VM_BRIDGE not found (virbr0 has no internet). Rebuild the host so the bridge exists, or pass --bridge."
        fi
    }

    create_luks_secret() {
        local vm_name="$1"
        local password="$2"
        local secret_uuid
        secret_uuid=$(uuidgen)

        local secret_xml
        secret_xml=$(cat <<EOF
    <secret ephemeral='no' private='yes'>
      <uuid>''${secret_uuid}</uuid>
      <description>LUKS key for ''${vm_name}</description>
      <usage type='volume'>
        <volume>/var/lib/libvirt/images/''${vm_name}.qcow2</volume>
      </usage>
    </secret>
    EOF
    )
        echo "$secret_xml" | sudo virsh --connect qemu:///system secret-define /dev/stdin >&2
        local password_b64
        password_b64=$(echo -n "$password" | base64)
        sudo virsh --connect qemu:///system secret-set-value "$secret_uuid" "$password_b64" >&2
        echo "$secret_uuid"
    }

    create_encrypted_vm_xml() {
        local vm_name="$1"
        local vm_disk="$2"
        local config_dir="$3"
        local staging_dir="$VM_STAGING_DIR/$vm_name"

        local vm_xml
        vm_xml=$(cat <<EOF
    <domain type='kvm'>
      <name>''${vm_name}</name>
      <memory unit='MiB'>''${VM_MEMORY}</memory>
      <vcpu>''${VM_VCPUS}</vcpu>
      <os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>
      <features><acpi/><apic/></features>
      <cpu mode='host-passthrough'/>
      <devices>
        <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2' cache='writeback'/>
          <source file="''${vm_disk}">
            <encryption format='luks'>
              <secret type='passphrase' uuid="''${ENCRYPT_SECRET_UUID}"/>
            </encryption>
          </source>
          <target dev='vda' bus='virtio'/>
        </disk>
        <interface type='bridge'>
          <source bridge="''${VM_BRIDGE}"/>
          <model type='virtio'/>
        </interface>
        <graphics type='spice'><listen type='none'/></graphics>
        <video><model type='qxl' vgamem='65536'/></video>
        <channel type='spicevmc'>
          <target type='virtio' name='com.redhat.spice.0'/>
        </channel>
        <vsock><cid auto='yes'/></vsock>
        <filesystem type='mount' accessmode='squash'>
          <source dir="''${config_dir}"/>
          <target dir='vm-config'/>
          <readonly/>
        </filesystem>
        <filesystem type='mount' accessmode='mapped'>
          <source dir="''${staging_dir}/profiles"/>
          <target dir='hydrix-profiles'/>
        </filesystem>
    EOF
    )

        if [[ "$SHARE_STORE" == true ]]; then
            vm_xml+="
        <filesystem type='mount'>
          <driver type='virtiofs'/>
          <binary path='/run/current-system/sw/bin/virtiofsd'/>
          <source dir='/nix/store'/>
          <target dir='nix-store'/>
        </filesystem>
      </devices>
      <memoryBacking>
        <source type='memfd'/>
        <access mode='shared'/>
      </memoryBacking>
    </domain>"
        else
            vm_xml+="
      </devices>
    </domain>"
        fi

        echo "$vm_xml" | sudo virsh --connect qemu:///system define /dev/stdin >&2
        sudo virsh --connect qemu:///system start "$vm_name" >&2
        success "Encrypted VM launched: $vm_name (secret: $ENCRYPT_SECRET_UUID)"
    }

    create_encrypted_disk() {
        local base_image="$1"
        local password="$2"
        local vm_disk="$VM_IMAGE_DIR/''${VM_TYPE}-''${VM_NAME}.qcow2"

        if [[ -f "$vm_disk" ]]; then
            if $FORCE; then
                sudo rm -f "$vm_disk"
            else
                read -p "VM disk exists: $vm_disk. Overwrite? [y/N] " -n 1 -r
                echo >&2
                [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted"
                sudo rm -f "$vm_disk"
            fi
        fi

        log "Creating LUKS-encrypted disk..."
        local temp_disk="/tmp/''${VM_TYPE}-''${VM_NAME}-temp.qcow2"
        sudo qemu-img convert -f qcow2 -O qcow2 "$base_image" "$temp_disk" >&2
        sudo qemu-img convert -f qcow2 -O qcow2 \
            --object "secret,id=sec0,data=$password" \
            -o encrypt.format=luks,encrypt.key-secret=sec0 \
            "$temp_disk" "$vm_disk" >&2
        sudo rm -f "$temp_disk"
        sudo qemu-img resize \
            --object "secret,id=sec0,data=$password" \
            --image-opts "driver=qcow2,encrypt.key-secret=sec0,file.driver=file,file.filename=$vm_disk" \
            +40G >&2 || log "  Warning: resize failed, using base size"

        success "Encrypted VM disk created: $vm_disk"
        echo "$vm_disk"
    }

    launch_vm() {
        local vm_disk="$1"
        local config_dir="$2"
        local vm_name="''${VM_TYPE}-''${VM_NAME}"
        local staging_dir="$VM_STAGING_DIR/''${VM_TYPE}-''${VM_NAME}"

        if sudo virsh --connect qemu:///system dominfo "$vm_name" &>/dev/null; then
            sudo virsh --connect qemu:///system destroy "$vm_name" 2>/dev/null || true
            sudo virsh --connect qemu:///system undefine "$vm_name" 2>/dev/null || true
        fi

        check_bridge

        if $ENCRYPT && [[ -n "$ENCRYPT_SECRET_UUID" ]]; then
            create_encrypted_vm_xml "$vm_name" "$vm_disk" "$config_dir"
            return
        fi

        local virt_install_args=(
            --connect qemu:///system
            --name "$vm_name"
            --memory "$VM_MEMORY"
            --vcpus "$VM_VCPUS"
            --disk "path=$vm_disk,format=qcow2,bus=virtio,cache=writeback"
            --network "bridge=$VM_BRIDGE,model=virtio"
            --graphics spice,listen=none
            # 64 MB framebuffer: the default 16 MB cannot hold a 2880x1800 desktop, which kept
            # full-screen guests below the panel's resolution.
            --video model.type=qxl,model.vgamem=65536
            --channel spicevmc
            # No SPICE USB redirection channels: USB goes in only through `usb attach`.
            --redirdev none
            --vsock cid.auto=yes
            --os-variant nixos-unstable
            --boot hd
            --noautoconsole
            --filesystem "source=$config_dir,target=vm-config,mode=squash,readonly=on"
            --filesystem "source=$staging_dir/profiles,target=hydrix-profiles,mode=mapped"
            --filesystem "source=$HOME/.config/hydrix,target=hydrix-config,mode=squash,readonly=on"
            --filesystem "source=$HOME/persist/$VM_TYPE,target=vm-persist,mode=mapped"
        )

        if [[ "$SHARE_STORE" == true ]]; then
            virt_install_args+=(
                --memorybacking source.type=memfd,access.mode=shared
                --filesystem source=/nix/store,target=nix-store,driver.type=virtiofs,binary.path=/run/current-system/sw/bin/virtiofsd
            )
        fi

        sudo virt-install "''${virt_install_args[@]}"
        success "VM launched: $vm_name"
    }

    connect_console() {
        local vm_name="''${VM_TYPE}-''${VM_NAME}"
        log "Connecting to console (Ctrl+] to detach)..."
        sleep 2
        sudo virsh --connect qemu:///system console "$vm_name"
    }

    main() {
        parse_args "$@"
        detect_host_resources
        calculate_resources

        local vm_name="''${VM_TYPE}-''${VM_NAME}"
        local resource_percent=''${TYPE_RESOURCES[$VM_TYPE]:-50}

        log "=== Deploying VM: $vm_name ==="
        log "Type: $VM_TYPE | Bridge: $VM_BRIDGE | Resources: ''${VM_VCPUS} vCPUs, ''${VM_MEMORY}MB (''${resource_percent}% of ''${HOST_CORES}c/''${HOST_RAM_MB}MB)"
        [[ "$ENCRYPT" == true ]] && log "Encryption: LUKS"

        local base_image
        base_image=$(check_base_image)

        local config_dir
        config_dir=$(create_vm_config)

        local vm_disk
        if $ENCRYPT; then
            log "=== LUKS Encryption ==="
            local pass1 pass2
            read -s -p "Enter encryption password: " pass1; echo >&2
            read -s -p "Confirm encryption password: " pass2; echo >&2
            [[ "$pass1" != "$pass2" ]] && error "Passwords do not match"
            [[ -z "$pass1" ]]          && error "Password cannot be empty"

            ENCRYPT_SECRET_UUID=$(create_luks_secret "$vm_name" "$pass1")
            vm_disk=$(create_encrypted_disk "$base_image" "$pass1")
            unset pass1 pass2
        else
            vm_disk=$(create_vm_disk "$base_image")
        fi

        launch_vm "$vm_disk" "$config_dir"

        log "VM is starting. First boot configures hostname and user."
        if $ENCRYPT; then
            log "Secret UUID: $ENCRYPT_SECRET_UUID  (needed to remove: virsh secret-undefine $ENCRYPT_SECRET_UUID)"
        fi

        if $NO_CONNECT; then
            log "Connect with: sudo virsh --connect qemu:///system console $vm_name"
        else
            connect_console
        fi
    }

    main "$@"
  '';
in

{
  options = {
    virtualisation = {
      mainUser = lib.mkOption {
        type = lib.types.str;
        default = config.hydrix.username;
        description = "Main user for virtualization permissions";
      };
      enableLookingGlass = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Looking Glass for GPU passthrough";
      };
    };
  };

  config = lib.mkIf config.hydrix.libvirt.enable {
    # virtio-win ISO at a stable path outside the store (see virtioWinLink).
    systemd.tmpfiles.rules = [
      "d /var/lib/hydrix/libvirt 0755 root root -"
      "L+ ${virtioWinLink} - - - - ${virtioWinIso}"
    ];

    # Resolve mbedtls security warning
    nixpkgs.config.permittedInsecurePackages = [ "mbedtls-2.28.10" ];

    # SPICE agent
    services.spice-vdagentd.enable = lib.mkDefault true;

    # virtiofsd binary path - create /etc/libvirt/qemu.conf
    # (verbatimConfig alone doesn't work - libvirt reads from /etc/libvirt/qemu.conf)
    environment.etc."libvirt/qemu.conf".text = ''
      virtiofsd_binary = "/run/current-system/sw/bin/virtiofsd"
    '';

    # Core virtualization
    virtualisation = {
      libvirtd = {
        enable = true;
        qemu = {
          package = lib.mkDefault pkgs.qemu_kvm;
          swtpm.enable = lib.mkDefault true;
          runAsRoot = true;
        };
        onBoot = lib.mkDefault "start";
        onShutdown = lib.mkDefault "shutdown";
      };
    };

    # Networking for VMs
    networking = {
      firewall = {
        allowedTCPPorts = [
          16509 16514  # libvirt (secure)
          5900 5901 5902 5903  # VNC
          3389  # RDP
        ] ++ lib.optionals config.virtualisation.enableLookingGlass [
          9999  # Looking Glass SPICE
        ];
        allowedUDPPorts = [ 8472 ];
        checkReversePath = "loose";
        # No trustedInterfaces — virbr0 gets only the ports its dnsmasq needs.
        # Hydrix bridges are covered by the explicit DROP in host/networking.nix.
        extraInputRules = ''
          iifname "virbr0" udp dport { 53, 67 } accept
          iifname "virbr0" tcp dport 53 accept
          iifname "virbr0" drop
        '';
      };
    };

    # libvirt nftables backend — consistent with host firewall.
    # Without this, libvirt uses iptables-legacy which conflicts with nftables.
    environment.etc."libvirt/network.conf".text = ''
      firewall_backend = "nftables"
    '';

    # Kernel parameters for virtualization
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
      "vm.max_map_count" = 2147483647;
      "kernel.unprivileged_userns_clone" = 1;
    };

    # Virtualization packages + management scripts
    environment.systemPackages = [
      buildBaseScript
      deployVmScript
      deployWindowsScript
      libvirtTuneScript
    ] ++ (with pkgs; [
      qemu_kvm
      virtManager
      virt-viewer
      libvirt
      libosinfo
      guestfs-tools
      spice-gtk
      spice-vdagent
      spice-protocol
      swtpm
      virtiofsd
      virtio-win
      win-spice
      bridge-utils
      iproute2
      bind.dnsutils
    ]) ++ lib.optionals config.virtualisation.enableLookingGlass [
      pkgs.looking-glass-client
    ];

    # Add user to virtualization groups
    users.users.${config.virtualisation.mainUser}.extraGroups =
      [ "libvirtd" "kvm" "qemu" ];

    # Libvirt service setup
    systemd.services.libvirtd = {
      path = with pkgs; [ bridge-utils iproute2 ];
      preStart = ''
        mkdir -p /var/lib/libvirt/{qemu/networks/autostart,images,dnsmasq}
        chmod 755 /var/lib/libvirt/{qemu/networks{,/autostart},images,dnsmasq}
      '';
    };

    # libvirt's default network, isolated: guests on virbr0 get DHCP/DNS from
    # the host but no route anywhere, and libvirt never switches on host IP
    # forwarding (it does for any NAT or routed network). Standalone VMs get
    # internet from a router-served bridge instead (deploy-vm --bridge/type).
    # NixOS seeds /var/lib/libvirt with libvirt's stock NAT definition once,
    # so an existing one is redefined here.
    systemd.services.libvirt-default-network = let
      virsh = "${config.virtualisation.libvirtd.package}/bin/virsh -c qemu:///system";
      isolated = pkgs.writeText "libvirt-default-network.xml" ''
        <network>
          <name>default</name>
          <bridge name="virbr0" stp="on" delay="0"/>
          <ip address="192.168.122.1" netmask="255.255.255.0">
            <dhcp>
              <range start="192.168.122.10" end="192.168.122.200"/>
            </dhcp>
          </ip>
        </network>
      '';
    in {
      description = "Keep libvirt's default network isolated";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if ${virsh} net-dumpxml default 2>/dev/null | grep -q "<forward"; then
          ${virsh} net-destroy default 2>/dev/null || true
          ${virsh} net-undefine default
          ${virsh} net-define ${isolated}
          ${virsh} net-autostart default
          ${virsh} net-start default
          echo "libvirt default network redefined as isolated"
        fi
      '';
    };

    # virt-manager grab/release key — set per-machine via hydrix.libvirt.grabKey
    home-manager.users.${config.hydrix.username}.dconf.settings = {
      "org/virt-manager/virt-manager/console" = {
        grab-keys = lib.mkDefault config.hydrix.libvirt.grabKey;
        # No SPICE USB auto-redirect: a device plugged in while a console is open must not go
        # to the guest by itself. USB reaches a VM only through `usb attach` (host/usb.nix).
        auto-redirect = lib.mkDefault false;
      };
    };
  };
}
