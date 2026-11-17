# Guest kernel hardening that needs no kernel compile. Everything here is a sysctl, a boot
# parameter or a systemd unit, so the stock nixpkgs kernel (from cache.nixos.org) stays in use
# and a change only rebuilds the runner. The compiled-in alternative (module signing, kernel
# lockdown) is modules/tier-kernels.nix, off by default because it means a local kernel build.
#
# Values are lib.mkDefault: a profile that needs something looser sets it with a plain
# assignment (pentest does, for ptrace, io_uring and the modules loaded before the lock).
#
# Sysctls apply on a live switch (shard -r). Boot parameters and the module lock apply on the
# next boot (shard -R).
{
  config,
  lib,
  ...
}: {
  options.hydrix.vmHardening.lockModules = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Stop all kernel module loading once boot has finished (kernel.modules_disabled=1, until
      the next boot). Stands in for module signature enforcement, which the stock kernel does
      not have: nothing can load, signed or not. Modules needed later (hotplugged devices,
      services started on demand) go in boot.kernelModules so they are loaded before the lock.
    '';
  };

  config = {
    boot.kernel.sysctl = {
      # Kernel pointers and the kernel log, root only
      "kernel.kptr_restrict" = lib.mkOverride 900 2;
      "kernel.dmesg_restrict" = lib.mkDefault 1;
      # No perf events for unprivileged users
      "kernel.perf_event_paranoid" = lib.mkDefault 2;
      # BPF: root only, permanently (2 would let root switch it back on), JIT constant blinding
      "kernel.unprivileged_bpf_disabled" = lib.mkDefault 1;
      "net.core.bpf_jit_harden" = lib.mkDefault 2;
      # ptrace: 2 = only root can attach to a process
      "kernel.yama.ptrace_scope" = lib.mkDefault 2;
      # io_uring: off for everyone, a frequent source of kernel exploits
      "kernel.io_uring_disabled" = lib.mkDefault 2;
      # No magic SysRq keys, no line disciplines loaded by unprivileged users, no
      # userfaultfd for unprivileged users (used to win kernel race conditions)
      "kernel.sysrq" = lib.mkOverride 900 0;
      "dev.tty.ldisc_autoload" = lib.mkDefault 0;
      "vm.unprivileged_userfaultfd" = lib.mkDefault 0;
      # Files in world-writable sticky directories (/tmp) and setuid core dumps
      "fs.protected_fifos" = lib.mkDefault 2;
      "fs.protected_regular" = lib.mkDefault 2;
      "fs.suid_dumpable" = lib.mkDefault 0;
    };

    # kexec_load_disabled=1 and nohibernate: the running kernel cannot be replaced without a reboot
    security.protectKernelImage = lib.mkDefault true;

    boot.kernelParams = [
      # Separate slab caches per type, so an overflow in one cannot reach another
      "slab_nomerge"
      # Zero memory on free as well as on allocation (the stock kernel already zeroes on alloc)
      "init_on_free=1"
      # Randomise the page allocator's free lists
      "page_alloc.shuffle=1"
      # No legacy vsyscall page at a fixed address
      "vsyscall=none"
      # No debugfs, which exposes kernel internals
      "debugfs=off"
    ];

    # With the lock, services that start after boot load their modules here instead.
    boot.kernelModules = lib.mkIf config.hydrix.vmHardening.lockModules (
      # Docker (also when started on demand): bridge networking, NAT (nft backend), overlay
      lib.optionals config.virtualisation.docker.enable [
        "bridge"
        "br_netfilter"
        "veth"
        "overlay"
        "nf_conntrack"
        "nf_nat"
        "nft_compat"
        "nft_chain_nat"
        "nft_masq"
        "nft_ct"
        "xt_MASQUERADE"
        "xt_conntrack"
        "xt_addrtype"
        "xt_nat"
        "xt_tcpudp"
        "xt_comment"
        "xt_multiport"
      ]
      # Tailscale: its tun device and the netfilter rules it adds once logged in
      ++ lib.optionals config.services.tailscale.enable [
        "tun"
        "nft_compat"
        "nft_chain_nat"
        "nft_masq"
        "xt_mark"
        "xt_connmark"
        "xt_conntrack"
        "xt_MASQUERADE"
        "xt_comment"
      ]
    );

    # Same as NixOS's security.lockKernelModules, without the boot.kernelModules entries it
    # adds for every fileSystems type: "tmpfs" (the root here) is not a module, so
    # systemd-modules-load would fail on it.
    systemd.services.disable-kernel-module-loading = lib.mkIf config.hydrix.vmHardening.lockModules {
      description = "Disable kernel module loading";
      wants = ["systemd-udevd.service"];
      wantedBy = [config.systemd.defaultUnit];
      after = [
        "firewall.service"
        "nftables.service"
        "systemd-modules-load.service"
        config.systemd.defaultUnit
      ];
      unitConfig.ConditionPathIsReadWrite = "/proc/sys/kernel";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutSec = 180;
      };
      script = ''
        ${config.systemd.package}/bin/udevadm settle
        echo -n 1 >/proc/sys/kernel/modules_disabled
      '';
    };
  };
}
