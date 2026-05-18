# Xpra Apps Module - GUI app theming integration for MicroVM xpra forwarding
#
# GUI apps (alacritty, firefox, obsidian) are configured in the user's
# hydrix-config/shared/vm-packages.nix.
#
# This module provides only the pywal colorscheme integration (plumbing).
#
{ config, pkgs, lib, ... }:

{
  # Pywal sequences removed - VMs use alacritty's live_config_reload via
  # colors-runtime.toml (written by write-alacritty-colors on vsock push).
  # This eliminates the color flash when opening new terminals.
}
