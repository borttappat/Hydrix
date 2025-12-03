#!/usr/bin/env bash
# Deploy Obsidian configuration to all vaults
# This script reads vault paths from ~/.config/obsidian/obsidian.json
# and deploys templated configs to each vault

set -e

OBSIDIAN_CONFIG="$HOME/.config/obsidian/obsidian.json"
TEMPLATE_DIR="$HOME/.config/obsidian-templates"

# Check if obsidian.json exists
if [ ! -f "$OBSIDIAN_CONFIG" ]; then
    echo "No Obsidian config found at $OBSIDIAN_CONFIG"
    exit 0
fi

# Source display config for font variables
source "$HOME/.config/scripts/load-display-config.sh" >/dev/null 2>&1 || true

# Extract vault paths from obsidian.json
VAULTS=$(jq -r '.vaults | to_entries[] | .value.path' "$OBSIDIAN_CONFIG" 2>/dev/null)

if [ -z "$VAULTS" ]; then
    echo "No Obsidian vaults found"
    exit 0
fi

echo "Deploying Obsidian configuration to vaults..."

# Deploy config to each vault
while IFS= read -r VAULT_PATH; do
    if [ -d "$VAULT_PATH" ]; then
        echo "  Updating vault: $VAULT_PATH"

        # Create .obsidian/snippets directory if it doesn't exist
        mkdir -p "$VAULT_PATH/.obsidian/snippets"

        # Template and deploy CSS snippet
        if [ -f "$TEMPLATE_DIR/snippets/cozette-font.css.template" ]; then
            sed -e "s/\${OBSIDIAN_FONT}/$OBSIDIAN_FONT/g" \
                -e "s/\${OBSIDIAN_FONT_SIZE}/$OBSIDIAN_FONT_SIZE/g" \
                -e "s/\${OBSIDIAN_HEADER_FONT_SIZE}/$OBSIDIAN_HEADER_FONT_SIZE/g" \
                "$TEMPLATE_DIR/snippets/cozette-font.css.template" > "$VAULT_PATH/.obsidian/snippets/cozette-font.css"
            echo "    ✓ CSS snippet deployed"
        fi

        # Template and deploy appearance.json (only if it doesn't exist or is a template)
        if [ -f "$TEMPLATE_DIR/appearance.json.template" ] && [ ! -f "$VAULT_PATH/.obsidian/appearance.json" ]; then
            sed -e "s/\${OBSIDIAN_FONT_SIZE}/$OBSIDIAN_FONT_SIZE/g" \
                "$TEMPLATE_DIR/appearance.json.template" > "$VAULT_PATH/.obsidian/appearance.json"
            echo "    ✓ appearance.json deployed"
        elif [ -f "$VAULT_PATH/.obsidian/appearance.json" ]; then
            # Update existing appearance.json to enable the snippet if not already enabled
            if ! jq -e '.enabledCssSnippets | contains(["cozette-font"])' "$VAULT_PATH/.obsidian/appearance.json" >/dev/null 2>&1; then
                jq '.enabledCssSnippets += ["cozette-font"]' "$VAULT_PATH/.obsidian/appearance.json" > "$VAULT_PATH/.obsidian/appearance.json.tmp"
                mv "$VAULT_PATH/.obsidian/appearance.json.tmp" "$VAULT_PATH/.obsidian/appearance.json"
                echo "    ✓ appearance.json updated (enabled CSS snippet)"
            fi
        fi
    else
        echo "  Warning: Vault path not found: $VAULT_PATH"
    fi
done <<< "$VAULTS"

echo "Obsidian configuration deployment complete!"
