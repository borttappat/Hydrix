# USB Sandbox Infra VM - Metadata
#
# Infrastructure VM for safely handling USB storage devices.
# Ephemeral - no persistent storage, fresh state on each boot.
# Isolated: only reachable from files VM for secure file extraction.
#
# CID 209 reserved for infrastructure use (2xx range)
{
  vsockCid  = 209;
  bridge    = "br-usb-sandbox";
  tapId     = "mv-usb-sandbox";
  tapMac    = "02:00:00:02:6d:01";  # CID 209 - 100 = 109 = 0x6d
  # No routerTap - usb-sandbox uses a built-in subnet, isolated from router
  # Only files VM (via br-files bridge) can reach this VM
  subnet    = "192.168.209";  # /24 prefix - matches CID last octet
  label     = "USB SANDBOX";
  description = "Ephemeral VM for safe USB storage device handling";

  # TAP -> bridge mappings for host-side wiring
  # Main TAP on br-usb-sandbox. Files VM connects here via its own mv-files-usb TAP.
  # No second TAP needed — both VMs share the same bridge.
  tapBridges = {
    "mv-usb-sandbox" = "br-usb-sandbox";
  };
}
