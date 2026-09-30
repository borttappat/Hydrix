# Builder VM user settings
# The builder VM gets internet through the router and mounts host /nix/store R/W.
# Add extra packages or config needed inside the builder here.
{ config, ... }: {
  # Share local flake inputs read-only at the same path, so offline builds
  # resolve e.g. hydrix.url = "path:/home/<user>/Hydrix" like the host does.
  # hydrix.builder.localInputs = [ "/home/${config.hydrix.builder.hostUsername}/Hydrix" ];
}
