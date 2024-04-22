{ config, pkgs, ... }:

let
  unstable = import <nixos-unstable> {
    config = config.nixpkgs.config;
  };
in
{
  imports = [
    ./plasma/plasma.nix
  ];

  home.username = "john";
  home.homeDirectory = "/home/john";
  home.stateVersion = "23.11";

  # home-manager should manage itself and allow unfree packages.
  programs.home-manager.enable = true;
  nixpkgs.config.allowUnfree = true;

  programs.zsh = {
    enable    = true;
    history = {
      ignoreSpace = true;
      extended = true;
    };
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    historySubstringSearch.enable = true;
    initExtra = ''
      ZSH_AUTOSUGGEST_STRATEGY=(history)

      . /home/john/repos/dotfiles/zshrc
    '';
    oh-my-zsh = {
      enable  = true;
      custom  = "/home/john/repos/dotfiles/zsh_custom";
      theme   = "jzila";
      plugins = [
        "git"
        "vi-mode"
        "bgnotify"
        "history-substring-search"
      ];
      extraConfig = ''
        zstyle ':completion:*' accept-exact-dirs true
      '';
    };
  };
  programs.tmux = {
    enable = true;
    secureSocket = true;
    clock24 = true;
    historyLimit = 10000;
    terminal = "screen-256color";
    plugins = with pkgs; [
      tmuxPlugins.cpu
      tmuxPlugins.battery
    ];
    extraConfig = ''
      source-file /home/john/repos/dotfiles/tmux.conf
    '';
  };
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
      github.copilot
    ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
    ];
  };
  home.packages = [
    pkgs.just
  ] ++ [
    unstable.python3Full
    unstable.nodejs_20
    unstable.bun
    unstable.earthly
  ];
}

