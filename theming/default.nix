# Theming Modules - Graphical environment, window managers, colorschemes
#
# Entry point for all theming and UI modules.
# Options are in theming/options.nix (imported separately by lib/default.nix).
{ ... }:

{
  imports = [
    ./graphical
  ];
}
