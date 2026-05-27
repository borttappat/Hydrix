# Vault Infra VM — Metadata
#
# Holds KeepassXC DB in a virtiofs-backed host directory.
# No network interface — fully offline (credentials cannot be exfiltrated).
# Syncs via gitsync VM triggered host-side (gitsync already has vault in its repo list).
#
# vsock port 14514: PING/UNLOCK/LOCK/STATUS/LIST/GET
# CID 213 — gap between files (212) and hostsync (214), reserved 2xx infra range.
{
  vsockCid   = 213;
  hasDisplay = false;
  subnet     = "192.168.213"; # for vm-registry lookup; no actual TAP/bridge
  label      = "VAULT";
  # No bridge, tapId, tapMac, tapBridges, routerTap — offline VM
}
