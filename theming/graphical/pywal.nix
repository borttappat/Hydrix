# pywal pin, fast backend and scheme precache (hydrix.graphical.pywal.*)
#
# pin: pkgs.pywal becomes pywal 3.3.0 from the `nixpkgs-pywal` input. pywal16,
# which current nixpkgs ships, forces HLS saturation onto any extracted
# background with every channel below 0x10 and derives color7/color8 from the
# result, so near-black wallpapers get a visible tint. No CLI flag undoes it
# for both color0 and color8. pywal-fast-backend.py is appended to 3.3.0's
# `wal` backend: same ImageMagick calls, less repeated work, same palettes.
#
# precache: a user service fills ~/.cache/wal/schemes for the wallpaper
# directories, so `wal -i` finds a palette instead of extracting one. It uses
# 3.3.0's cache naming and colors.get() signature, hence the pin requirement.
# Type is exec, not oneshot: home-manager activation waits for started units
# to finish starting, which a oneshot only does once every image is done.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.hydrix.graphical.pywal;
  username = config.hydrix.username;
  isHost = (config.hydrix.vmType or null) == "host";

  pinned = import inputs.nixpkgs-pywal {inherit (pkgs.stdenv.hostPlatform) system;};
  pywalModule = pinned.python3Packages.pywal.overridePythonAttrs (old: {
    postPatch =
      old.postPatch
      + ''
        cat ${./pywal-fast-backend.py} >> pywal/backends/wal.py
      '';
  });

  precache = pkgs.writeShellScript "pywal-precache" ''
    exec ${pinned.python3.withPackages (_: [pywalModule])}/bin/python3 ${./pywal-precache.py} ${lib.escapeShellArgs cfg.precache.directories}
  '';
in {
  config = lib.mkIf (config.hydrix.graphical.enable && isHost) (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.precache.enable -> cfg.pin.enable;
          message = "hydrix.graphical.pywal.precache.enable requires hydrix.graphical.pywal.pin.enable (it uses pywal 3.3.0's cache layout).";
        }
      ];
    }

    (lib.mkIf cfg.pin.enable {
      nixpkgs.overlays = [(_: _: {pywal = pinned.python3Packages.toPythonApplication pywalModule;})];
    })

    (lib.mkIf (cfg.precache.enable && cfg.pin.enable) {
      home-manager.users.${username} = {
        systemd.user.services.pywal-precache = {
          Unit.Description = "Pre-generate pywal palettes for wallpapers";
          Service = {
            Type = "exec";
            ExecStart = "${precache}";
            Nice = 19;
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
          };
          Install.WantedBy = ["graphical-session.target"];
        };

        systemd.user.paths.pywal-precache = {
          Unit.Description = "Watch wallpaper directories for pywal pre-caching";
          Path.PathChanged = cfg.precache.directories;
          Install.WantedBy = ["paths.target"];
        };
      };
    })
  ]);
}
