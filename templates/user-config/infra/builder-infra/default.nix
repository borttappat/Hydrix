# Infra-tier builder settings.
# hostUsername, CID, TAP and storeTier are passed via mkMicrovmBuilder in flake.nix.
# No hydrix-config or Hydrix share: the host evaluates and exports the derivations, and this
# builder only builds them into the infra store (BUILDDRV). It substitutes from the host's
# cache (/var/lib/hydrix/caches/host, read-only, unsigned and trusted) and cache.nixos.org.
_: {}
