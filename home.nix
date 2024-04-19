{ config, pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;
  programs.home-manager.enable = true;

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
  home.username = "john";
  home.homeDirectory = "/home/john";
  home.stateVersion = "23.11";

  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
    ];
  };
}

