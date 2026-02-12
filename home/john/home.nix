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
  ] ++ lib.optionals (jzila-derivations != null) [
    jzila-derivations.packages.${system}.claude-code
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
  ]);

  # Darwin-only packages
  darwinPackages = lib.optionals isDarwin [
    pkgs.firefox-bin
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
    enable = true;
    history = {
      ignoreSpace = true;
      extended = true;
    };
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    historySubstringSearch.enable = true;
    shellAliases = {
      "...." = "cd ../../..";
      "....." = "cd ../../../..";
      ls = "ls --color=auto";
      ll = "ls --color=auto -l";
      la = "ls --color=auto -la";
      l1 = "ls --color=auto -1";
      l1a = "ls --color=auto -1a";
      vim = "lvim";
      grep = ''grep -I --exclude-dir=".git" --exclude-dir="vendor" --exclude-dir="node_modules" --exclude-dir=dist'';
      grepnolog = ''grep -I --exclude-dir="*log*" --exclude-dir="*\.svn*" --exclude="*\.svn-base"'';
      gup = "git fetch origin && git rebase origin/main";
      gds = "git --no-pager diff --stat";
      gd2 = "git diff2";
      gp = "git push";
      gfu = "git fetch upstream";
      gfo = "git fetch origin";
      gr = "git rebase";
      grm = "git rebase origin/main main";
      ga = "git add";
      gaa = "git add -A";
    };
    initContent = ''
      ZSH_AUTOSUGGEST_STRATEGY=(history)

      unset correctall
      set correct

      unsetopt nomatch 2>/dev/null

      repodir() {
          unset -f _direnv_hook
          local old_pwd="$PWD"
          local counter="."
          if [[ "''${PWD##/keybase/}" != "$old_pwd" ]]; then
              echo "''${PWD##*/}"
              return 0
          fi
          while true; do
              local cur_pwd="$(echo -n $(cd $counter && pwd))"
              if [[ "$cur_pwd" == "/" ]]; then
                  echo "''${PWD##*/}"
                  return 0
              fi
              for repo in "$cur_pwd/.git" "$cur_pwd/.hg"; do
                  if [[ -d "$repo" ]]; then
                      cur_pwd="$(echo -n $(cd ../$counter && pwd))"
                      echo "''${old_pwd#$cur_pwd/}"
                      return 0
                  fi
              done
              counter="../$counter"
          done
      }

      reporoot() {
          git rev-parse --show-toplevel
      }

      dcleanup() {
          local containers
          containers=( $(docker ps -aq 2>/dev/null) )
          docker rm "''${containers[@]}" 2>/dev/null
          local volumes
          volumes=( $(docker volume ls --filter dangling=true -q 2>/dev/null) )
          docker volume rm "''${volumes[@]}" 2>/dev/null
          local images
          images=( $(docker images --filter dangling=true -q 2>/dev/null) )
          docker rmi "''${images[@]}" 2>/dev/null
      }

      yubikey() {
          if [ "$1" ]; then
              ykman oath code | grep "$1" | head -n 1 | awk '{print $NF}'
          else
              echo STDERR "Usage: yubikey <name of service>"
              return 1
          fi
      }

      csv_to_json() {
          local input_file="$1"
          local output_file="$2"

          if [[ ! -f "$input_file" ]]; then
              echo "Input file does not exist."
              return 1
          fi

          if [[ -z "$output_file" ]]; then
              echo "Please specify an output file."
              return 1
          fi

          jq -R -s -c '
          split("\n") | .[1:] | map(split(",")) |
          map({
              id: .[0],
              name: .[1],
              age: .[2]
          })
          ' "$input_file" > "$output_file"

          echo "CSV converted to JSON successfully."
      }

      PROMPT='%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%})%M %* %{$fg[cyan]%}$(repodir) %{$fg_bold[blue]%}$(git_prompt_info)%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%})%(!.#.➜)%{$fg_bold[blue]%} % %{$reset_color%}'
    '';
    oh-my-zsh = {
      enable = true;
      custom = "${homeDir}/.oh-my-zsh-custom";
      theme = "jzila";
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
  programs.kitty = {
    enable = true;
    settings = {
      shell = "${pkgs.tmux}/bin/tmux new-session";
    } // lib.optionalAttrs isDarwin {
      font_size = 12;
      window_padding_width = 2;
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

    GREP_COLOR = "1;31";
    GOPATH = "$HOME/repos/go";
    JZ_REPO = "$HOME/repos/go/src/github.com/jzila";
  };
  home.sessionPath = [
    "$HOME/bin"
    "$HOME/repos/go/bin"
  ];
  home.file.".oh-my-zsh-custom/themes/jzila.zsh-theme".text = ''
    PROMPT='%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%})%M %* %{$fg[cyan]%}%c %{$fg_bold[blue]%}$(git_prompt_info)%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%})%(!.#.➜)%{$fg_bold[blue]%} % %{$reset_color%}'

    ZSH_THEME_GIT_PROMPT_PREFIX="(%{$fg[blue]%}"
    ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
    ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[yellow]%}*%{$fg[blue]%})%{$reset_color%}"
    ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"
  '';
  home.file.".config/nixpkgs/config.nix" = {
    text = ''
      {
        allowUnfree = true;
      }
    '';
  };
  home.packages = commonPackages ++ linuxPackages ++ darwinPackages;
}
