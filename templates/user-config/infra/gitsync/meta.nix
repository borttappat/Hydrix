# Gitsync Infra VM - Metadata
#
# Infrastructure VM for pushing/pulling git repos from lockdown mode.
# Gets internet through the router via br-builder.
# Repos are mounted R/W from the host via virtiofs.
#
# CID 211 reserved for infrastructure use (2xx range)
{
  vsockCid  = 211;
  bridge    = "br-builder";
  tapId     = "mv-gitsync";
  tapMac    = "02:00:00:02:11:01";  # CID 211 - 100 = 111 = 0x6f... fixed MAC
  subnet    = "192.168.107";
  label     = "GITSYNC";

  tapBridges = {
    "mv-gitsync" = "br-builder";
  };
}
