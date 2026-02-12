{ isDarwin, ... }:

let
  homeDir = if isDarwin then "/Users/john" else "/home/john";
in
{
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

  home.file.".oh-my-zsh-custom/themes/jzila.zsh-theme".text = ''
    PROMPT='%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%})%M %* %{$fg[cyan]%}%c %{$fg_bold[blue]%}$(git_prompt_info)%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%})%(!.#.➜)%{$fg_bold[blue]%} % %{$reset_color%}'

    ZSH_THEME_GIT_PROMPT_PREFIX="(%{$fg[blue]%}"
    ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
    ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[yellow]%}*%{$fg[blue]%})%{$reset_color%}"
    ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"
  '';
}
