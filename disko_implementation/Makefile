# Makefile - Convenience commands for NixOS management

.PHONY: help build-iso flash-iso rebuild update clean test

help:
	@echo "NixOS Configuration Management"
	@echo ""
	@echo "Available targets:"
	@echo "  build-iso     - Build custom installer ISO"
	@echo "  flash-iso     - Flash ISO to USB (requires DEVICE=/dev/sdX)"
	@echo "  rebuild       - Rebuild current system"
	@echo "  update        - Update flake inputs"
	@echo "  clean         - Clean build artifacts"
	@echo "  test          - Test configuration without rebuilding"
	@echo "  vm-manager    - Install VM management helper"
	@echo ""
	@echo "Examples:"
	@echo "  make build-iso"
	@echo "  make flash-iso DEVICE=/dev/sdb"
	@echo "  make rebuild"

build-iso:
	@echo "Building custom installer ISO..."
	nix build .#installer-iso
	@echo ""
	@echo "ISO built successfully!"
	@ls -lh result/iso/*.iso

flash-iso:
ifndef DEVICE
	@echo "Error: DEVICE not specified"
	@echo "Usage: make flash-iso DEVICE=/dev/sdX"
	@exit 1
endif
	@echo "WARNING: This will erase all data on $(DEVICE)"
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@echo "Flashing ISO to $(DEVICE)..."
	sudo dd if=$$(ls result/iso/*.iso | head -n1) of=$(DEVICE) bs=4M status=progress oflag=sync
	@echo "Done! You can now boot from $(DEVICE)"

rebuild:
	@echo "Rebuilding NixOS configuration..."
	sudo nixos-rebuild switch --flake .#$$(hostname)

test:
	@echo "Testing configuration (no activation)..."
	nixos-rebuild test --flake .#$$(hostname)

update:
	@echo "Updating flake inputs..."
	nix flake update
	@echo "Updated. Run 'make rebuild' to apply changes."

clean:
	@echo "Cleaning build artifacts..."
	rm -rf result
	nix-collect-garbage -d
	@echo "Cleaned."

vm-manager:
	@echo "Installing VM manager helper..."
	@mkdir -p ~/.local/bin
	@cp vm-manager.fish ~/.local/bin/vm-manager
	@chmod +x ~/.local/bin/vm-manager
	@echo "Installed to ~/.local/bin/vm-manager"
	@echo "Add to your PATH or run directly"

check:
	@echo "Checking flake..."
	nix flake check

fmt:
	@echo "Formatting Nix files..."
	nix fmt

# Advanced: Build for specific host
build-host:
ifndef HOST
	@echo "Error: HOST not specified"
	@echo "Usage: make build-host HOST=hostname"
	@exit 1
endif
	@echo "Building configuration for $(HOST)..."
	nixos-rebuild build --flake .#$(HOST)
