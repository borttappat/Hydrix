# Mullvad VPN Configuration
#
# Each profile VM can route through a different Mullvad exit node.
# The router VM manages all WireGuard tunnels and per-bridge routing.
#
# SETUP:
#   1. Log into https://mullvad.net -> Account -> WireGuard configuration
#   2. Select a country/city/server -> download the .conf file
#   3. Place downloaded files in ~/hydrix-config/vpn/:
#        vpn/mullvad-browsing.conf   <- exit node for browsing VM
#        vpn/mullvad-pentest.conf    <- exit node for pentest VM
#        vpn/mullvad-comms.conf      <- exit node for comms VM
#   4. Uncomment the bridges below, mapping each to its .conf file
#   5. Set enable = true
#   6. Rebuild the router:
#        microvm build microvm-router && microvm restart microvm-router
#
# Each bridge can use a DIFFERENT exit node (different country/server per VM).
# Download one .conf per VM from Mullvad — they can share the same key pair.
# Table = off, IPv6, and DNS lines are automatically stripped at build time
# (configured via hydrix.router.vpn.mullvad.processConfig in infra/router/).
#
# RUNTIME MANAGEMENT (from router console, no rebuild needed):
#   vpn-assign status                       # Show all bridge assignments
#   vpn-assign browsing direct              # Bypass VPN for browsing VM
#   vpn-assign browsing wg-browsing         # Re-enable VPN for browsing VM
#   vpn-assign --persistent pentest direct  # Persist across reboots
#   vpn-assign list-mullvad                 # List configured exit nodes
#
# Valid bridge names match your profile names: browsing, pentest, comms, dev, lurking
# Bridges omitted from the map go direct (no VPN, no kill switch).
{
  enable = false;

  bridges = {
    # browsing = ./mullvad-browsing.conf;
    # pentest  = ./mullvad-pentest.conf;
    # comms    = ./mullvad-comms.conf;
    # lurking  = ./mullvad-lurking.conf;
    # dev      = ./mullvad-dev.conf;
  };
}
