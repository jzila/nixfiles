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

  nvim = inputs.nvim;
  vimdiff = pkgs.writeShellScriptBin "vimdiff" ''exec nvim -d "$@"'';

  # Stable nixpkgs, imported explicitly because `pkgs` here is the host package
  # set: stable on NixOS, but unstable on darwin (nix-darwin's nixpkgs follows
  # nixpkgs-unstable). google-cloud-sdk needs the stable one. Its
  # withExtraComponents build always runs locally, and with the unstable version
  # the postInstall `gcloud components list` step aborts on Apple Silicon. Same
  # rationale as the gcloud pin in watt's platform/devenv.nix.
  pkgs-stable = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  commonPackages = [
    nvim
    vimdiff
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
    # gcloud with gke-gcloud-auth-plugin and kubectl bundled as components, so
    # `gcloud container clusters get-credentials` works without extra setup.
    # Pinned to the stable nixpkgs (see pkgs-stable above).
    (pkgs-stable.google-cloud-sdk.withExtraComponents [
      pkgs-stable.google-cloud-sdk.components.gke-gcloud-auth-plugin
      pkgs-stable.google-cloud-sdk.components.kubectl
    ])
    pkgs.zed-editor
    pkgs.jre_minimal
  ] ++ [
    pkgs-unstable.python3
    pkgs-unstable.nodejs_22
    pkgs-unstable.bun
    pkgs-unstable.yarn
    pkgs-unstable.go
    pkgs-unstable.lazygit
    pkgs-unstable.gh
    pkgs-unstable.gemini-cli
    pkgs-unstable.step-cli
  ] ++ [
    pkgs.postgresql
  ] ++ lib.optionals (jzila-derivations != null) [
    jzila-derivations.packages.${system}.claude-code
    jzila-derivations.packages.${system}.codex
  ] ++ lib.optionals (roborev != null) [
    roborev.packages.${system}.default
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
  ] ++ lib.optionals (pkgs-jzila != null) [
    pkgs-jzila.ollama
  ]);

  # Darwin-only packages
  darwinPackages = lib.optionals isDarwin [
    pkgs.firefox-bin
  ];
in
{
  imports = [
    ./zsh.nix
    ./kitty-bare.nix
  ] ++ lib.optionals isLinux [
    ../../modules/plasma/plasma.nix
  ];

  home.username = "john";
  home.homeDirectory = homeDir;
  home.stateVersion = "23.11";

  # home-manager should manage itself.
  programs.home-manager.enable = true;
  programs.direnv.enable = true;

  # Python packaging/interpreter manager. uv downloads its own interpreters,
  # which are not Nix-linked; on the NixOS hosts that needs the nix-ld shim
  # enabled in modules/desktop/aliza.nix.
  programs.uv = {
    enable = true;
    package = pkgs-unstable.uv;
  };

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

  programs.kitty = {
    enable = true;
    settings = {
      # Absolute path so kitty finds tmux even when launched from the macOS
      # Dock/Finder/Spotlight, where the GUI PATH excludes the Nix profile dirs.
      shell = "${pkgs.tmux}/bin/tmux";

      hide_window_decorations = "no";
      background_opacity = "0.85";
      background_blur = 15;

      font_family = "FiraCode";
      bold_font = "auto";
      italic_font = "auto";
      bold_italic_font = "auto";
      font_size = 11.0;

      # Molokai
      background = "#121212";
      foreground = "#bbbbbb";
      cursor = "#bbbbbb";
      selection_background = "#b4d5ff";
      selection_foreground = "#121212";
      color0 = "#121212";
      color8 = "#545454";
      color1 = "#fa2573";
      color9 = "#f5669c";
      color2 = "#97e123";
      color10 = "#b0e05e";
      color3 = "#dfd460";
      color11 = "#fef26c";
      color4 = "#0f7fcf";
      color12 = "#00afff";
      color5 = "#8700ff";
      color13 = "#af87ff";
      color6 = "#42a7cf";
      color14 = "#50cdfe";
      color7 = "#bbbbbb";
      color15 = "#ffffff";
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
    focusEvents = true;
    shortcut = "a";
    keyMode = "vi";
    baseIndex = 1;
    escapeTime = 0;
    aggressiveResize = true;
    customPaneNavigationAndResize = true;
    plugins = with pkgs; [
      tmuxPlugins.cpu
      tmuxPlugins.battery
    ];
    extraConfig = ''
      # https://github.com/seebi/tmux-colors-solarized
      set-option -g status-bg colour235
      set-option -g status-fg colour136

      # Window title colors
      set -g window-status-style fg=colour244,bg=default
      set -g window-status-current-style fg=black,bg=colour166

      # Pane number display
      set-option -g display-panes-active-colour colour33
      set-option -g display-panes-colour colour166

      # Clock
      set-window-option -g clock-mode-colour green

      # Status bar
      set -g status-left ""
      set -g status-interval 1
      set -g status-right '#[fg=white,bg=default]%a %l:%M:%S#[default] #[fg=cyan]%Y-%m-%d #{battery_icon_status}:#{battery_percentage}'

      # Window splits open in the current path
      bind-key v split-window -h -c "#{pane_current_path}"
      bind-key b split-window -c "#{pane_current_path}"
      bind-key '"' split-window -c "#{pane_current_path}"
      bind-key % split-window -h -c "#{pane_current_path}"
      bind-key c new-window -c "#{pane_current_path}"

      # Vi copy-mode selection
      bind -Tcopy-mode-vi v send -X begin-selection
      bind -Tcopy-mode-vi y send -X copy-selection

      # main-horizontal layout, 60% height for main pane
      bind m set-window-option main-pane-height 60\; select-layout main-horizontal

      # Named new window
      bind-key C command-prompt -p "Name of new window: " "new-window -n '%%'"

      # Reload config
      bind r source-file ~/.config/tmux/tmux.conf \; display-message "Config reloaded..."

      # Auto window rename
      set-window-option -g automatic-rename on
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
    EDITOR = "nvim";
    VISUAL = "nvim";
    OLLAMA_HOST = "127.0.0.1:11434";

    GREP_COLOR = "1;31";
    GOPATH = "$HOME/repos/go";
    JZ_REPO = "$HOME/repos/go/src/github.com/jzila";
  };
  home.sessionPath = [
    "$HOME/bin"
    "$HOME/repos/go/bin"
  ];
  home.file.".config/nixpkgs/config.nix" = {
    text = ''
      {
        allowUnfree = true;
      }
    '';
  };
  home.packages = commonPackages ++ linuxPackages ++ darwinPackages;
}
