{ config, pkgs, pkgs-unstable, lib, nix-vscode-extensions, isLinux, isDarwin, ... }@inputs:

let
  system = pkgs.stdenv.hostPlatform.system;
  homeDir = if isDarwin then "/Users/john" else "/home/john";

  vscode-extensions = nix-vscode-extensions.extensions.${system};

  # Linux-only inputs (may be null on darwin)
  pkgs-jzila = inputs.pkgs-jzila or null;
  beads-fixed = inputs.beads-fixed or null;
  wifitui = inputs.wifitui or null;
  roborev = inputs.roborev or null;
  jzila-derivations = inputs.jzila-derivations or null;

  # Cross-platform packages
  commonPackages = [
    pkgs.just
    pkgs.kitty
    pkgs.kitty-themes
    pkgs.nerd-fonts.fira-code
    pkgs.jq
    pkgs.fzf
    pkgs.lmodern
    pkgs.tree
    pkgs.ripgrep
    pkgs.openssl
    pkgs.awscli2
    pkgs.zed-editor
  ] ++ [
    pkgs-unstable.python3
    pkgs-unstable.nodejs_22
    pkgs-unstable.bun
    pkgs-unstable.yarn
    pkgs-unstable.go
    pkgs-unstable.lazygit
    pkgs-unstable.gh
    pkgs-unstable.lunarvim
    pkgs-unstable.gemini-cli
    pkgs-unstable.step-cli
    pkgs-unstable.codex
  ];

  # Linux-only packages
  linuxPackages = lib.optionals isLinux ([
    pkgs.vlc
    pkgs.kdePackages.skanpage
    pkgs.gpu-screen-recorder
    pkgs.gpu-screen-recorder-gtk
    pkgs-unstable.earthly
    pkgs-unstable.signal-desktop
    pkgs-unstable.galaxy-buds-client
    pkgs-unstable.google-chrome
  ] ++ lib.optionals (beads-fixed != null) [
    beads-fixed
  ] ++ lib.optionals (wifitui != null) [
    wifitui.packages.${system}.default
  ] ++ lib.optionals (roborev != null) [
    roborev.packages.${system}.default
  ] ++ lib.optionals (pkgs-jzila != null) [
    pkgs-jzila.ollama
  ] ++ lib.optionals (jzila-derivations != null) [
    jzila-derivations.packages.${system}.claude-code
  ]);

  # Darwin-only packages
  darwinPackages = lib.optionals isDarwin [
    # macOS-specific packages can be added here
  ];
in
{
  imports = lib.optionals isLinux [
    ../../modules/plasma/plasma.nix
  ];

  home.username = "john";
  home.homeDirectory = homeDir;
  home.stateVersion = "23.11";

  # home-manager should manage itself.
  programs.home-manager.enable = true;
  programs.direnv.enable = true;

  # fonts
  fonts.fontconfig.enable = true;

  programs.git = {
    enable = true;
    ignores = [
      ".vscode/**"
    ];
    settings = {
      user = {
        email = "john@jzila.com";
        name = "John Zila";
      };
      alias = {
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
        lg = "lg1";
        fixup = "commit --amend -C HEAD";
        blast = "for-each-ref --sort=-committerdate refs/heads/ --format=\"%(committerdate:relative)%09%(refname:short)\"";
        fix = "diff --name-only --relative -z --diff-filter=U | uniq | xargs -0 \${EDITOR}";
      };
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
  };
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      line-numbers = true;
      side-by-side = true;
    };
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

      . ${homeDir}/repos/dotfiles/zshrc
    '';
    oh-my-zsh = {
      enable  = true;
      custom  = "${homeDir}/repos/dotfiles/zsh_custom";
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
      source-file ${homeDir}/repos/dotfiles/tmux.conf
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
  home.file.".config/nixpkgs/config.nix" = {
    text = ''
      {
        allowUnfree = true;
      }
    '';
  };
  home.packages = commonPackages ++ linuxPackages ++ darwinPackages;
}
