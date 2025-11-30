#!/usr/bin/env bash

# Hydrix - Add New Machine Script
# Interactive script to add support for a new physical machine

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Hydrix - Add New Machine"
echo "======================================"
echo ""

# Gather information
read -p "Machine name (e.g., 'thinkpad'): " MACHINE_NAME
read -p "Flake name (lowercase, e.g., 'thinkpad'): " FLAKE_NAME
read -p "Model detection pattern (e.g., 'thinkpad'): " MODEL_PATTERN
read -p "Short description: " DESCRIPTION
read -p "Hostname to use: " HOSTNAME

echo ""
echo "Summary:"
echo "  Machine Name: $MACHINE_NAME"
echo "  Flake Name: $FLAKE_NAME"
echo "  Model Pattern: $MODEL_PATTERN"
echo "  Description: $DESCRIPTION"
echo "  Hostname: $HOSTNAME"
echo ""
read -p "Create these files? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Creating machine profile..."

# Create machine profile from template
PROFILE_FILE="$SCRIPT_DIR/profiles/machines/${FLAKE_NAME}.nix"
cp "$SCRIPT_DIR/templates/machine-profile.nix.template" "$PROFILE_FILE"
sed -i "s/{{HOSTNAME}}/$HOSTNAME/g" "$PROFILE_FILE"

echo "✓ Created: $PROFILE_FILE"

# Generate nixbuild entry
NIXBUILD_ENTRY=$(mktemp)
cp "$SCRIPT_DIR/templates/nixbuild-entry.sh.template" "$NIXBUILD_ENTRY"
sed -i "s/{{MACHINE_NAME}}/$MACHINE_NAME/g" "$NIXBUILD_ENTRY"
sed -i "s/{{MODEL_PATTERN}}/$MODEL_PATTERN/g" "$NIXBUILD_ENTRY"
sed -i "s/{{FLAKE_NAME}}/$FLAKE_NAME/g" "$NIXBUILD_ENTRY"

echo ""
echo "✓ Generated nixbuild.sh entry"
echo ""
echo "----------------------------------------"
cat "$NIXBUILD_ENTRY"
echo "----------------------------------------"
echo ""
echo "Add the above block to nixbuild.sh in the 'ADD NEW PHYSICAL MACHINES HERE' section"
echo ""

# Generate flake entry
FLAKE_ENTRY=$(mktemp)
cp "$SCRIPT_DIR/templates/flake-entry.nix.template" "$FLAKE_ENTRY"
sed -i "s/{{MACHINE_NAME}}/$MACHINE_NAME/g" "$FLAKE_ENTRY"
sed -i "s/{{FLAKE_NAME}}/$FLAKE_NAME/g" "$FLAKE_ENTRY"
sed -i "s/{{DESCRIPTION}}/$DESCRIPTION/g" "$FLAKE_ENTRY"

echo "✓ Generated flake.nix entry"
echo ""
echo "----------------------------------------"
cat "$FLAKE_ENTRY"
echo "----------------------------------------"
echo ""
echo "Add the above block to flake.nix in the nixosConfigurations section"
echo ""

echo "======================================"
echo "Next steps:"
echo "======================================"
echo "1. Edit $PROFILE_FILE to add machine-specific settings"
echo "2. Add the nixbuild.sh entry to nixbuild.sh"
echo "3. Add the flake.nix entry to flake.nix"
echo "4. Run: ./nixbuild.sh"
echo ""
echo "Done!"

# Cleanup
rm -f "$NIXBUILD_ENTRY" "$FLAKE_ENTRY"
