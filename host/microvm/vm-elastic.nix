# Elastic CPU/RAM policy for microVMs: fluid resource scaling instead of a
# fixed hard allocation. Proven on lurking + comms in hydrix-config before
# promotion here - see hydrix-config's per-machine config for real-world
# per-VM values (memFloorMb/memLowFloorMb/cpuFloorPct/cpuLowFloorPct all
# need empirical tuning per profile, there's no universal default).
#
# Mechanism:
# - RAM: microvm.nix's per-VM current/bin/microvm-balloon <target-mb> script
#   (QMP "balloon", requires microvm.balloon = true, already on for all
#   profile VMs).
# - CPU: `systemctl set-property --runtime <unit> CPUQuota=<pct>%` on the
#   VM's own systemd unit. No vCPU hotplug exists under the "microvm" qemu
#   machine type (no ACPI), and a cgroup quota is fluid rather than a hard
#   allocation anyway - the guest never sees its vCPU count change.
# - Idle-absolute: zero Hyprland clients matching this VM's waypipe title
#   prefix -> immediate floor, no debounce.
# - Otherwise: guest CPU/RAM usage (from vm-metrics, vsock 14501) below
#   lowPct for lowDebounceTicks consecutive polls -> gradual step down
#   toward the low floor. Above highPct -> immediate step up to ceiling.
#   Between the two: hold.
#
# Deliberately separate from hydrix.microvmHost.balloonTrim: that's a coarse
# periodic timer (fixed percentage of declared ceiling, no window-awareness,
# no CPU management) meant as a lightweight safety net for VMs that don't
# opt into this. Both manipulate the same balloon, so don't enable both for
# the same VM - they'd fight each other.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.vmElastic;

  mkPollScript = name: vmCfg:
    pkgs.writeShellScript "vm-elastic-${name}" ''
      set -euo pipefail
      VM_DIR="/var/lib/microvms/${vmCfg.unitName}"
      UNIT="microvm@${vmCfg.unitName}.service"
      HOST_UID=$(id -u ${vmCfg.hostUsername})
      # Keyed by unitName (matches the vm_name field waybar's poller already
      # writes to its cache) so the display side can find this without any
      # separate name-mapping. This is the only place cur_mem is visible
      # from outside this process - vm-metrics' own rammb can't be used for
      # display, see the comment above the ram= computation below. Writes
      # "cur_mem ceiling_mb" so the display side can subtract out however
      # much the balloon has taken away and isolate real usage, rather than
      # showing raw allocation (which is a capacity number, not a usage
      # number - not what "VRAM" should mean here).
      STATE_FILE="/run/vm-elastic-mem-${vmCfg.unitName}"
      CEILING_MB=${toString vmCfg.memCeilingMb}

      mem_low_streak=0
      cpu_low_streak=0
      cur_mem=${toString vmCfg.memCeilingMb}
      cur_cpu=${toString vmCfg.cpuCeilingPct}
      confirmed_ready=0
      printf '%s %s\n' "$cur_mem" "$CEILING_MB" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

      # virtio-balloon does bounded work per request and then stops even if
      # the guest hasn't reached the target yet - it needs to be re-prompted
      # to keep converging, it won't grind toward an old target on its own.
      # So this always re-issues the request (cheap, and self-correcting) and
      # tracks cur_mem from the guest's own reported actual, not from what we
      # asked for, so the ramp math below stays honest about real state.
      # Always re-issues, even once converged: this is also our only way to
      # detect drift. deflateOnOOM can autonomously give memory back outside
      # this loop entirely if the guest signals real pressure - if we stop
      # asking once we think we're converged, we'd never notice and the
      # guest would just creep upward uncorrected.
      set_mem() {
        local target=$1
        local out
        out=$(cd "$VM_DIR" && ./current/bin/microvm-balloon "$target" 2>/dev/null) || return
        # "0" is a known spurious/flaky read from this script, never a real
        # value - no VM here is ever plausibly at 0MB, and cur_mem is used
        # as a divisor elsewhere, so treat it the same as an empty/non-numeric
        # read rather than accepting it.
        case "$out" in "" | "0" | *[!0-9]*) return ;; esac
        if [ "$out" != "$cur_mem" ]; then
          echo "vm-elastic-${name}: mem -> ''${out}MB (target ''${target}MB)"
          cur_mem=$out
          printf '%s %s\n' "$cur_mem" "$CEILING_MB" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
        fi
      }

      # Always re-issues, same reasoning as set_mem: cur_cpu starts as an
      # assumption (the declared ceiling), not a real read of the systemd
      # unit's actual CPUQuota. systemctl set-property --runtime persists
      # across daemon restarts, so if a previous incarnation left the real
      # quota throttled, a fresh daemon's very first "set_cpu ceiling" call
      # (during the confirmed_ready boot-hold) would silently no-op forever
      # against its own stale assumption - the real quota never gets
      # corrected until some other value happens to differ from that
      # assumption, which may never happen. Confirmed live: cur_cpu tracked
      # "200" from startup while the real CPUQuota stayed at a leftover 640ms
      # (64%) through an entire session, including multiple ticks where
      # guest cpu% crossed 90+ and should have forced ceiling.
      set_cpu() {
        local target=$1
        if systemctl set-property --runtime "$UNIT" CPUQuota="$target%" >/dev/null 2>&1; then
          [ "$target" != "$cur_cpu" ] && echo "vm-elastic-${name}: cpu -> ''${target}%"
          cur_cpu=$target
        fi
      }

      # A single balloon request under memory pressure often only makes
      # partial progress (virtio-balloon does bounded work per call, see
      # set_mem above). Retries with short sleeps instead of waiting for the
      # next normal poll tick, so real relief takes seconds, not tens of
      # seconds. A short retry budget isn't enough for a large jump (e.g.
      # 1.5GB -> 8GB ceiling) to actually complete - it would make partial
      # progress, run out of retries, and just stop at whatever intermediate
      # value it reached. That plateau then sits untouched (the ratio often
      # drops enough once partially inflated that "high" doesn't re-fire)
      # until idle-absolute pulls it back down again - a real, observed
      # failure mode ("climbs partway then plateaus") with too few retries.
      # 30 tries gives real room to reach the full target instead of an
      # arbitrary partial one.
      relieve_mem() {
        local target=$1
        local tries=0
        set_mem "$target"
        while [ "$cur_mem" -lt "$target" ] && [ "$tries" -lt 30 ]; do
          sleep 1
          set_mem "$target"
          tries=$((tries + 1))
        done
      }

      while true; do
        sleep ${toString vmCfg.pollIntervalSec}

        systemctl is-active --quiet "$UNIT" || { mem_low_streak=0; cpu_low_streak=0; confirmed_ready=0; continue; }

        # Hold ceiling unconditionally until waypipe has actually finished
        # connecting - gated on the real readiness signal (display-mode's
        # own STATUS, vsock 14509) instead of a guessed fixed duration. A
        # timed grace window gets this wrong in both directions: too short
        # for a genuinely slow boot (still strangles it mid-boot), and pure
        # elapsed-time keeps forcing the ceiling for the guessed duration
        # even on boots that are ready far sooner. This also covers
        # set-property --runtime persisting across restarts - a VM
        # restarted right after being throttled to the idle floor would
        # otherwise inherit that quota for its whole boot.
        #
        # Only actually query STATUS until confirmed_ready flips - waypipe's
        # own reconnection logic (waypipe-connect) hammers this exact port
        # hard during a restart (up to 30 retries of waypipe-reconnect plus
        # 15 of STATUS). Continuing to poll the same port every tick forever
        # would make this daemon an uninvited concurrent user of it for the
        # VM's entire lifetime, not just during boot.
        if [ "$confirmed_ready" = "0" ]; then
          dm_status=$(printf 'STATUS\n' | socat -T2 - VSOCK-CONNECT:${toString vmCfg.cid}:14509 2>/dev/null) || dm_status=""
          [ "$dm_status" = "waypipe" ] && confirmed_ready=1
        fi
        if [ "$confirmed_ready" = "0" ]; then
          mem_low_streak=0
          cpu_low_streak=0
          set_cpu ${toString vmCfg.cpuCeilingPct}
          relieve_mem ${toString vmCfg.memCeilingMb}
          continue
        fi

        metrics=$(echo all | socat -T2 - VSOCK-CONNECT:${toString vmCfg.cid}:14501 2>/dev/null) || continue
        cpu=$(printf '%s\n' "$metrics" | sed -n 's/^cpu=//p')
        rammb_now=$(printf '%s\n' "$metrics" | sed -n 's/^rammb=//p')
        # availmb is optional: older vm-metrics builds (guest not yet rebuilt
        # with this field) don't emit it. Only the new hard-floor check below
        # is skipped in that case - never block the whole tick on it, or
        # every VM's daemon would freeze in place until individually rebuilt.
        availmb_now=$(printf '%s\n' "$metrics" | sed -n 's/^availmb=//p')
        top=$(printf '%s\n' "$metrics" | sed -n 's/^top=\([^ ]*\).*/\1/p')
        [ -z "$cpu" ] && continue
        [ -z "$rammb_now" ] && continue
        case "$cpu$rammb_now" in *[!0-9]*) continue ;; esac
        case "$availmb_now" in *[!0-9]*) availmb_now="" ;; esac

        # Headroom (absolute MB), not a percentage: rammb_now / cur_mem
        # necessarily rises toward rammb_now / rammb_now = 100% as cur_mem
        # is squeezed down near the guest's real baseline usage, purely
        # mechanically, with zero change in actual memory pressure. For any
        # VM whose baseline sits at a non-trivial fraction of its floor
        # (comms: ~1.9GB baseline against a 2048MB low floor, from real
        # Signal/Firefox userland even with no window open), that made the
        # ratio permanently un-droppable below the low-band cutoff (stuck
        # ~22-23%, never <20%) while simultaneously making the high-band
        # cutoff fire on ordinary convergence, not genuine distress -
        # producing an endless sawtooth: descend from ratio math, then
        # immediately get yanked back to the ceiling by the same math one
        # tick later. Comparing an absolute MB margin against real usage
        # instead keeps both directions honest regardless of how close
        # cur_mem gets to actual baseline.
        headroom=$((cur_mem - rammb_now))
        [ "$headroom" -lt 0 ] && headroom=0

        # kswapd active in the guest means it's already fighting for memory -
        # a target being too aggressive for what this guest actually needs,
        # not something to keep pushing toward. Relieve immediately rather
        # than trust a static floor value can never be wrong.
        case "$top" in
          kswapd*)
            mem_low_streak=0
            cpu_low_streak=0
            # Restore CPU too, not just RAM: a throttled CPU quota starves
            # the guest's own reclaim work of the cycles it needs to
            # recover, which is what makes real distress slow to clear.
            set_cpu ${toString vmCfg.cpuCeilingPct}
            relieve_mem ${toString vmCfg.memCeilingMb}
            continue
            ;;
        esac

        # Second, independent safety net alongside kswapd: MemAvailable is a
        # real, reclaim-aware kernel estimate, unlike rammb (Active(anon)+
        # Inactive(anon)+Shmem) it doesn't ignore non-anon pinned memory
        # (kernel slab, actively-mapped binaries/libraries) - a guest can be
        # genuinely tight on those even while rammb looks perfectly flat.
        # Catches a tightening margin before the kernel is forced into
        # active reclaim, rather than only reacting once kswapd already
        # fired. Deliberately not the primary descent signal (see the
        # headroom comment above) - MemAvailable mechanically drops on every
        # balloon deflation same as the old MemTotal-MemAvailable formula
        # did, so using it continuously would reintroduce that exact
        # coupling. A hard floor, checked only for genuine low-margin
        # emergencies, doesn't have that problem.
        if [ -n "$availmb_now" ] && [ "$availmb_now" -lt ${toString vmCfg.memAvailableMinMb} ]; then
          mem_low_streak=0
          cpu_low_streak=0
          set_cpu ${toString vmCfg.cpuCeilingPct}
          relieve_mem ${toString vmCfg.memCeilingMb}
          continue
        fi

        # hyprctl needs both vars - XDG_RUNTIME_DIR alone isn't enough, it
        # fails outright without HYPRLAND_INSTANCE_SIGNATURE. Computed once
        # here, reused for both the workspace-active check below and the
        # windows count further down.
        HYPR_SIG=$(ls "/run/user/$HOST_UID/hypr/" 2>/dev/null | head -1) || HYPR_SIG=""

        # Being on this VM's workspace at all is a far earlier and cheaper
        # signal than waiting for measured CPU/RAM usage to climb - that only
        # happens once an app is already running and already struggling
        # under a throttled quota (measured live: a fresh app launch spent
        # several seconds capped before the daemon's own reactive checks
        # caught up, even at a 2s poll interval). Switching to the
        # workspace, even before any window has opened yet, holds ceiling
        # unconditionally - same priority as genuine load below.
        active_ws=$(runuser -u ${vmCfg.hostUsername} -- \
          env XDG_RUNTIME_DIR="/run/user/$HOST_UID" HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" hyprctl activeworkspace -j 2>/dev/null \
          | jq -r '.id' 2>/dev/null) || active_ws=""

        # High usage always wins, even with zero windows open - a VM can be
        # under real load (e.g. still booting, or a background task) despite
        # nothing being open yet. Checked before the idle-absolute branch
        # below so a "no windows" read can never starve genuine load.
        high=0
        if [ "$active_ws" = "${toString vmCfg.workspace}" ]; then
          mem_low_streak=0
          cpu_low_streak=0
          relieve_mem ${toString vmCfg.memCeilingMb}
          set_cpu ${toString vmCfg.cpuCeilingPct}
          high=1
        fi
        if [ "$headroom" -lt ${toString vmCfg.memHeadroomLowMb} ]; then
          mem_low_streak=0
          relieve_mem ${toString vmCfg.memCeilingMb}
          high=1
        fi
        if [ "$cpu" -gt ${toString vmCfg.highPct} ]; then
          cpu_low_streak=0
          set_cpu ${toString vmCfg.cpuCeilingPct}
          high=1
        fi
        [ "$high" = "1" ] && continue

        # Matching by the waypipe [name] title prefix (not workspace.id)
        # since the workspace can also hold unrelated host-side windows
        # (terminals, etc.) that would otherwise be mistaken for this VM
        # being in use.
        windows=$(runuser -u ${vmCfg.hostUsername} -- \
          env XDG_RUNTIME_DIR="/run/user/$HOST_UID" HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" hyprctl clients -j 2>/dev/null \
          | jq "[.[] | select(.title | startswith(\"${vmCfg.titlePrefix}\"))] | length" 2>/dev/null) || windows=""

        if [ "$windows" = "0" ]; then
          mem_low_streak=0
          cpu_low_streak=0

          # Step down gradually even here - starting immediately (no
          # debounce, "zero windows" is unambiguous) but never asking the
          # guest to give up several GB in one shot. An instant jump from
          # ceiling to floor can overwhelm the guest's reclaim path badly
          # enough to read as real distress and trigger a violent snap back.
          if [ "$cur_mem" -gt ${toString vmCfg.memFloorMb} ]; then
            mem_step=$(( (cur_mem - ${toString vmCfg.memFloorMb}) * ${toString vmCfg.stepPct} / 100 ))
            new_mem=$(( cur_mem - mem_step ))
            [ "$new_mem" -lt ${toString vmCfg.memFloorMb} ] && new_mem=${toString vmCfg.memFloorMb}
            set_mem "$new_mem"
          fi

          # Keep CPU at the less-aggressive floor until RAM has actually
          # settled, only dropping to the true minimum once there's nothing
          # left to reclaim. Dropping both at once can starve the guest of
          # the cycles it needs to process its own memory transition, badly
          # enough to make waypipe/display-mode stop answering entirely.
          mem_diff=$((cur_mem > ${toString vmCfg.memFloorMb} ? cur_mem - ${toString vmCfg.memFloorMb} : ${toString vmCfg.memFloorMb} - cur_mem))
          if [ "$mem_diff" -le 64 ]; then
            set_cpu ${toString vmCfg.cpuFloorPct}
          else
            set_cpu ${toString vmCfg.cpuLowFloorPct}
          fi
          continue
        fi

        # RAM and CPU are independent tracks: each reacts to its own usage
        # only, so e.g. an idle CPU doesn't block RAM from deflating while
        # RAM usage is still high, and vice versa. High-usage case is
        # already handled above, so only the low band is left to check here.
        if [ "$headroom" -gt ${toString vmCfg.memHeadroomHighMb} ]; then
          mem_low_streak=$((mem_low_streak + 1))
          if [ "$mem_low_streak" -ge ${toString vmCfg.lowDebounceTicks} ]; then
            mem_step=$(( (cur_mem - ${toString vmCfg.memLowFloorMb}) * ${toString vmCfg.stepPct} / 100 ))
            new_mem=$(( cur_mem - mem_step ))
            [ "$new_mem" -lt ${toString vmCfg.memLowFloorMb} ] && new_mem=${toString vmCfg.memLowFloorMb}
            set_mem "$new_mem"
          fi
        else
          mem_low_streak=0
        fi

        if [ "$cpu" -lt ${toString vmCfg.lowPct} ]; then
          cpu_low_streak=$((cpu_low_streak + 1))
          if [ "$cpu_low_streak" -ge ${toString vmCfg.lowDebounceTicks} ]; then
            cpu_step=$(( (cur_cpu - ${toString vmCfg.cpuLowFloorPct}) * ${toString vmCfg.stepPct} / 100 ))
            new_cpu=$(( cur_cpu - cpu_step ))
            [ "$new_cpu" -lt ${toString vmCfg.cpuLowFloorPct} ] && new_cpu=${toString vmCfg.cpuLowFloorPct}
            set_cpu "$new_cpu"
          fi
        else
          cpu_low_streak=0
        fi
      done
    '';

  vmSubmodule = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "elastic CPU/RAM scaling for this VM";

      unitName = lib.mkOption {
        type = lib.types.str;
        description = "Full microvm instance name, e.g. microvm-lurking-mb-ux5406sa (matches /var/lib/microvms/<name> and microvm@<name>.service).";
      };
      cid = lib.mkOption {
        type = lib.types.int;
        description = "vsock CID for vm-metrics (port 14501).";
      };
      titlePrefix = lib.mkOption {
        type = lib.types.str;
        description = "waypipe --title-prefix for this VM (e.g. \"[lurking]\"), used to tell a real forwarded window apart from unrelated host windows sharing the same workspace.";
      };
      workspace = lib.mkOption {
        type = lib.types.int;
        description = "This VM's assigned Hyprland workspace number. While it's the active workspace, resources are held at ceiling unconditionally - switching to a VM's workspace is a far earlier and cheaper signal of intent to use it than waiting for measured CPU/RAM usage to climb, which only happens after an app is already running (and struggling).";
      };
      hostUsername = lib.mkOption {
        type = lib.types.str;
        default = config.hydrix.username;
      };

      memCeilingMb = lib.mkOption {
        type = lib.types.int;
        description = "Matches this VM's declared hydrix.microvm.mem.";
      };
      memLowFloorMb = lib.mkOption {
        type = lib.types.int;
        description = "Resting point when usage is low but a window is open.";
      };
      memFloorMb = lib.mkOption {
        type = lib.types.int;
        description = "Absolute floor when no windows are open at all.";
      };
      memAvailableMinMb = lib.mkOption {
        type = lib.types.int;
        default = 512;
        description = "Hard safety floor on the guest's real MemAvailable (not rammb) - below this, relieve immediately regardless of what rammb/headroom says. Catches non-anon pinned memory (kernel slab, actively-mapped binaries) that rammb's anon+shmem total doesn't account for. Ignored (no effect) for guests running a vm-metrics build predating the availmb field.";
      };

      cpuCeilingPct = lib.mkOption {
        type = lib.types.int;
        description = "Matches this VM's declared vcpu count * 100.";
      };
      cpuLowFloorPct = lib.mkOption {type = lib.types.int;};
      cpuFloorPct = lib.mkOption {type = lib.types.int;};

      memHeadroomHighMb = lib.mkOption {
        type = lib.types.int;
        default = 768;
        description = "Safe to deflate further once (cur_mem - real usage) exceeds this many MB. Absolute margin, not a percentage - see the comment above the headroom computation for why a ratio breaks once cur_mem approaches a VM's real baseline usage.";
      };
      memHeadroomLowMb = lib.mkOption {
        type = lib.types.int;
        default = 256;
        description = "Genuine distress once (cur_mem - real usage) falls below this many MB - relieve back to the ceiling. Keep a gap above memHeadroomHighMb (hysteresis) so it doesn't fight itself right at the boundary.";
      };

      lowPct = lib.mkOption {
        type = lib.types.int;
        default = 20;
        description = "CPU-only low-usage cutoff (guest cpu= is a true percentage of quota, not subject to the same fixed-baseline problem as RAM).";
      };
      highPct = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "CPU-only high-usage cutoff.";
      };
      lowDebounceTicks = lib.mkOption {
        type = lib.types.int;
        default = 15;
        description = "Consecutive low samples required before starting to deflate. Scales with pollIntervalSec - default (15 * 2s = 30s) preserves the same real-world debounce as the original 3 * 10s, only the high-usage reaction time (unbounced) got faster.";
      };
      stepPct = lib.mkOption {
        type = lib.types.int;
        default = 20;
        description = "Percent of the remaining range to shed per tick while ramping down.";
      };
      pollIntervalSec = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "How often to poll guest CPU/RAM. This bounds high-usage reaction latency directly (no debounce on the way up) - a fresh app launch can run under the low floor for up to this long before the daemon notices and restores ceiling. Lowered from 10 to 2 specifically to fix that: a real app cold-start (e.g. a browser) was measurably slow under the old value since it spent its first several seconds throttled.";
      };
    };
  };
in {
  options.hydrix.vmElastic.vms = lib.mkOption {
    type = lib.types.attrsOf vmSubmodule;
    default = {};
    description = "Per-VM elastic CPU/RAM scaling policies (balloon + cgroup CPUQuota). Mutually exclusive with hydrix.microvmHost.balloonTrim for the same VM - both manipulate the same balloon device.";
  };

  config.systemd.services =
    lib.mapAttrs' (
      name: vmCfg:
        lib.nameValuePair "vm-elastic-${name}" (lib.mkIf vmCfg.enable {
          description = "Elastic CPU/RAM policy for ${vmCfg.unitName}";
          after = ["microvm@${vmCfg.unitName}.service"];
          wantedBy = ["multi-user.target"];
          path = [pkgs.socat pkgs.jq pkgs.util-linux pkgs.hyprland pkgs.systemd pkgs.coreutils];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${mkPollScript name vmCfg}";
            Restart = "always";
            RestartSec = 5;
          };
        })
    )
    cfg.vms;
}
