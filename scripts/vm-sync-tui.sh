#!/usr/bin/env bash
# vm-sync-tui - TUI for managing VM package development workflow
#
# Unified interface for:
# - Viewing packages in development across VMs
# - Staging packages (dev flake.nix → staging/package.nix)
# - Pulling to profiles
# - Rebuilding affected VMs
#
# Dependencies: fzf, python3
#
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly PROFILES_DIR="$PROJECT_DIR/profiles"
readonly PERSIST_BASE="$HOME/persist"

# VM types that support package development
readonly VM_TYPES=("browsing" "pentest" "dev")

# Colors
readonly RED=$'\e[31m'
readonly GREEN=$'\e[32m'
readonly YELLOW=$'\e[33m'
readonly BLUE=$'\e[34m'
readonly CYAN=$'\e[36m'
readonly MAGENTA=$'\e[35m'
readonly NC=$'\e[0m'
readonly BOLD=$'\e[1m'
readonly DIM=$'\e[38;5;8m'

# Stage indicators
readonly STAGE_DEV="${YELLOW}[dev]${NC}"
readonly STAGE_STG="${CYAN}[stg]${NC}"
readonly STAGE_INS="${GREEN}[ins]${NC}"

# ============================================================================
# Utility Functions
# ============================================================================

log() { echo -e "$*"; }
error() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}$*${NC}"; }

# Get color for VM type
get_vm_color() {
    local vm_type="$1"
    case "$vm_type" in
        browsing) echo "$GREEN" ;;
        pentest)  echo "$RED" ;;
        dev)      echo "$BLUE" ;;
        *)        echo "$NC" ;;
    esac
}

# Check dependencies
check_deps() {
    local missing=()
    command -v fzf &>/dev/null || missing+=("fzf")
    command -v python3 &>/dev/null || missing+=("python3")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        exit 1
    fi
}

# ============================================================================
# Package Discovery
# ============================================================================

# Parse packages from a dev flake.nix
# Extracts package names from packages.${system} = { <name> = ... }
parse_dev_flake_packages() {
    local flake_path="$1"
    [[ ! -f "$flake_path" ]] && return

    FLAKE_PATH="$flake_path" python3 -c "
import re
import sys
import os

flake_path = os.environ.get('FLAKE_PATH', '')
if not flake_path:
    sys.exit(0)

with open(flake_path, 'r') as f:
    content = f.read()

# Find packages.\${system} = { and then parse with brace matching
start_match = re.search(r'packages\.\\\$\{system\}\s*=\s*\{', content)
if not start_match:
    sys.exit(0)

# Find the matching closing brace
start = start_match.end()
depth = 1
end = start
for i, char in enumerate(content[start:], start):
    if char == '{':
        depth += 1
    elif char == '}':
        depth -= 1
        if depth == 0:
            end = i
            break

block = content[start:end]

# Parse the block for top-level assignments
found_packages = []
i = 0
while i < len(block):
    # Skip whitespace
    while i < len(block) and block[i] in ' \t\n':
        i += 1
    if i >= len(block):
        break

    # Skip comments
    if block[i] == '#':
        while i < len(block) and block[i] != '\n':
            i += 1
        continue

    # Look for identifier = pattern
    match = re.match(r'([a-zA-Z_][a-zA-Z0-9_-]*)\s*=', block[i:])
    if match:
        name = match.group(1)
        i += match.end()

        # Skip the derivation (handle nested braces)
        depth = 0
        in_string = False
        while i < len(block):
            char = block[i]
            if char == '\"' and (i == 0 or block[i-1] != '\\\\'):
                in_string = not in_string
            elif not in_string:
                if char == '{':
                    depth += 1
                elif char == '}':
                    depth -= 1
                elif char == ';' and depth == 0:
                    if name != 'default':
                        found_packages.append(name)
                    i += 1
                    break
            i += 1
    else:
        i += 1

for pkg in found_packages:
    print(pkg)
"
}

# Get development packages (from ~/persist/<type>/dev/flake.nix)
get_dev_packages() {
    for vm_type in "${VM_TYPES[@]}"; do
        local flake_path="$PERSIST_BASE/$vm_type/dev/flake.nix"
        if [[ -f "$flake_path" ]]; then
            for pkg in $(parse_dev_flake_packages "$flake_path"); do
                echo "dev:$vm_type:$pkg:flake"
            done
        fi
    done
}

# Get staged packages
# Sources:
#   1. ~/persist/<type>/staging/packages/<name>/package.nix (extracted package.nix)
#   2. ~/persist/<type>/staging/dev/flake.nix (staged flake with packages)
get_staged_packages() {
    for vm_type in "${VM_TYPES[@]}"; do
        # Check for individual package.nix files
        local staging_dir="$PERSIST_BASE/$vm_type/staging/packages"
        if [[ -d "$staging_dir" ]]; then
            for pkg_dir in "$staging_dir"/*/; do
                [[ ! -d "$pkg_dir" ]] && continue
                local pkg_name=$(basename "$pkg_dir")
                if [[ -f "${pkg_dir}package.nix" ]]; then
                    echo "stg:$vm_type:$pkg_name:staged"
                fi
            done
        fi

        # Also check for staging/dev/flake.nix (VM-synced flake)
        local staging_flake="$PERSIST_BASE/$vm_type/staging/dev/flake.nix"
        if [[ -f "$staging_flake" ]]; then
            for pkg in $(parse_dev_flake_packages "$staging_flake"); do
                echo "stg:$vm_type:$pkg:staging-flake"
            done
        fi
    done
}

# Get installed packages (from profiles/<type>/packages/<name>.nix)
get_installed_packages() {
    for vm_type in "${VM_TYPES[@]}"; do
        local packages_dir="$PROFILES_DIR/$vm_type/packages"
        if [[ -d "$packages_dir" ]]; then
            for pkg_file in "$packages_dir"/*.nix; do
                [[ ! -f "$pkg_file" ]] && continue
                local pkg_name=$(basename "$pkg_file" .nix)
                [[ "$pkg_name" == "default" ]] && continue
                echo "ins:$vm_type:$pkg_name:profile"
            done
        fi
    done
}

# Collect all packages, deduplicated with priority: ins > stg > dev
collect_all_packages() {
    declare -A seen

    # First pass: installed packages (highest priority)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local stage vm_type pkg_name source
        IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
        local key="${vm_type}:${pkg_name}"
        if [[ -z "${seen[$key]:-}" ]]; then
            seen[$key]="$entry"
        fi
    done < <(get_installed_packages)

    # Second pass: staged packages
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local stage vm_type pkg_name source
        IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
        local key="${vm_type}:${pkg_name}"
        if [[ -z "${seen[$key]:-}" ]]; then
            seen[$key]="$entry"
        fi
    done < <(get_staged_packages)

    # Third pass: dev packages (lowest priority)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local stage vm_type pkg_name source
        IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
        local key="${vm_type}:${pkg_name}"
        if [[ -z "${seen[$key]:-}" ]]; then
            seen[$key]="$entry"
        fi
    done < <(get_dev_packages)

    # Output all entries
    for entry in "${seen[@]}"; do
        echo "$entry"
    done | sort -t: -k2,2 -k3,3
}

# ============================================================================
# Display Formatting
# ============================================================================

# Format a package entry for display
# Input: stage:vmtype:name:source
format_package_entry() {
    local entry="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    local stage_display
    case "$stage" in
        dev) stage_display="$STAGE_DEV" ;;
        stg) stage_display="$STAGE_STG" ;;
        ins) stage_display="$STAGE_INS" ;;
        *)   stage_display="[???]" ;;
    esac

    local vm_color
    vm_color=$(get_vm_color "$vm_type")

    # Fixed-width formatting for alignment
    printf "%b  ${vm_color}%-10s${NC} %s\n" "$stage_display" "$vm_type" "$pkg_name"
}

# Raw list for fzf (includes data in format fzf can parse)
list_raw() {
    local packages
    packages=$(collect_all_packages)

    if [[ -z "$packages" ]]; then
        echo "${DIM}No packages found${NC}"
        echo ""
        echo "Start development in a VM:"
        echo "  vm-dev build https://github.com/owner/repo"
        return
    fi

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        # Output: formatted_display \t raw_data
        local formatted
        formatted=$(format_package_entry "$entry")
        echo -e "${formatted}\t${entry}"
    done <<< "$packages"

    echo ""
    echo "-------------------------"
    echo -e "Refresh\t__refresh__"
    echo -e "Exit\t__exit__"
}

# ============================================================================
# Package Operations
# ============================================================================

# Extract derivation from flake.nix and create package.nix
# Handles both simple (pkgs.foo) and complex (pkgs.buildRustPackage { ... }) derivations
extract_derivation() {
    local flake_path="$1"
    local pkg_name="$2"

    python3 << EOF
import re
import sys

with open("$flake_path", "r") as f:
    content = f.read()

# Find the package definition
pkg_name = "$pkg_name"

# Match: pkg_name = <derivation>;
# Handle both simple and complex derivations with nested braces
pattern = rf'{pkg_name}\s*=\s*'
match = re.search(pattern, content)
if not match:
    sys.exit(1)

start = match.end()
# Find the complete derivation (handle nested braces)
depth = 0
in_string = False
escape_next = False
end = start

for i, char in enumerate(content[start:], start):
    if escape_next:
        escape_next = False
        continue
    if char == '\\\\':
        escape_next = True
        continue
    if char == '"' and not in_string:
        in_string = True
        continue
    if char == '"' and in_string:
        in_string = False
        continue
    if in_string:
        continue

    if char == '{':
        depth += 1
    elif char == '}':
        depth -= 1
    elif char == ';' and depth == 0:
        end = i
        break

derivation = content[start:end].strip()

# Create standalone package.nix
print("{ pkgs }:")
print("")
print(derivation)
EOF
}

# Stage a package (extract from dev flake → staging)
stage_package() {
    local entry="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    if [[ "$stage" != "dev" ]]; then
        echo -e "${YELLOW}Package is not in development stage${NC}"
        return 1
    fi

    local flake_path="$PERSIST_BASE/$vm_type/dev/flake.nix"
    local staging_dir="$PERSIST_BASE/$vm_type/staging/packages/$pkg_name"

    if [[ ! -f "$flake_path" ]]; then
        echo -e "${RED}Dev flake not found: $flake_path${NC}"
        return 1
    fi

    # Create staging directory
    mkdir -p "$staging_dir"

    # Extract derivation
    echo -e "${CYAN}Extracting $pkg_name from dev flake...${NC}"
    if ! extract_derivation "$flake_path" "$pkg_name" > "$staging_dir/package.nix"; then
        echo -e "${RED}Failed to extract derivation${NC}"
        rm -rf "$staging_dir"
        return 1
    fi

    success "Staged: $staging_dir/package.nix"
    echo ""
    echo "Preview:"
    head -20 "$staging_dir/package.nix"
    if [[ $(wc -l < "$staging_dir/package.nix") -gt 20 ]]; then
        echo "..."
    fi
}

# Regenerate default.nix for a profile
regenerate_default() {
    local vm_type="$1"
    local packages_dir="$PROFILES_DIR/$vm_type/packages"
    local default_file="$packages_dir/default.nix"

    # Collect package files
    local package_files=()
    for pkg_file in "$packages_dir"/*.nix; do
        [[ ! -f "$pkg_file" ]] && continue
        [[ "$(basename "$pkg_file")" == "default.nix" ]] && continue
        package_files+=("$(basename "$pkg_file" .nix)")
    done

    # Write default.nix
    cat > "$default_file" << EOF
# Auto-generated package list for $vm_type profile
# Managed by vm-sync - do not edit manually
{ pkgs }:
[
EOF

    for pkg_name in "${package_files[@]}"; do
        echo "  (import ./${pkg_name}.nix { inherit pkgs; })" >> "$default_file"
    done

    echo "]" >> "$default_file"
}

# Pull package from staging to profile(s)
pull_package() {
    local entry="$1"
    shift
    local targets=("$@")

    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    if [[ "$stage" != "stg" ]]; then
        echo -e "${YELLOW}Package must be staged before pulling${NC}"
        return 1
    fi

    # Determine package source
    local staging_path=""
    local extract_from_flake=false

    if [[ "$source" == "staging-flake" ]]; then
        # Package is in staging/dev/flake.nix - extract it
        local staging_flake="$PERSIST_BASE/$vm_type/staging/dev/flake.nix"
        if [[ ! -f "$staging_flake" ]]; then
            echo -e "${RED}Staging flake not found: $staging_flake${NC}"
            return 1
        fi
        extract_from_flake=true
    else
        # Package is in staging/packages/<name>/package.nix
        staging_path="$PERSIST_BASE/$vm_type/staging/packages/$pkg_name/package.nix"
        if [[ ! -f "$staging_path" ]]; then
            echo -e "${RED}Staged package not found: $staging_path${NC}"
            return 1
        fi
    fi

    # If no targets specified, use the source VM type
    if [[ ${#targets[@]} -eq 0 ]]; then
        targets=("$vm_type")
    fi

    for target in "${targets[@]}"; do
        local packages_dir="$PROFILES_DIR/$target/packages"
        mkdir -p "$packages_dir"

        if [[ "$extract_from_flake" == "true" ]]; then
            # Extract derivation from staging flake
            local staging_flake="$PERSIST_BASE/$vm_type/staging/dev/flake.nix"
            echo -e "${CYAN}Extracting $pkg_name from staging flake...${NC}"
            if ! extract_derivation "$staging_flake" "$pkg_name" > "$packages_dir/${pkg_name}.nix"; then
                echo -e "${RED}Failed to extract derivation${NC}"
                return 1
            fi
        else
            cp "$staging_path" "$packages_dir/${pkg_name}.nix"
        fi
        log "Installed to $target/packages/${pkg_name}.nix"

        regenerate_default "$target"
    done

    success "Pulled $pkg_name to: ${targets[*]}"
}

# Remove package from profile
remove_package() {
    local entry="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    if [[ "$stage" != "ins" ]]; then
        echo -e "${YELLOW}Package is not installed${NC}"
        return 1
    fi

    local pkg_file="$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix"
    if [[ -f "$pkg_file" ]]; then
        rm "$pkg_file"
        regenerate_default "$vm_type"
        success "Removed $pkg_name from $vm_type"
    else
        echo -e "${YELLOW}Package file not found${NC}"
    fi
}

# Get list of profiles that have been modified
get_modified_profiles() {
    local modified=()

    for vm_type in "${VM_TYPES[@]}"; do
        local packages_dir="$PROFILES_DIR/$vm_type/packages"
        if git -C "$PROJECT_DIR" status --porcelain "$packages_dir" 2>/dev/null | grep -q .; then
            modified+=("$vm_type")
        fi
    done

    printf '%s\n' "${modified[@]}"
}

# Get list of microVMs that need rebuilding
get_microvms_needing_rebuild() {
    local modified_profiles
    modified_profiles=$(get_modified_profiles)

    [[ -z "$modified_profiles" ]] && return

    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        # Find microVMs of this type
        nix eval "$PROJECT_DIR#nixosConfigurations" --apply 'builtins.attrNames' --json 2>/dev/null | \
            jq -r '.[]' | grep "^microvm-${profile}" || true
    done <<< "$modified_profiles"
}

# Rebuild menu - choose what to rebuild
rebuild_vms() {
    local modified_profiles
    modified_profiles=$(get_modified_profiles)

    if [[ -z "$modified_profiles" ]]; then
        echo -e "${YELLOW}No profiles have been modified${NC}"
        return
    fi

    echo -e "${BOLD}Modified profiles:${NC}"
    echo "$modified_profiles" | sed 's/^/  - /'
    echo ""

    # Build options
    local options=(
        "Rebuild MicroVMs - Fast, for testing"
        "Rebuild Libvirt Base Images - For new deployments"
        "Rebuild Both - MicroVMs and base images"
        "Cancel"
    )

    local choice
    choice=$(printf '%s\n' "${options[@]}" | fzf \
        --color=16 \
        --header="What to rebuild?" \
        --height=10 \
        --reverse) || choice=""

    case "$choice" in
        *"MicroVMs"*)
            rebuild_microvms
            ;;
        *"Base Images"*)
            rebuild_base_images "$modified_profiles"
            ;;
        *"Both"*)
            rebuild_microvms
            echo ""
            rebuild_base_images "$modified_profiles"
            ;;
        *)
            echo "Cancelled"
            ;;
    esac
}

# Rebuild microVMs
rebuild_microvms() {
    local vms_to_rebuild
    vms_to_rebuild=$(get_microvms_needing_rebuild)

    if [[ -z "$vms_to_rebuild" ]]; then
        echo -e "${YELLOW}No microVMs need rebuilding${NC}"
        return
    fi

    echo -e "${BOLD}Rebuilding MicroVMs:${NC}"
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        echo -e "${CYAN}Building $vm...${NC}"
        "$SCRIPT_DIR/microvm" build "$vm" || echo -e "${YELLOW}Failed: $vm${NC}"
    done <<< "$vms_to_rebuild"

    success "MicroVM rebuild complete"
}

# Rebuild libvirt base images
rebuild_base_images() {
    local profiles="$1"

    echo -e "${BOLD}Rebuilding Libvirt Base Images:${NC}"
    echo -e "${DIM}(This may take several minutes per image)${NC}"
    echo ""

    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        echo -e "${CYAN}Building base-${profile}...${NC}"
        "$SCRIPT_DIR/build-base.sh" --type "$profile" || echo -e "${YELLOW}Failed: $profile${NC}"
        echo ""
    done <<< "$profiles"

    success "Base image rebuild complete"
    echo ""
    echo -e "${DIM}Deploy new VMs with: ./scripts/deploy-vm.sh --type <type> --name <name>${NC}"
}

# ============================================================================
# Preview Functions
# ============================================================================

# Preview package content
preview_package() {
    local raw_data="$1"

    # Handle special entries
    case "$raw_data" in
        __refresh__|__exit__|"")
            echo "Select a package to preview"
            return
            ;;
    esac

    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"

    local vm_color
    vm_color=$(get_vm_color "$vm_type")

    echo -e "${BOLD}Package: ${NC}$pkg_name"
    echo -e "${BOLD}VM Type: ${NC}${vm_color}$vm_type${NC}"
    echo -e "${BOLD}Stage:   ${NC}$stage"
    echo ""

    case "$stage" in
        dev)
            echo -e "${DIM}Source: ~/persist/$vm_type/dev/flake.nix${NC}"
            echo ""
            local flake_path="$PERSIST_BASE/$vm_type/dev/flake.nix"
            if [[ -f "$flake_path" ]]; then
                # Show relevant section
                python3 << EOF
import re
import sys

with open("$flake_path", "r") as f:
    content = f.read()

pkg_name = "$pkg_name"
# Find and print the package definition with context
pattern = rf'(\n\s*{pkg_name}\s*=)'
match = re.search(pattern, content)
if match:
    start = match.start()
    # Find start of line
    line_start = content.rfind('\n', 0, start) + 1
    # Find end (matching semicolon at same depth)
    depth = 0
    end = match.end()
    for i, char in enumerate(content[match.end():], match.end()):
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
        elif char == ';' and depth == 0:
            end = i + 1
            break
    print(content[line_start:end])
else:
    print("Package definition not found")
EOF
            fi
            echo ""
            echo -e "${DIM}Actions: [s]tage${NC}"
            ;;
        stg)
            if [[ "$source" == "staging-flake" ]]; then
                echo -e "${DIM}Source: ~/persist/$vm_type/staging/dev/flake.nix${NC}"
                echo ""
                local staging_flake="$PERSIST_BASE/$vm_type/staging/dev/flake.nix"
                if [[ -f "$staging_flake" ]]; then
                    # Show relevant section from staging flake
                    python3 << EOF
import re
import sys

with open("$staging_flake", "r") as f:
    content = f.read()

pkg_name = "$pkg_name"
pattern = rf'(\n\s*{pkg_name}\s*=)'
match = re.search(pattern, content)
if match:
    start = match.start()
    line_start = content.rfind('\n', 0, start) + 1
    depth = 0
    end = match.end()
    for i, char in enumerate(content[match.end():], match.end()):
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
        elif char == ';' and depth == 0:
            end = i + 1
            break
    print(content[line_start:end])
else:
    print("Package definition not found")
EOF
                fi
            else
                echo -e "${DIM}Source: ~/persist/$vm_type/staging/packages/$pkg_name/package.nix${NC}"
                echo ""
                local staging_path="$PERSIST_BASE/$vm_type/staging/packages/$pkg_name/package.nix"
                if [[ -f "$staging_path" ]]; then
                    head -30 "$staging_path"
                    if [[ $(wc -l < "$staging_path") -gt 30 ]]; then
                        echo "..."
                    fi
                fi
            fi
            echo ""
            echo -e "${DIM}Actions: [p]ull to profile${NC}"
            ;;
        ins)
            echo -e "${DIM}Source: profiles/$vm_type/packages/$pkg_name.nix${NC}"
            echo ""
            local pkg_path="$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix"
            if [[ -f "$pkg_path" ]]; then
                head -30 "$pkg_path"
                if [[ $(wc -l < "$pkg_path") -gt 30 ]]; then
                    echo "..."
                fi
            fi
            echo ""
            echo -e "${DIM}Actions: [x] remove${NC}"
            ;;
    esac
}

# Show diff between staged and installed
show_diff() {
    local raw_data="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"

    local staged_path="$PERSIST_BASE/$vm_type/staging/packages/$pkg_name/package.nix"
    local installed_path="$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix"

    if [[ -f "$staged_path" && -f "$installed_path" ]]; then
        diff --color=always "$installed_path" "$staged_path" || true
    elif [[ -f "$staged_path" ]]; then
        echo -e "${GREEN}New package (not yet installed)${NC}"
        cat "$staged_path"
    elif [[ -f "$installed_path" ]]; then
        echo -e "${YELLOW}Installed (no staged version)${NC}"
        cat "$installed_path"
    else
        echo "No source files found"
    fi
}

# ============================================================================
# Actions Menu
# ============================================================================

show_actions_menu() {
    local raw_data="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"

    local actions=()

    case "$stage" in
        dev)
            actions+=("Stage package")
            actions+=("View source")
            ;;
        stg)
            actions+=("Pull to profile")
            actions+=("Pull to multiple profiles...")
            actions+=("View source")
            actions+=("View diff")
            ;;
        ins)
            actions+=("Remove from profile")
            actions+=("View source")
            ;;
    esac

    actions+=("Back")

    local action
    action=$(printf '%s\n' "${actions[@]}" | fzf --prompt="$pkg_name > " --height=12 --reverse \
        --color="fg:-1,bg:-1,hl:yellow,fg+:7,bg+:0,hl+:yellow,pointer:cyan,marker:cyan,header:blue,info:cyan,prompt:cyan,query:7")

    case "$action" in
        "Stage package")
            stage_package "$raw_data"
            read -p "Press Enter to continue..."
            ;;
        "Pull to profile")
            pull_package "$raw_data"
            read -p "Press Enter to continue..."
            ;;
        "Pull to multiple profiles...")
            echo "Select profiles (Tab to multi-select):"
            local targets
            targets=$(printf '%s\n' "${VM_TYPES[@]}" | fzf --multi --prompt="Profiles > " --height=8 --reverse)
            if [[ -n "$targets" ]]; then
                pull_package "$raw_data" $targets
            fi
            read -p "Press Enter to continue..."
            ;;
        "Remove from profile")
            remove_package "$raw_data"
            read -p "Press Enter to continue..."
            ;;
        "View source")
            preview_package "$raw_data" | less -R
            ;;
        "View diff")
            show_diff "$raw_data" | less -R
            ;;
        "Back"|"")
            return
            ;;
    esac
}

# ============================================================================
# Main Menu
# ============================================================================

main_menu() {
    while true; do
        clear

        local header="${CYAN}[s]${NC}tage  ${CYAN}[p]${NC}ull  ${CYAN}[x]${NC}remove  ${CYAN}[R]${NC}ebuild  ${CYAN}[r]${NC}efresh  ${CYAN}[q]${NC}uit"

        # Build bind commands
        local bind_s="execute($SELF_PATH --stage {-1})+reload($SELF_PATH --list-raw)"
        local bind_p="execute($SELF_PATH --pull {-1})+reload($SELF_PATH --list-raw)"
        local bind_x="execute($SELF_PATH --remove {-1})+reload($SELF_PATH --list-raw)"
        local bind_R="execute($SELF_PATH --rebuild)"
        local bind_r="reload($SELF_PATH --list-raw)"

        local selection
        selection=$("$SELF_PATH" --list-raw | \
            fzf --ansi --prompt="vm-sync > " --height=25 --reverse \
                --header="$header" \
                --delimiter=$'\t' \
                --with-nth=1 \
                --color="fg:-1,bg:-1,hl:yellow,fg+:7,bg+:0,hl+:yellow,pointer:cyan,marker:cyan,header:blue,info:cyan,prompt:cyan,query:7" \
                --preview "$SELF_PATH --preview {-1}" \
                --preview-window="right:50%:wrap" \
                --bind "s:$bind_s" \
                --bind "p:$bind_p" \
                --bind "x:$bind_x" \
                --bind "R:$bind_R+reload($SELF_PATH --list-raw)" \
                --bind "r:$bind_r" \
                --bind "d:execute($SELF_PATH --diff {-1} | less -R)" \
                --bind "v:execute($SELF_PATH --view {-1})"
            ) || selection=""

        # Extract raw data (last field after tab)
        local raw_data
        raw_data=$(echo "$selection" | awk -F'\t' '{print $NF}')

        case "$raw_data" in
            __refresh__)
                continue
                ;;
            __exit__|"")
                exit 0
                ;;
            *)
                show_actions_menu "$raw_data"
                ;;
        esac
    done
}

# ============================================================================
# Entry Point
# ============================================================================

main() {
    case "${1:-}" in
        --list-raw)
            list_raw
            ;;
        --preview)
            preview_package "${2:-}"
            ;;
        --diff)
            show_diff "${2:-}"
            ;;
        --view)
            local raw_data="${2:-}"
            local stage vm_type pkg_name source
            IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"
            case "$stage" in
                dev) less "$PERSIST_BASE/$vm_type/dev/flake.nix" ;;
                stg) less "$PERSIST_BASE/$vm_type/staging/packages/$pkg_name/package.nix" ;;
                ins) less "$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix" ;;
            esac
            ;;
        --stage)
            stage_package "${2:-}"
            read -p "Press Enter to continue..."
            ;;
        --pull)
            pull_package "${2:-}"
            read -p "Press Enter to continue..."
            ;;
        --remove)
            remove_package "${2:-}"
            read -p "Press Enter to continue..."
            ;;
        --rebuild)
            rebuild_vms
            read -p "Press Enter to continue..."
            ;;
        -h|--help)
            cat << 'EOF'
vm-sync-tui - TUI for VM package sync workflow

Usage: vm-sync-tui.sh

Hotkeys:
  s       Stage selected package (dev → staging)
  p       Pull selected package (staging → profile)
  x       Remove package from profile
  R       Rebuild menu (choose MicroVMs, Base Images, or Both)
  r       Refresh list
  d       View diff (staged vs installed)
  v       View full source in pager
  Enter   Actions submenu
  q/Esc   Exit

Package stages:
  [dev]   In development (~/persist/<type>/dev/flake.nix)
  [stg]   Staged (~/persist/<type>/staging/packages/<name>/package.nix)
  [ins]   Installed in profile (profiles/<type>/packages/<name>.nix)

Workflow (MicroVMs - for quick testing):
  1. Develop package in VM: vm-dev build <url>
  2. Test in VM: vm-dev run <name>
  3. Stage on host: Press 's' on [dev] package
  4. Pull to profile: Press 'p' on [stg] package
  5. Rebuild microVM: Press 'R', select MicroVMs

Workflow (Libvirt - for permanent named instances):
  1-4. Same as above
  5. Rebuild base image: Press 'R', select Base Images
  6. Deploy new VM: ./scripts/deploy-vm.sh --type <type> --name <name>

EOF
            ;;
        *)
            check_deps
            main_menu
            ;;
    esac
}

main "$@"
