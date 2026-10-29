# Mullvad VPN Configuration
#
# Each profile VM can route through a different Mullvad exit node.
# The router VM manages all WireGuard tunnels and per-network routing.
#
# Only the network names live here. The .conf files hold private keys, so they
# never enter the Nix store (every VM sharing the host store could read them):
# they live in secrets/mullvad.yaml (sops), one key per network, the conf text
# as its value, delivered to the router at boot.
#
# SETUP:
#   1. Log into https://mullvad.net -> Account -> WireGuard configuration
#   2. Select a country/city/server -> download one .conf per network
#   3. Put the confs in secrets/mullvad.yaml:
#        sops secrets/mullvad.yaml
#          browsing: |
#            # Server: se-got-wg-001
#            [Interface]
#            PrivateKey = ...
#      (setup-mullvad-secrets does this from conf files and a bridges map, then
#      delete the plaintext confs)
#   4. List the networks below and set enable = true
#   5. In machines/<serial>.nix:
#        hydrix.secrets.mullvadSecretsFile = ../secrets/mullvad.yaml;
#        and "mullvad" in hydrix.microvmHost.byName.router.secrets
#   6. rebuild, then shard -bR router
#
# Each network can use a DIFFERENT exit node (different country/server per VM).
# Table = off, IPv6 and DNS lines are stripped on the router at boot
# (hydrix.router.vpn.mullvad.processScript in infra/router/). A "# Server:"
# line names the exit node in the exit-nodes widget.
#
# RUNTIME MANAGEMENT (from router console, no rebuild needed):
#   vpn-assign status                       # Show all network assignments
#   vpn-assign browsing direct              # Bypass VPN for browsing VM
#   vpn-assign browsing wg-browsing         # Re-enable VPN for browsing VM
#   vpn-assign browsing blocked             # Kill switch
# Runtime assignments last until the router restarts; networks below are the boot default.
#   vpn-assign list-mullvad                 # List configured exit nodes
#
# Valid network names match your profile names: browsing, pentest, comms, dev, lurking
# Networks not listed go direct (no VPN, no kill switch). A listed network whose
# conf is missing stays blocked.
{
  enable = false;

  networks = [
    # "browsing"
    # "pentest"
    # "comms"
  ];
}
