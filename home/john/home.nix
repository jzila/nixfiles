{ config, pkgs, pkgs-unstable, nix-vscode-extensions, plasma-manager, system, ... }:

let
  vscode-extensions = nix-vscode-extensions.extensions.${system};
in
{
  imports = [
    ../../modules/plasma/plasma.nix
  ];

  home.username = "john";
  home.homeDirectory = "/home/john";
  home.stateVersion = "23.11";

  # home-manager should manage itself and allow unfree packages.
  programs.home-manager.enable = true;
  nixpkgs.config.allowUnfree = true;
  programs.direnv.enable = true;

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
    package = pkgs-unstable.vscode;
    extensions = with vscode-extensions.vscode-marketplace; [
      pkgs.vscode-extensions.github.copilot
    ] ++ [
      ms-vscode.vscode-typescript-next
      bradlc.vscode-tailwindcss
    ];
  };
  home.packages = [
    pkgs.just
    pkgs.kitty
    pkgs.kitty-themes
    (pkgs.nerdfonts.override { fonts = [ "FiraCode" ]; })
    pkgs.jq
    pkgs.fzf
    pkgs.kdePackages.skanpage
    pkgs.gpu-screen-recorder
    pkgs.gpu-screen-recorder-gtk
    pkgs.vlc
    pkgs.lmodern
  ] ++ [
    pkgs-unstable.python3Full
    pkgs-unstable.nodejs_22
    pkgs-unstable.bun
    pkgs-unstable.yarn
    pkgs-unstable.earthly
    pkgs-unstable.ollama
    pkgs-unstable.go
    pkgs-unstable.lazygit
    pkgs-unstable.delta
    pkgs-unstable.signal-desktop
    pkgs-unstable.zed-editor
    pkgs-unstable.gh
    pkgs-unstable.neovim
    pkgs-unstable.lunarvim
    pkgs-unstable.galaxy-buds-client
    pkgs-unstable.google-chrome
    pkgs-unstable.claude-code
  ];
}