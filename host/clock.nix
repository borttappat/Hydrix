# Host clock floor
#
# Early in boot systemd moves a clock that reads older than the last known time
# forward to the mtime of /var/lib/systemd/timesync/clock (what timesyncd saved last).
# A hardware clock (RTC) driver that loads later, acpi-tad on some laptops, then
# registers as rtc0 and the kernel sets the system time from it once more: after a
# dead CMOS battery, back to the firmware's default date, years off. Offline (lockdown)
# nothing corrects that. It hides the whole fish history, among other things: fish
# loads only entries older than the shell's start (hydrix-config
# investigations/fish-history-clock).
#
# hydrix-clock-floor runs whenever an RTC device appears and once at boot: when the
# clock reads older than the saved time it moves it forward to that time and writes the
# RTC, so the next boot starts there too. It only ever moves the clock forward.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.clock.floor;

  floorScript = pkgs.writeShellScript "hydrix-clock-floor" ''
    set -u
    saved=/var/lib/systemd/timesync/clock
    [ -e "$saved" ] || exit 0
    floor=$(${pkgs.coreutils}/bin/stat -c %Y "$saved")
    now=$(${pkgs.coreutils}/bin/date +%s)
    [ "$now" -ge "$floor" ] && exit 0
    ${pkgs.coreutils}/bin/date -s "@$floor" > /dev/null
    echo "Clock read $(${pkgs.coreutils}/bin/date -u -d "@$now" +%FT%TZ), moved forward to the last known time $(${pkgs.coreutils}/bin/date -u -d "@$floor" +%FT%TZ)"
    ${pkgs.util-linux}/bin/hwclock --systohc --utc || echo "Writing the RTC failed"
  '';
in {
  options.hydrix.clock.floor.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.hydrix.vmType == "host";
    description = ''
      Keep the host clock from going back past the last known time (timesyncd's saved
      clock) when an RTC driver that loads late resets it, as after a dead CMOS battery.
      Moves the clock forward only, and writes the RTC when it does.
    '';
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hydrix-clock-floor = {
      description = "Move the clock forward to the last known time";
      wantedBy = ["sysinit.target"];
      after = ["systemd-modules-load.service" "local-fs.target"];
      before = ["shutdown.target"];
      conflicts = ["shutdown.target"];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/var/lib/systemd";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = floorScript;
      };
    };

    # The kernel sets the time from an RTC as it registers (rtc0): check right after.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="rtc", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hydrix-clock-floor.service"
    '';
  };
}
