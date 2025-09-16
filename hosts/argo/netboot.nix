# TRULY MINIMAL netboot - replicate nix-community/nixos-images approach
{ config, pkgs, lib, nixpkgs, ... }:

{
  imports = [
    # Use the EXACT same approach as nix-community/nixos-images
    # They use nixpkgs/nixos/modules/installer/netboot/netboot.nix, NOT netboot-minimal.nix
    "${nixpkgs}/nixos/modules/installer/netboot/netboot.nix"
    # Generate an EFI-friendly iPXE script (imgargs + boot vmlinuz)
    ../../modules/netboot/ipxe-efi.nix
  ];

  # ABSOLUTELY NOTHING ELSE - testing if this creates working squashfs embedding
  networking.hostName = "argo-netboot-minimal";
  system.stateVersion = "23.11";

  # Help avoid early VFS panic by ensuring the kernel can unpack the initramfs
  # on all firmware. Some environments stumble on zstd-compressed initramfs.
  # Force gzip for maximum compatibility.
  boot.initrd.compressor = "gzip";

  # Increase verbosity and slow scroll to capture early initramfs messages.
  boot.kernelParams = [
    "loglevel=7"
    "ignore_loglevel"
    "keep_bootcon"
    "boot_delay=50"
    "printk.time=1"
  ];

  # Use the latest kernel for broader initramfs and driver support during netboot
  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.build.squashfs.enable = true;

  # Create a passwordless installer user 'nixos' (no autologin)
  users.mutableUsers = false;
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    password = "";
  };
  security.pam.services.login.allowNullPassword = true;
  security.sudo.wheelNeedsPassword = false;
}
