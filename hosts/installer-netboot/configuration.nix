# NixOS Netboot Installer (generic, not host-specific)
{ config, pkgs, lib, nixpkgs, ... }:

{
  imports = [
    # Official netboot image support
    "${nixpkgs}/nixos/modules/installer/netboot/netboot.nix"
    # Generate an EFI-friendly iPXE script (imgargs + boot vmlinuz)
    ../../modules/netboot/ipxe-efi.nix
    # SSH CA integration (SmallStep) for certificate-based SSH
    ../../modules/ssh-ca
  ];

  networking.hostName = "nixos-installer-netboot";
  system.stateVersion = "23.11";

  # Initrd/kernel tweaks for robust early boot
  boot.initrd.compressor = "gzip";
  boot.kernelParams = [
    "loglevel=7" "ignore_loglevel" "keep_bootcon" "boot_delay=50" "printk.time=1"
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.build.squashfs.enable = true;

  # Passwordless installer user
  users.mutableUsers = false;
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    password = "";
  };
  security.pam.services.login.allowNullPassword = true;
  security.sudo.wheelNeedsPassword = false;

  # SSH server with certificate authentication
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Installer tooling
  environment.systemPackages =
    (with pkgs; [
      nixos-install-tools git curl jq parted e2fsprogs btrfs-progs lvm2 mdadm cryptsetup gptfdisk
    ]) ++ [
      (pkgs.writeShellScriptBin "install-host" ''
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "$(id -u)" -ne 0 ]]; then
          echo "install-host must be run as root." >&2
          echo "Try: sudo install-host <host> | <flakeRef>#<host>" >&2
          exit 1
        fi
        EMBEDDED_FLAKE="/etc/installer/flake"
        usage() {
          echo "Usage: install-host <host> | <flakeRef>#<host>" >&2
          echo "  - If you pass just <host>, it uses ''${EMBEDDED_FLAKE}#<host>" >&2
          echo "  - Or pass a full flake ref like github:user/repo#host" >&2
        }
        if [[ $# -lt 1 ]]; then usage; exit 1; fi
        ARG="$1"
        if [[ "$ARG" == *#* ]]; then
          FLAKE="$ARG"; HOST=""
        else
          HOST="$ARG"; FLAKE=""
        fi

        echo
        echo "Disk partitioning options:"
        echo "  1) Auto-partition (GPT: ESP + root; optional LUKS) [default]"
        echo "  2) Manual (you will run parted yourself)"
        read -r -p "Choose [1/2]: " choice || true
        if [[ -z "''${choice}" || "''${choice}" == 1 ]]; then
          echo
          echo "Detecting candidate disks ..."
          mapfile -t CANDS < <(lsblk -dn -o NAME,TYPE,SIZE | awk '$2=="disk"{printf("/dev/%s %s\n", $1, $3)}')
          if [[ ''${#CANDS[@]} -eq 0 ]]; then
            echo "No installable disks detected." >&2; exit 1
          fi
          if [[ ''${#CANDS[@]} -eq 1 ]]; then
            DISK=$(awk '{print $1}' <<<"''${CANDS[0]}")
            echo "Selected disk: ''${DISK} ($(awk '{print $2}' <<<"''${CANDS[0]}") )"
          else
            echo "Multiple disks detected:"
            idx=1
            for d in "''${CANDS[@]}"; do
              printf "  %d) %s %s\n" "$idx" "$(awk '{print $1}' <<<"$d")" "$(awk '{print $2}' <<<"$d")"
              idx=$((idx+1))
            done
            read -r -p "Choose disk [1-''${#CANDS[@]}] (default 1): " pick || true
            if [[ -z "''${pick}" ]]; then pick=1; fi
            if ! [[ "''${pick}" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ''${#CANDS[@]} )); then
              echo "Invalid choice." >&2; exit 1
            fi
            DISK=$(awk '{print $1}' <<<"''${CANDS[$((pick-1))]}")
          fi
          echo "WARNING: This will ERASE all data on ''${DISK}!"; read -r -p "Type 'ERASE' to confirm: " confirm
          if [[ "''${confirm}" != "ERASE" ]]; then echo "Aborted."; exit 1; fi
          if [[ "''${DISK}" =~ (nvme|mmcblk) ]]; then P1="''${DISK}p1"; P2="''${DISK}p2"; else P1="''${DISK}1"; P2="''${DISK}2"; fi
          echo
          read -r -s -p "Root LUKS passphrase (empty for no encryption): " LUKS1; echo
          if [[ -n "''${LUKS1}" ]]; then read -r -s -p "Confirm passphrase: " LUKS2; echo; [[ "''${LUKS1}" == "''${LUKS2}" ]] || { echo "Passphrases do not match." >&2; exit 1; }; fi
          echo "Wiping and partitioning ''${DISK} ..."
          wipefs -fa "''${DISK}" || true; sgdisk -Z "''${DISK}" || true
          parted -s "''${DISK}" mklabel gpt
          parted -s -a optimal "''${DISK}" mkpart ESP fat32 1MiB 1GiB
          parted -s "''${DISK}" set 1 esp on
          parted -s -a optimal "''${DISK}" mkpart primary ext4 1GiB 100%
          echo "Formatting EFI (''${P1}) ..."; mkfs.fat -F32 -n EFI "''${P1}"
          if [[ -n "''${LUKS1}" ]]; then
            echo "Setting up LUKS on ''${P2} ..."
            printf '%s' "''${LUKS1}" | cryptsetup luksFormat --type luks2 "''${P2}" -q --key-file -
            printf '%s' "''${LUKS1}" | cryptsetup open "''${P2}" cryptroot --key-file -
            ROOTDEV="/dev/mapper/cryptroot"
          else
            ROOTDEV="''${P2}"
          fi
          echo "Formatting root (''${ROOTDEV}) ..."; mkfs.ext4 -L nixos "''${ROOTDEV}"
          echo "Mounting filesystems ..."; mkdir -p /mnt; mount "''${ROOTDEV}" /mnt; mkdir -p /mnt/boot; mount "''${P1}" /mnt/boot
          echo "Generating hardware config ..."; nixos-generate-config --root /mnt || true
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

        # Build device flake under /mnt/etc/nixos using nixfiles.lib.mkSystem via template
        if [[ -n "''${HOST}" ]]; then
          mkdir -p /mnt/etc/nixos
          # Ensure hardware-configuration exists
          if [[ ! -f /mnt/etc/nixos/hardware-configuration.nix ]]; then
            echo "Generating hardware-configuration.nix ..."
            nixos-generate-config --root /mnt
          fi
          echo "Copying embedded nixfiles into /mnt/etc/nixos/nixfiles ..."
          mkdir -p /mnt/etc/nixos/nixfiles
          cp -aL "''${EMBEDDED_FLAKE}"/. /mnt/etc/nixos/nixfiles/
          if [[ ! -f /mnt/etc/nixos/flake.nix ]]; then
            echo "Initializing device flake from template (relative path) ..."
            ( cd /mnt/etc/nixos && nix flake init -t path:./nixfiles#nixos-device )
          fi
          # Lock the device flake so it pins the local path input purely
          ( cd /mnt/etc/nixos && nix flake lock --update-input nixfiles )
          echo "Setting host in /mnt/etc/nixos/host.nix ..."
          printf '"%s"\n' "''${HOST}" > /mnt/etc/nixos/host.nix
          FLAKE="/mnt/etc/nixos#''${HOST}"
        fi

        echo "Using flake: ''${FLAKE}"
        if nixos-install --no-root-passwd --flake "''${FLAKE}"; then
          echo
          echo "Installation complete."
          echo
          echo "Optionally set user passwords now (recommended):"
          read -r -p "Enter username to set password for (leave empty to skip): " PWUSER || true
          if [[ -n "''${PWUSER}" ]]; then
            echo "Launching passwd for ''${PWUSER} inside the target system..."
            nixos-enter --root /mnt -- passwd "''${PWUSER}" || true
          fi
          read -r -p "Set root password as well? [y/N]: " setroot || true
          if [[ "''${setroot}" =~ ^[Yy]$ ]]; then
            nixos-enter --root /mnt -- passwd root || true
          fi
          echo
          echo "All done. You can now reboot."
          echo "If you ever need to set passwords later from the installer:"
          echo "  1) If root is LUKS-encrypted:"
          echo "     cryptsetup open /dev/<root-partition> cryptroot"
          echo "     mount /dev/mapper/cryptroot /mnt"
          echo "     mount /dev/<esp-partition> /mnt/boot"
          echo "  2) Enter the system and run passwd:"
          echo "     nixos-enter --root /mnt -- passwd <username>"
        else
          echo "nixos-install failed" >&2
          exit 1
        fi
      '')
    ];

  # Enable flakes in the installer environment
  nix = {
    package = pkgs.nixVersions.latest;
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  # Embed this repository's flake into the initrd for offline installs
  environment.etc."installer/flake".source = ../../.;
}
