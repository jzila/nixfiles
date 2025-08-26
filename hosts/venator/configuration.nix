# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').

{ config, pkgs, pkgs-unstable, lib, nixos-hardware, nixpkgs, nixpkgs-unstable, ... }:

{
  imports =
    [
      # Base image for GA402
      nixos-hardware.nixosModules.asus-zephyrus-ga402
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.rocmSupport = true;

  # Bootloader.
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [];
    extraModprobeConfig = ''
      options amdgpu cwsr_enable=0
    '';
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      grub.memtest86.enable = true;
      systemd-boot.memtest86.enable = true;
    };
    binfmt.registrations.appimage = {
      wrapInterpreterInShell = false;
      interpreter = "${pkgs.appimage-run}/bin/appimage-run";
      recognitionType = "magic";
      offset = 0;
      mask = ''\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff'';
      magicOrExtension = ''\x7fELF....AI\x02'';
    };
  };

  # Configure network proxy if necessary

  # Configure networking
  networking = {
    hostName = "venator";
    networkmanager.enable = true;
    # wireless.enable = true;  # Enables wireless support via wpa_supplicant.
    # proxy.default = "http://user:password@proxy:port/";
    # proxy.noProxy = "127.0.0.1,localhost,internal.domain";

    firewall = {
      allowedTCPPorts = [
        # development
        3000
        3001
      ];
    };

    extraHosts = ''
      127.0.0.1 manuscripts.localhost
    '';
    # Open ports in the firewall.
    # networking.firewall.allowedTCPPorts = [ ... ];
    # networking.firewall.allowedUDPPorts = [ ... ];
    # Or disable the firewall altogether.
    # networking.firewall.enable = false;

  };

  # Enable containers
  virtualisation.containers.enable = true;
  virtualisation = {
    podman = {
      enable = true;

      # Create a `docker` alias for podman, to use it as a drop-in replacement
      dockerCompat = true;

      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  containers = (import ../../modules/ollama.nix {
    inherit nixpkgs lib;
    devices = [
      "/dev/kfd"
      "/dev/dri/card1"      # Discrete GPU (RX 6650 XT/6700S/6800S)
      "/dev/dri/renderD128" # Discrete GPU render node
    ];
  }).containers;

  # Set your time zone.
  # time.timeZone = "America/Chicago";
  services.automatic-timezoned.enable = true;

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;
  services.xserver.videoDrivers = [ "amdgpu" ];

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm = {
    enable = true;
    wayland = {
      enable = true;
      compositor = "kwin";
    };
  };
  services.xserver.desktopManager.plasma5.enable = true;
  services.hardware.bolt.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    variant = "";
    layout = "us";
  };

  # Enable CUPS to print documents, and SANE to scan them.
  services.printing.enable = true;
  hardware.sane.enable = true;

  # Enable Avahi (mDNS/DNS-SD) for the local network discovery services.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      userServices = true;
      addresses = true;
      domain = true;
      hinfo = true;
      workstation = true;
    };
  };

  # Enable bluetooth
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # Enable OpenGL/ROCm
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = [
    pkgs-unstable.amdvlk
    pkgs.rocmPackages.clr.icd
  ];
  hardware.graphics.extraPackages32 = [
    pkgs-unstable.driversi686Linux.amdvlk
  ];

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Security configurations.
  security = {
    rtkit.enable = true;
    pam = {
      services = {
        sudo.u2fAuth = true;
      };
      loginLimits = [{
        domain = "*";
        type = "soft";
        item = "nofile";
        value = "4096";
      }];
    };
    sudo = {
      enable = true;
      extraConfig = ''
        Defaults timestamp_timeout=1
      '';
    };
  };

  services.keybase.enable = true;
  services.kbfs = {
    enable = true;
    enableRedirector = true;
  };
  security.wrappers.keybase-redirector.owner = "john";
  security.wrappers.keybase-redirector.group = "users";

  # Extra groups
  users.groups.plugdev = {};

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

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    pciutils
    pam_u2f
    # shell utils
    bat
    neovim
    wget
    curl
    git
    htop
    dig
    home-manager
    appimage-run
    # container utils
    podman-tui
    dive
    podman-compose
    # build utils
    nix-prefetch-scripts
    cmake
    gnumake
    gcc
    libgcc
    # UI utils
    kdePackages.plasma-thunderbolt
    keybase-gui
  ] ++ [
    pkgs-unstable.zsa-udev-rules
    pkgs-unstable.devenv
  ];

  users.defaultUserShell = pkgs.zsh;
  programs.zsh.enable = true;
  programs.direnv.enable = true;

  programs.streamdeck-ui = {
    enable = true;
  };

  nix.settings.experimental-features = "nix-command flakes";

  nix.gc = {
    automatic = true;
    dates = "Tue *-*-* 03:15:00";
    options = "--delete-older-than 14d";
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:
  services.pcscd.enable = true;

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

  services.udev = {
    packages = [ pkgs-unstable.zsa-udev-rules ];
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    extraUpFlags = [
      "--operator=john"
    ];
  };

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
