# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/9afedc62-0227-41f2-9eb4-8af128a2584b";
      fsType = "ext4";
    };

  boot.initrd.luks.devices."luks-e882a22b-a07a-4bd2-b9bf-0879c3a10a35".device = "/dev/disk/by-uuid/e882a22b-a07a-4bd2-b9bf-0879c3a10a35";

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/6442-8792";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices = [ ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp8s0f4u1u2.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp5s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
