# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').

{ config, pkgs, pkgs-unstable, lib, nixos-hardware, nixpkgs, nixpkgs-unstable, nixpkgs-jzila, ... }:

{
  imports =
    [
      # Base image for GA402
      nixos-hardware.nixosModules.asus-zephyrus-ga402
      # Shared desktop configuration
      ../../modules/desktop/aliza.nix
    ];

  # ASUS Zephyrus specific configurations
  nixpkgs.config.rocmSupport = true;

  # ASUS Zephyrus specific boot configuration
  boot = {
    kernelParams = [];
    extraModprobeConfig = ''
      options amdgpu cwsr_enable=0
    '';
  };

  # Venator specific networking
  networking = {
    hostName = "venator";
    extraHosts = ''
      127.0.0.1 manuscripts.localhost
    '';
  };

  containers = (import ../../modules/ollama.nix {
    nixpkgs = nixpkgs-jzila;
    inherit lib;
    devices = [
      "/dev/kfd"
      "/dev/dri/card1"      # Discrete GPU (RX 6650 XT/6700S/6800S)
      "/dev/dri/renderD128" # Discrete GPU render node
    ];
  }).containers;


  # ASUS Zephyrus video drivers
  services.xserver.videoDrivers = [ "amdgpu" ];


  # ASUS Zephyrus graphics hardware acceleration
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = [
    pkgs-unstable.amdvlk
    pkgs.rocmPackages.clr.icd
  ];
  hardware.graphics.extraPackages32 = [
    pkgs-unstable.driversi686Linux.amdvlk
  ];


  # Venator specific security wrapper ownership
  security.wrappers.keybase-redirector.owner = "john";
  security.wrappers.keybase-redirector.group = "users";

  # Define a user account. Don't forget to set a password with 'passwd'.
  users.users.john = {
    isNormalUser = true;
    description = "John Zila";
    extraGroups = [
      "networkmanager"
      "wheel"
      "plugdev"
      "scanner"
      "lp"
      "dialout"
    ];
    packages = with pkgs; [
      firefox
      bitwarden
      yubioath-flutter
      alacritty
    ];
    useDefaultShell = true;
  };




  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";

      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 100;
      CPU_MIN_PERF_ON_BAT = 0;
      CPU_MAX_PERF_ON_BAT = 30;

      START_CHARGE_THRESH_BAT0 = 50;
      STOP_CHARGE_THRESH_BAT0 = 80;
    };
  };


  # Venator specific Tailscale configuration
  services.tailscale.extraUpFlags = [
    "--operator=john"
  ];

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
