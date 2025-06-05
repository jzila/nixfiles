# NixOS LiveCD for the ASUS ROG Zephyrus G14 GA402 - 2022 edition
{ config, pkgs, ... }:
{
  imports = [
    <nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-graphical-plasma5.nix>

    # Provide an initial copy of the NixOS channel so that the user
    # doesn't need to run "nix-channel --update" first.
    <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>

    # Base image for GA402
    <nixos-hardware/asus/zephyrus/ga402>
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
