# Audio Configuration - Pipewire
{ config, pkgs, lib, ... }:

{
  # Pipewire
  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  # ALSA CLI tools (amixer, aplay, etc.)
  environment.systemPackages = [ pkgs.alsa-utils ];

  # Disable PulseAudio (using Pipewire instead)
  services.pulseaudio.enable = false;
}
