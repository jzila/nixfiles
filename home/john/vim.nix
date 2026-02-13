{ pkgs, ... }:

{
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    vimdiffAlias = true;

    globals = {
      mapleader = "\\";
      maplocalleader = "\\";
      sonokai_transparent_background = 1;
    };

    colorscheme = "sonokai";

    opts = {
      shiftwidth = 2;
      tabstop = 2;
      relativenumber = true;
      number = true;
      termguicolors = true;
      mouse = "a";
      ignorecase = true;
      smartcase = true;
      updatetime = 250;
      signcolumn = "yes";
      clipboard = "unnamedplus";
      undofile = true;
      breakindent = true;
      cursorline = true;
      scrolloff = 8;
    };

    keymaps = [
      { mode = "n"; key = "<C-t>"; action = ":b#<CR>"; options = { silent = true; desc = "Toggle last buffer"; }; }
      { mode = "n"; key = "<C-w>n"; action = ":bn<CR>"; options = { silent = true; desc = "Next buffer"; }; }
      { mode = "n"; key = "<C-w>p"; action = ":bp<CR>"; options = { silent = true; desc = "Previous buffer"; }; }
      { mode = "n"; key = "<C-w>d"; action = ":bd<CR>"; options = { silent = true; desc = "Delete buffer"; }; }
      { mode = "n"; key = "<C-w>t"; action = ":NvimTreeToggle<CR>"; options = { silent = true; desc = "Toggle file tree"; }; }
      { mode = "n"; key = "<Esc>"; action = "<cmd>nohlsearch<CR>"; options = { desc = "Clear search highlight"; }; }
    ];

    plugins = {
      treesitter = {
        enable = true;
        settings = {
          highlight.enable = true;
          indent.enable = true;
        };
      };

      lsp = {
        enable = true;
        servers = {
          lua_ls.enable = true;
          pyright.enable = true;
          ts_ls.enable = true;
          gopls.enable = true;
          nil_ls.enable = true;
          rust_analyzer = {
            enable = true;
            installCargo = false;
            installRustc = false;
          };
        };
        keymaps = {
          lspBuf = {
            "gd" = "definition";
            "gD" = "declaration";
            "gr" = "references";
            "gi" = "implementation";
            "K" = "hover";
            "<leader>ca" = "code_action";
            "<leader>rn" = "rename";
            "<leader>D" = "type_definition";
          };
          diagnostic = {
            "[d" = "goto_prev";
            "]d" = "goto_next";
          };
          extra = [
            {
              mode = "n";
              key = "<leader>e";
              action.__raw = "vim.diagnostic.open_float";
              options.desc = "Show diagnostic";
            }
          ];
        };
      };

      cmp = {
        enable = true;
        autoEnableSources = true;
        settings = {
          sources = [
            { name = "nvim_lsp"; }
            { name = "luasnip"; }
            { name = "buffer"; }
            { name = "path"; }
          ];
          snippet.expand = ''
            function(args)
              require('luasnip').lsp_expand(args.body)
            end
          '';
          mapping = {
            "<C-b>" = "cmp.mapping.scroll_docs(-4)";
            "<C-f>" = "cmp.mapping.scroll_docs(4)";
            "<C-Space>" = "cmp.mapping.complete()";
            "<C-e>" = "cmp.mapping.abort()";
            "<CR>" = "cmp.mapping.confirm({ select = true })";
            "<Tab>" = ''
              cmp.mapping(function(fallback)
                local luasnip = require('luasnip')
                if cmp.visible() then
                  cmp.select_next_item()
                elseif luasnip.expand_or_jumpable() then
                  luasnip.expand_or_jump()
                else
                  fallback()
                end
              end, { 'i', 's' })
            '';
            "<S-Tab>" = ''
              cmp.mapping(function(fallback)
                local luasnip = require('luasnip')
                if cmp.visible() then
                  cmp.select_prev_item()
                elseif luasnip.jumpable(-1) then
                  luasnip.jump(-1)
                else
                  fallback()
                end
              end, { 'i', 's' })
            '';
          };
        };
      };

      luasnip.enable = true;
      friendly-snippets.enable = true;

      telescope = {
        enable = true;
        keymaps = {
          "<leader>ff" = { action = "find_files"; options.desc = "Find files"; };
          "<leader>fg" = { action = "live_grep"; options.desc = "Live grep"; };
          "<leader>fb" = { action = "buffers"; options.desc = "Buffers"; };
          "<leader>fh" = { action = "help_tags"; options.desc = "Help tags"; };
          "<leader>fr" = { action = "oldfiles"; options.desc = "Recent files"; };
        };
        extensions.fzf-native.enable = true;
      };

      nvim-tree = {
        enable = true;
        settings = {
          view = {
            side = "left";
            adaptive_size = true;
          };
          renderer.icons.show.git = false;
        };
      };

      lualine = {
        enable = true;
        settings.options = {
          theme = "auto";
          component_separators = "|";
          section_separators = "";
        };
      };

      web-devicons.enable = true;
      bufferline.enable = true;
      which-key.enable = true;
      indent-blankline.enable = true;
      gitsigns.enable = true;
      nvim-autopairs.enable = true;
      comment.enable = true;

      toggleterm = {
        enable = true;
        settings = {
          open_mapping = "[[<C-\\>]]";
          direction = "float";
        };
      };
    };

    extraPlugins = with pkgs.vimPlugins; [
      sonokai
      vim-sleuth
      alpha-nvim
    ];

    extraConfigLua = ''
      -- Dashboard
      local alpha = require('alpha')
      local dashboard = require('alpha.themes.dashboard')
      dashboard.section.buttons.val = {
        dashboard.button('f', '  Find file', ':Telescope find_files<CR>'),
        dashboard.button('r', '  Recent files', ':Telescope oldfiles<CR>'),
        dashboard.button('g', '  Grep text', ':Telescope live_grep<CR>'),
        dashboard.button('e', '  New file', ':ene <BAR> startinsert<CR>'),
        dashboard.button('q', '  Quit', ':qa<CR>'),
      }
      alpha.setup(dashboard.config)
    '';
  };
}
