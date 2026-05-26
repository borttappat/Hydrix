# Comms Profile Packages
#
# Minimal communication toolkit.
# Core VM packages are in shared/vm-packages.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Chat client (Signal only) — wrapped to force native Wayland (waypipe requires it)
    (symlinkJoin {
      name = "signal-desktop";
      paths = [ signal-desktop ];
      buildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/signal-desktop \
          --add-flags "--ozone-platform=wayland"
      '';
    })

    # Web browser for web-based comms (fallback)
    firefox

    # TUI file manager (for attachments)
    ranger

    # Archive tools
    unzip
    p7zip
  ];
}
