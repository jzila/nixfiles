{ config, pkgs, lib, ... }:

let
  # Kernel args from the system config
  kernelArgs = lib.concatStringsSep " " (config.boot.kernelParams or []);
  # The stage-2 init inside the built system
  stage2Init = "${config.system.build.toplevel}/init";
in {
  # Produce an iPXE script that uses UEFI imgargs + boot vmlinuz
  system.build.netbootIpxeScriptEfi = pkgs.writeText "netboot-efi.ipxe" ''
#!ipxe
imgfree
imgfetch --name vmlinuz bzImage
imgfetch --name initrd initrd
imgstat
imgargs vmlinuz initrd=initrd init=${stage2Init} ${kernelArgs}
boot vmlinuz
'';
}

