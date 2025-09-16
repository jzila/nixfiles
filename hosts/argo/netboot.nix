# TRULY MINIMAL netboot - replicate nix-community/nixos-images approach
{ config, pkgs, lib, nixpkgs, ... }:

{
  imports = [
    # Use the EXACT same approach as nix-community/nixos-images
    # They use nixpkgs/nixos/modules/installer/netboot/netboot.nix, NOT netboot-minimal.nix
    "${nixpkgs}/nixos/modules/installer/netboot/netboot.nix"
    # Generate an EFI-friendly iPXE script (imgargs + boot vmlinuz)
    ../../modules/netboot/ipxe-efi.nix
    # SSH CA integration (SmallStep) for certificate-based SSH
    ../../modules/ssh-ca
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

  # SSH server with certificate authentication via TrustedUserCAKeys
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Include Nix installer tooling and common utilities + helper script
  environment.systemPackages =
    (with pkgs; [
      nixos-install-tools
      git
      curl
      jq
      parted
      e2fsprogs
      btrfs-progs
      lvm2
      mdadm
      cryptsetup
    ]) ++ [
      (pkgs.writeShellScriptBin "install-host" ''
        #!/usr/bin/env bash
        set -euo pipefail
        EMBEDDED_FLAKE="/etc/installer/flake"
        usage() {
          echo "Usage: install-host <host> | <flakeRef>#<host>" >&2
          echo "  - If you pass just <host>, it uses ''${EMBEDDED_FLAKE}#<host>" >&2
          echo "  - Or pass a full flake ref like github:user/repo#host" >&2
        }
        if [[ $# -lt 1 ]]; then
          usage; exit 1
        fi
        ARG="$1"
        if [[ "$ARG" == *#* ]]; then
          FLAKE="$ARG"
        else
          FLAKE="''${EMBEDDED_FLAKE}#''${ARG}"
        fi
        echo
        echo "Disk partitioning options:"
        echo "  1) Auto-partition (GPT: ESP + root; optional LUKS) [default]"
        echo "  2) Manual (you will run parted yourself)"
        read -r -p "Choose [1/2]: " choice || true
        if [[ -z "''${choice}" || "''${choice}" == 1 ]]; then
          echo
          echo "Available disks:"
          lsblk -d -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{print}'
          echo
          read -r -p "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK
          if [[ -z "''${DISK}" || ! -b "''${DISK}" ]]; then
            echo "Invalid disk: ''${DISK}" >&2; exit 1
          fi
          echo "WARNING: This will ERASE all data on ''${DISK}!"
          read -r -p "Type 'ERASE' to confirm: " confirm
          if [[ "''${confirm}" != "ERASE" ]]; then
            echo "Aborted."; exit 1
          fi
          # Determine partition path style
          if [[ "''${DISK}" =~ (nvme|mmcblk) ]]; then
            P1="''${DISK}p1"; P2="''${DISK}p2"
          else
            P1="''${DISK}1"; P2="''${DISK}2"
          fi
          # Optional LUKS
          echo
          read -r -s -p "Root LUKS passphrase (empty for no encryption): " LUKS1; echo
          if [[ -n "''${LUKS1}" ]]; then
            read -r -s -p "Confirm passphrase: " LUKS2; echo
            if [[ "''${LUKS1}" != "''${LUKS2}" ]]; then
              echo "Passphrases do not match." >&2; exit 1
            fi
          fi
          echo "Wiping and partitioning ''${DISK} ..."
          wipefs -fa "''${DISK}" || true
          sgdisk -Z "''${DISK}" || true
          parted -s "''${DISK}" mklabel gpt
          parted -s -a optimal "''${DISK}" mkpart ESP fat32 1MiB 1GiB
          parted -s "''${DISK}" set 1 esp on
          parted -s -a optimal "''${DISK}" mkpart primary ext4 1GiB 100%
          echo "Formatting EFI (''${P1}) ..."
          mkfs.fat -F32 -n EFI "''${P1}"
          if [[ -n "''${LUKS1}" ]]; then
            echo "Setting up LUKS on ''${P2} ..."
            printf '%s' "''${LUKS1}" | cryptsetup luksFormat --type luks2 "''${P2}" -q --key-file -
            printf '%s' "''${LUKS1}" | cryptsetup open "''${P2}" cryptroot --key-file -
            ROOTDEV="/dev/mapper/cryptroot"
          else
            ROOTDEV="''${P2}"
          fi
          echo "Formatting root (''${ROOTDEV}) ..."
          mkfs.ext4 -L nixos "''${ROOTDEV}"
          echo "Mounting filesystems ..."
          mkdir -p /mnt
          mount "''${ROOTDEV}" /mnt
          mkdir -p /mnt/boot
          mount "''${P1}" /mnt/boot
          echo "Generating hardware config ..."
          nixos-generate-config --root /mnt || true
        else
          echo
          echo "Manual partitioning selected. Instructions:"
          echo "  - Run: parted /dev/<disk>"
          echo "  - Create GPT: mklabel gpt"
          echo "  - ESP: mkpart ESP fat32 1MiB 1GiB; set 1 esp on; mkfs.fat -F32 /dev/<disk>1"
          echo "  - Root: mkpart primary ext4 1GiB 100%; mkfs.ext4 /dev/<disk>2"
          echo "  - For LUKS root: cryptsetup luksFormat /dev/<disk>2; cryptsetup open /dev/<disk>2 cryptroot; mkfs.ext4 /dev/mapper/cryptroot"
          echo "  - Mount root at /mnt and ESP at /mnt/boot, then re-run this command."
          exit 1
        fi

        echo "Using flake: ''${FLAKE}"
        exec nixos-install --no-root-passwd --flake "''${FLAKE}"
      '')
    ];

  # Enable flakes in the installer environment
  nix = {
    package = pkgs.nixVersions.latest;
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  # Embed this repository's flake into the initrd for offline installs
  # Available at /etc/installer/flake (directory with flake.nix/flake.lock)
  environment.etc."installer/flake".source = ../../.;

  # Convenience: boot param you can add via iPXE: install_flake=<flakeRef>#<host>
}
