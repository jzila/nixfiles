# Shared desktop/workstation configuration module
{ config, pkgs, pkgs-unstable, lib, ... }:

{
  imports = [
    ../ssh-ca
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Desktop Environment - KDE Plasma 6
  services.xserver.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland = {
      enable = true;
      compositor = "kwin";
    };
  };
  services.desktopManager.plasma6.enable = true;
  services.hardware.bolt.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    variant = "";
    layout = "us";
  };

  # Audio - PipeWire
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Printing and Scanning
  services.printing.enable = true;
  hardware.sane.enable = true;

  # Network Discovery - Avahi (mDNS/DNS-SD)
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

  # Bluetooth
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # Container Infrastructure - Podman
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Security Configurations
  security = {
    rtkit.enable = true;
    pam = {
      services.sudo.u2fAuth = true;
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

  # Keybase Services
  services.keybase.enable = true;
  services.kbfs = {
    enable = true;
    enableRedirector = true;
  };

  # Extra Groups
  users.groups.plugdev = {};

  # Shell Configuration
  users.defaultUserShell = pkgs.zsh;
  programs.zsh.enable = true;
  programs.direnv.enable = true;

  # Hardware Security
  services.pcscd.enable = true;

  # Stream Deck Support
  programs.streamdeck-ui.enable = true;

  # ZSA Keyboard Support
  services.udev.packages = [ pkgs-unstable.zsa-udev-rules ];

  # Tailscale VPN
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    package = pkgs-unstable.tailscale;
  };

  # Networking
  networking = {
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [
      3000  # Development server
      3001  # Development server
    ];
  };

  # Time Zone
  services.automatic-timezoned.enable = true;

  # Locale Settings
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

  # AppImage Support
  boot.binfmt.registrations.appimage = {
    wrapInterpreterInShell = false;
    interpreter = "${pkgs.appimage-run}/bin/appimage-run";
    recognitionType = "magic";
    offset = 0;
    mask = ''\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff'';
    magicOrExtension = ''\x7fELF....AI\x02'';
  };

  # System Packages
  environment.systemPackages = with pkgs; [
    # Hardware utilities
    pciutils
    pam_u2f
    
    # Shell utilities
    bat
    neovim
    wget
    curl
    git
    htop
    dig
    home-manager
    appimage-run
    
    # Container utilities
    podman-tui
    dive
    podman-compose
    
    # Build utilities
    nix-prefetch-scripts
    cmake
    gnumake
    gcc
    libgcc
    
    # Desktop utilities
    kdePackages.plasma-thunderbolt
    keybase-gui
  ] ++ [
    # Unstable packages
    pkgs-unstable.zsa-udev-rules
    pkgs-unstable.devenv
  ];

  # Nix Configuration
  nix.settings.experimental-features = "nix-command flakes";
  nix.gc = {
    automatic = true;
    dates = "Tue *-*-* 03:15:00";
    options = "--delete-older-than 14d";
  };

  # Bootloader common configuration
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
    grub.memtest86.enable = true;
    systemd-boot.memtest86.enable = true;
  };
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
