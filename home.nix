{ config, pkgs, ... }:

let
  unstable = import <nixos-unstable> {
    config = config.nixpkgs.config;
  };
in
{
  home.username = "john";
  home.homeDirectory = "/home/john";
  home.stateVersion = "23.11";

  # home-manager should manage itself and allow unfree packages.
  programs.home-manager.enable = true;
  nixpkgs.config.allowUnfree = true;

  programs.zsh = {
    enable    = true;
    initExtra = ''
      . /home/john/repos/dotfiles/zshrc
    '';
    oh-my-zsh = {
      enable  = true;
      custom  = "$HOME/repos/dotfiles/zsh_custom";
      theme   = "jzila";
      plugins = [
        "git"
        "vi-mode"
        "history-substring-search"
        "zsh-autosuggestions"
        "zsh-syntax-highlighting"
        "bgnotify"
      ];
      extraConfig = ''
        zstyle ':completion:*' accept-exact-dirs true
      '';
    };
  };
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
    ];
  };
  home.packages = with pkgs; [
  ] ++ [
    unstable.nodejs_20
  ];
}

