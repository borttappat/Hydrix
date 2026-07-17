#                        __                           __
#.-----.-----.----.--.--|__.----.-----.-----.  .-----|__.--.--.
#|__ --|  -__|   _|  |  |  |  __|  -__|__ --|__|     |  |_   _|
#|_____|_____|__|  \___/|__|____|_____|_____|__|__|__|__|__.__|
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;
in {
  programs.dconf.enable = lib.mkDefault true;

  # NetworkManager configuration
  systemd.services.NetworkManager-wait-online = {
    enable = lib.mkDefault false;
  };

  networking = {
    networkmanager = {
      enable = lib.mkDefault true;
    };
  };

  # avoid issues with #/bin/bash scripts and alike
  services.envfs.enable = lib.mkDefault true;

  # ollama, LLM (disabled - testing in VM instead)
  # services.ollama.enable = true;

  # udisksctl
  services.udisks2.enable = lib.mkDefault true; #added with udisks in packages.nix

  # Lid and suspend/resume settings
  services.logind.settings.Login = {
    HandleLidSwitch = lib.mkDefault "suspend"; # Suspend on lid close (default)
    HandleLidSwitchExternalPower = lib.mkDefault "ignore"; # Ignore when on AC power
    HandleLidSwitchDocked = lib.mkDefault "ignore"; # Ignore when docked/external display
  };

  # Rsync (disabled - not needed on host)
  # services.rsyncd.enable = true;

  # Enable touchpad support
  services.libinput.enable = lib.mkIf cfg.hardware.touchpad.enable true;

  # MySQL
  /*
  services.mysql = {
      enable = true;
      package = pkgs.mariadb;
  };
  */

  # Enabling auto-cpufreq
  services.auto-cpufreq.enable = lib.mkIf cfg.power.autoCpuFreq true;

  # Intel-undervolt
  #services.undervolt.enable = true;

  # SSH: disabled globally in shared/core — enable per machine with services.openssh.enable = true

  # Enabling tailscale VPN
  services.tailscale.enable = lib.mkIf cfg.services.tailscale.enable true;

  # Tailscale caches its DNS upstream on route changes; wait for the bridge's
  # own address service too, not just resolvconf (rebuild also force-restarts
  # tailscaled post-activation as a backstop — see post_build in scripts/rebuild).
  systemd.services.tailscaled = lib.mkIf cfg.services.tailscale.enable {
    after = [ "resolvconf.service" "network-addresses-br-mgmt.service" ];
    restartTriggers = [ (toString config.networking.nameservers) ];
  };

  # Enable i2c-bus
  hardware.i2c.enable = lib.mkIf cfg.hardware.i2c.enable true;

  # Bluetooth (host only - VMs don't import services.nix)
  hardware.bluetooth = lib.mkIf cfg.hardware.bluetooth.enable {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
      };
    };
  };
  services.blueman.enable = lib.mkIf cfg.hardware.bluetooth.enable true;

  # Undervolt
  # services.undervolt = {
  #     enable = false;
  #     coreOffset = -80;
  # };
}
