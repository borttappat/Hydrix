# Task slots: generic, reusable VMs that engagements are bound to at runtime
# (shard pentest task1 <name>). Slots are built from this single block, see
# slots.nix for what each slot is expanded into.
#
# Slot N gets CID = subnet octet = baseCid + N - 1 and its own bridge
# br-taskN / subnet 192.168.<cid>.0/24, so the router isolates every slot from
# every other VM network. Changing count or baseCid needs a `rebuild` and a
# router build + restart (shard -bR router) to create the new bridges and subnets.
{
  count = 3; # task1..task3, max 9
  baseCid = 115; # task1 = 115, task2 = 116, task3 = 117
  profile = "pentest"; # base profile every slot builds on (workspace/border follow it)
  secrets = []; # hydrix secrets delivered to every slot, e.g. ["burp"]

  # Applied to every slot's NixOS config.
  module = {lib, ...}: {
    hydrix.microvm = {
      persistence.homeSize = 20480; # 20GB, smaller than pentest's 100GB
      encryption.enable = true; # engagement data is sensitive
    };
    # Inconspicuous hostname; mkForce because the pentest profile sets it plainly.
    # hydrix.vm.hostname = lib.mkForce "Win-aabbcc1122";
  };

  # Per-slot additions, merged after `module`:
  # overrides.task2 = {hydrix.microvm.persistence.homeSize = 51200;};
  overrides = {};
}
