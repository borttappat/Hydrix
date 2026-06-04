# Audio Configuration - Pipewire
{ config, pkgs, lib, ... }:

{
  # Pipewire
  security.rtkit.enable = lib.mkDefault true;

  services.pipewire = {
    enable        = lib.mkDefault true;
    alsa.enable   = lib.mkDefault true;
    alsa.support32Bit = lib.mkDefault true;
    pulse.enable  = lib.mkDefault true;
    wireplumber.enable = lib.mkDefault true;
  };

  # ALSA CLI tools (amixer, aplay, etc.)
  environment.systemPackages = [ pkgs.alsa-utils ];

  # Disable PulseAudio (using Pipewire instead)
  services.pulseaudio.enable = lib.mkDefault false;
}
