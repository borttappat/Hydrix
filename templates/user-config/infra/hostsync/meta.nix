# Hostsync infra VM — secure host file inbox
# CID 214, subnet 192.168.109.x — reserved, never use for profile VMs
#
# Receives encrypted files from the files VM via bridge delivery,
# decrypts them into a virtiofs-shared directory (~/vm-inbox on host).
# No internet access — isolated to the hostsync bridge only.
{
  vsockCid = 214;
  subnet   = "192.168.214";
  tapId    = "mv-hostsync";
  tapMac   = "02:00:00:02:d6:01";  # CID 214 = 0xd6
  label    = "HOSTSYNC";

  # No routerTap — hostsync never needs internet routing.
  # Only the files VM bridge (br-hostsync) is needed.
  tapBridges = {
    "mv-hostsync" = "br-hostsync";
  };
}
