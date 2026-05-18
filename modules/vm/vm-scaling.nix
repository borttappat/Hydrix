# VM Scaling Module - Dynamic scaling from host's scaling.json
#
# This module ensures VMs use the same font sizes and scaling as the host.
# It reads from /mnt/hydrix-config/scaling.json (mounted from host).
#
# Provides:
#   - Wrapper scripts for apps that need DPI-aware launching (firefox, rofi, obsidian)
#   - Environment variables for xpra service (optional, for libvirt VMs)
#   - Shell aliases as backup mechanism
#   - Helper script to verify scaling configuration
#
# NOTE: Alacritty font scaling for xpra is handled HOST-SIDE in xpra-host.nix.
# The vm-app script reads scaling.json and applies xpra_font_offset when
# launching alacritty via xpra. This is simpler than VM-side wrappers.
#
# For microVMs: set hydrix.vmScaling.configureXpraService = false since
# microvm-xpra-guest.nix defines its own xpra-vsock service.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  scalingCfg = config.hydrix.vmScaling;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType or null;
  isVM = vmType != null && vmType != "host";

  # Path to scaling.json (via symlink or direct mount)
  scalingJsonPaths = ''
    SCALING_JSON="$HOME/.config/hydrix/scaling.json"
    SCALING_JSON_VM="/mnt/hydrix-config/scaling.json"

    # Find scaling.json (prefer home config which may be symlinked to mount)
    if [ -f "$SCALING_JSON" ]; then
        json_path="$SCALING_JSON"
    elif [ -f "$SCALING_JSON_VM" ]; then
        json_path="$SCALING_JSON_VM"
    else
        json_path=""
    fi
  '';

  # Alacritty wrapper - reads font size from scaling.json
  # NOTE: For xpra, font adjustment is handled host-side in vm-app (xpra-host.nix)
  # This wrapper is for direct VM access (VNC, virt-viewer, etc.)
  alacrittyWrapper = pkgs.writeShellScriptBin "alacritty-scaled" ''
    ${scalingJsonPaths}

    if [ -n "$json_path" ]; then
        font_size=$(${pkgs.jq}/bin/jq -r '.fonts.alacritty // 10' "$json_path" 2>/dev/null)
        font_name=$(${pkgs.jq}/bin/jq -r '.font_name // "${cfg.font.family}"' "$json_path" 2>/dev/null)
    else
        font_size=10
        font_name="${cfg.font.family}"
    fi

    # WINIT_X11_SCALE_FACTOR=1 prevents alacritty from doing its own DPI scaling
    exec env WINIT_X11_SCALE_FACTOR=1 ${pkgs.alacritty}/bin/alacritty \
        -o "font.size=$font_size" \
        -o "font.normal.family=\"$font_name\"" \
        "$@"
  '';

  # Rofi wrapper - sets font from scaling.json
  rofiWrapper = pkgs.writeShellScriptBin "rofi-scaled" ''
    ${scalingJsonPaths}

    rofi_args=("$@")

    if [ -n "$json_path" ]; then
        font_size=$(${pkgs.jq}/bin/jq -r '.fonts.rofi // 12' "$json_path" 2>/dev/null)
        font_name=$(${pkgs.jq}/bin/jq -r '.font_name // "${cfg.font.family}"' "$json_path" 2>/dev/null)
        # Add font override unless user specified their own
        if [[ ! " $* " =~ " -font " ]]; then
            rofi_args+=(-font "$font_name $font_size")
        fi
    fi

    exec ${pkgs.rofi}/bin/rofi "''${rofi_args[@]}"
  '';

  # Obsidian wrapper - Electron app, needs --force-device-scale-factor
  obsidianWrapper = pkgs.writeShellScriptBin "obsidian-scaled" ''
    ${scalingJsonPaths}

    obsidian_args=("$@")

    if [ -n "$json_path" ]; then
        scale_factor=$(${pkgs.jq}/bin/jq -r '.scale_factor // 1' "$json_path" 2>/dev/null)
        # Electron apps use --force-device-scale-factor for scaling
        obsidian_args+=(--force-device-scale-factor="$scale_factor")
    fi

    exec ${pkgs.obsidian}/bin/obsidian "''${obsidian_args[@]}"
  '';

  # Generic GTK app wrapper - reads scale factor and sets GDK_DPI_SCALE
  gtkAppWrapper = name: binary: pkgs.writeShellScriptBin "${name}-scaled" ''
    ${scalingJsonPaths}

    if [ -n "$json_path" ]; then
        scale_factor=$(${pkgs.jq}/bin/jq -r '.scale_factor // 1' "$json_path" 2>/dev/null)
        export GDK_DPI_SCALE="$scale_factor"
    fi

    exec ${binary} "$@"
  '';

  # Helper script to show current scaling values
  scalingInfo = pkgs.writeShellScriptBin "vm-scaling-info" ''
    ${scalingJsonPaths}

    if [ -z "$json_path" ]; then
        echo "ERROR: scaling.json not found"
        echo "Checked:"
        echo "  $SCALING_JSON"
        echo "  $SCALING_JSON_VM"
        echo ""
        echo "Is the hydrix-config mount working?"
        echo "  ls -la /mnt/hydrix-config/"
        echo "  ls -la ~/.config/hydrix/"
        exit 1
    fi

    echo "Using: $json_path"
    echo ""
    echo "=== Scaling Values ==="
    ${pkgs.jq}/bin/jq '.' "$json_path"
  '';

in {
  options.hydrix.vmScaling = {
    configureXpraService = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to configure the xpra-vsock systemd service with scaling environment.
        Set to false for microVMs which define their own xpra service in microvm-xpra-guest.nix.
      '';
    };
  };

  config = lib.mkIf (isVM && cfg.enable) {
    # Add wrapper scripts and dependencies
    environment.systemPackages = [
      alacrittyWrapper
      rofiWrapper
      obsidianWrapper
      scalingInfo
      pkgs.jq  # Required for scaling.json parsing
    ];

    # Configure xpra service environment (only for libvirt VMs, not microVMs)
    # Sets baseline env vars; wrappers provide dynamic per-app values
    # The `path` attribute prepends /usr/local/bin to PATH so wrappers are found first
    systemd.user.services.xpra-vsock = lib.mkIf scalingCfg.configureXpraService {
      path = lib.mkBefore [ "/usr/local/bin" ];
      environment = {
        GDK_DPI_SCALE = "1.0";
        QT_SCALE_FACTOR = "1.0";
        WINIT_X11_SCALE_FACTOR = "1";  # Disable winit auto-scaling globally
      };
    };

    # Shell aliases to redirect app commands to scaled wrappers
    # This ensures 'alacritty' actually runs 'alacritty-scaled'
    environment.shellAliases = {
      alacritty = "alacritty-scaled";
      rofi = "rofi-scaled";
      obsidian = "obsidian-scaled";
    };
  };
}
