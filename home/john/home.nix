{ config, pkgs, pkgs-unstable, nix-vscode-extensions, codex, wifitui, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  vscode-extensions = nix-vscode-extensions.extensions.${system};
in
{
  imports = [
    ../../modules/plasma/plasma.nix
  ];

  home.username = "john";
  home.homeDirectory = "/home/john";
  home.stateVersion = "23.11";

  # home-manager should manage itself.
  programs.home-manager.enable = true;
  programs.direnv.enable = true;

  # fonts
  fonts.fontconfig.enable = true;

  programs.git = {
    enable = true;
    userEmail = "john@jzila.com";
    userName = "John Zila";
    aliases = {
      ci = "commit";
      st = "status";
      co = "checkout";
      oneline = "log --pretty=oneline";
      br = "branch";
      la = "log --pretty=\"format:%ad %h (%an): %s\" --date=short";
      lgthis = "log --graph --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(bold white)%an — %C(reset)%C(white)%s%C(reset)%C(bold yellow)%d%C(reset)' --abbrev-commit --date=relative";
      lgall = "log --graph --all --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(bold white)%an — %C(reset)%C(white)%s%C(reset)%C(bold yellow)%d%C(reset)' --abbrev-commit --date=relative";
      lgall2 = "log --graph --all --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(bold yellow)%d%C(reset)%n''          %C(white)%s%C(reset) %C(bold white)— %an%C(reset)' --abbrev-commit";
      diff2 = "diff --ignore-all-space --patience";
      lg = !"git lg1";
      fixup = "commit --amend -C HEAD";
      blast = "for-each-ref --sort=-committerdate refs/heads/ --format=\"%(committerdate:relative)%09%(refname:short)\"";
      fix = "git diff --name-only --relative -z --diff-filter=U | uniq | xargs -0 \${EDITOR}";
    };
    delta = {
      enable = true;
      options = {
        line-numbers = true;
        side-by-side = true;
      };
    };
    extraConfig = {
      core = {
        editor = "nvim";
      };
      color = {
        ui = "true";
      };
      diff = {
        tool = "nvimdiff";
        algorithm = "patience";
      };
      push = {
        default = "current";
      };
      merge = {
        tool = "nvimdiff";
        conflictstyle = "diff3";
      };
      rerere = {
        enabled = "true";
      };
    };
    ignores = [
      ".vscode/**"
    ];
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
  };

  programs.zsh = {
    enable    = true;
    history = {
      ignoreSpace = true;
      extended = true;
    };
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    historySubstringSearch.enable = true;
    initContent = ''
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
    profiles.default.extensions = with vscode-extensions.vscode-marketplace; [
      pkgs.vscode-extensions.github.copilot
    ] ++ [
      ms-vscode.vscode-typescript-next
      bradlc.vscode-tailwindcss
    ];
  };
  home.sessionVariables = {
    OLLAMA_HOST = "127.0.0.1:11434";
  };
  home.packages = [
    pkgs.just
    pkgs.kitty
    pkgs.kitty-themes
    pkgs.nerd-fonts.fira-code
    pkgs.jq
    pkgs.fzf
    pkgs.kdePackages.skanpage
    pkgs.gpu-screen-recorder
    pkgs.gpu-screen-recorder-gtk
    pkgs.vlc
    pkgs.lmodern
    pkgs.tree
    pkgs.ripgrep
    pkgs.openssl
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
    pkgs-unstable.lunarvim
    pkgs-unstable.galaxy-buds-client
    pkgs-unstable.google-chrome
    pkgs-unstable.claude-code
    pkgs-unstable.gemini-cli
    pkgs-unstable.step-cli
    codex.packages.${system}.codex-rs
    wifitui.packages.${system}.default
  ];
}
