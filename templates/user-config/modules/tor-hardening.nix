# Tor Hardening Module
#
# Architecture: HYBRID approach
#
# VM-SIDE (this module):
#   - Tor client configuration (bridges, transports)
#   - No swap/hibernate enforcement
#   - App-level anonymity (Firefox hardening, etc.)
#
# ROUTER-SIDE (separate module):
#   - Traffic padding (mask volume patterns)
#   - MAC randomization
#   - TCP fingerprint normalization
#   - Combined traffic blending across VMs
#
# This module is for VMs. Router hardening goes in modules/router-hardening.nix
#
# Usage in VM profile:
#   {
#     imports = [ ../../modules/tor-hardening.nix ];
#     hydrix.tor.hardening = {
#       enable = true;
#       level = "moderate";  # "minimal" | "moderate" | "paranoid"
#       bridgeType = "obfs4";
#     };
#   }
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.tor.hardening;

  # Bridge request helper - fetch bridges from torproject.org
  fetchBridges = ''
    # Request bridges from torproject.org via email
    # Run: fetch-tor-bridges <email>
    echo "To get Tor bridges:"
    echo "1. Send email to: getobfs4bridges@torproject.org"
    echo "2. Body should contain: obfs4"
    echo "3. You'll receive bridge lines like:"
    echo "   Bridge obfs4 IP:PORT CERT iat-mode=0"
    echo ""
    echo "For more options, see: https://bridges.torproject.org/"
  '';
in {
  config = lib.mkIf cfg.enable {
    # Tor bridge helper script + pluggable transport packages
    environment.systemPackages = with pkgs;
      [(writeShellScriptBin "fetch-tor-bridges" fetchBridges)]
      ++ lib.optionals (cfg.bridgeType != "none") (
        [torbridge]
        ++ lib.optionals (cfg.bridgeType == "obfs4") [obfs4proxy]
        ++ lib.optionals (cfg.bridgeType == "meek-azure") [meek]
        ++ lib.optionals (cfg.bridgeType == "snowflake") [snowflake]
      );

    # Configure Tor with hardening settings
    # Note: services.tor.client.enable already set in profile; we just add extra config
    environment.etc = lib.mkIf (cfg.bridgeType != "none" || cfg.customBridges != "") {
      "tor/bridgerc".source = pkgs.writeText "bridgerc" ''
        # Pluggable transport for censorship bypass
        ${
          if cfg.bridgeType == "obfs4"
          then ''
            ClientTransportPlugin obfs4 exec ${pkgs.obfs4proxy}/bin/obfs4proxy
          ''
          else if cfg.bridgeType == "meek-azure"
          then ''
            ClientTransportPlugin meek-azure exec ${pkgs.meek}/bin/meek-client
          ''
          else if cfg.bridgeType == "snowflake"
          then ''
            ClientTransportPlugin snowflake exec ${pkgs.snowflake}/bin/snowflake-client
          ''
          else ""
        }

        ${cfg.customBridges}
      '';
    };

    # Disable hibernation for memory forensics protection
    # Note: swapDevices = [ ] already in machines/mb-ux5406sa-hardware.nix
    systemd.sleep.extraConfig = ''
      # Disable hibernation - no swap devices configured
      Hibernate=false
      SuspendThenHibernate=false
    '';

    # Firefox hardening for anonymity.
    # Uses lib.mkDefault so it merges with firefox.nix's lib.mkDefault policies
    # (both at priority 1500 → attrsOf merges them) rather than clobbering
    # ExtensionSettings and other policies set there.
    programs.firefox = lib.mkIf (config.programs.firefox.enable) {
      policies = lib.mkDefault {
        DisableTelemetry = true;
        DisableFirefoxScreenshots = true;
        BlockAboutConfig = true;
      };
    };
  };
}
