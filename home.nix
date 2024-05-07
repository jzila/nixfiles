{ config, pkgs, ... }:

let
  system = builtins.currentSystem;
  unstable = import <nixos-unstable> {
    config = config.nixpkgs.config;
  };
  vscode-extensions =
    (import (builtins.fetchGit {
      url = "https://github.com/nix-community/nix-vscode-extensions";
      ref = "refs/heads/master";
    })).extensions.${system};
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

  # fonts
  fonts.fontconfig.enable = true;

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
    package = unstable.vscode;
    extensions = with vscode-extensions.vscode-marketplace; [
      pkgs.vscode-extensions.github.copilot
    ] ++ [
      ms-vscode.vscode-typescript-next
      bradlc.vscode-tailwindcss
    ];
  };
  home.packages = [
    pkgs.just
    pkgs.lunarvim
    pkgs.kitty
    pkgs.kitty-themes
    (pkgs.nerdfonts.override { fonts = [ "FiraCode" ]; })
  ] ++ [
    unstable.python3Full
    unstable.nodejs_20
    unstable.bun
    unstable.yarn
    unstable.earthly
    unstable.ollama
    unstable.go
    unstable.lazygit
  ];
}
