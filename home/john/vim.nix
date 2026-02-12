{ pkgs, pkgs-unstable, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    vimdiffAlias = true;
    package = pkgs-unstable.neovim-unwrapped;

    plugins = with pkgs.vimPlugins; [
      # Colorscheme
      sonokai

      # Treesitter
      (nvim-treesitter.withAllGrammars)

      # LSP
      nvim-lspconfig

      # Completion
      nvim-cmp
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      cmp_luasnip
      luasnip
      friendly-snippets

      # Telescope
      telescope-nvim
      telescope-fzf-native-nvim
      plenary-nvim

      # File explorer
      nvim-tree-lua
      nvim-web-devicons

      # UI
      lualine-nvim
      bufferline-nvim
      alpha-nvim
      which-key-nvim
      indent-blankline-nvim

      # Git
      gitsigns-nvim

      # Editing
      nvim-autopairs
      comment-nvim
      vim-sleuth

      # Terminal
      toggleterm-nvim

      # Copilot
      copilot-lua
      copilot-cmp
      CopilotChat-nvim
    ];

    extraPackages = [
      pkgs-unstable.lua-language-server
      pkgs-unstable.pyright
      pkgs-unstable.nodePackages.typescript-language-server
      pkgs-unstable.gopls
      pkgs-unstable.nil
      pkgs-unstable.rust-analyzer
    ];

    extraLuaConfig = ''
      -- Leader key
      vim.g.mapleader = '\\'
      vim.g.maplocalleader = '\\'

      -- Options
      vim.opt.shiftwidth = 2
      vim.opt.tabstop = 2
      vim.opt.relativenumber = true
      vim.opt.number = true
      vim.opt.termguicolors = true
      vim.opt.mouse = 'a'
      vim.opt.ignorecase = true
      vim.opt.smartcase = true
      vim.opt.updatetime = 250
      vim.opt.signcolumn = 'yes'
      vim.opt.clipboard = 'unnamedplus'
      vim.opt.undofile = true
      vim.opt.breakindent = true
      vim.opt.cursorline = true
      vim.opt.scrolloff = 8

      -- Colorscheme
      vim.g.sonokai_transparent_background = 1
      vim.cmd.colorscheme('sonokai')

      -- Buffer navigation (matching LunarVim keymaps)
      vim.keymap.set('n', '<C-t>', ':b#<CR>', { silent = true, desc = 'Toggle last buffer' })
      vim.keymap.set('n', '<C-w>n', ':bn<CR>', { silent = true, desc = 'Next buffer' })
      vim.keymap.set('n', '<C-w>p', ':bp<CR>', { silent = true, desc = 'Previous buffer' })
      vim.keymap.set('n', '<C-w>d', ':bd<CR>', { silent = true, desc = 'Delete buffer' })
      vim.keymap.set('n', '<C-w>t', ':NvimTreeToggle<CR>', { silent = true, desc = 'Toggle file tree' })
      vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })

      -- Treesitter (grammars are pre-compiled by Nix, use neovim built-in)
      vim.api.nvim_create_autocmd('FileType', {
        callback = function(args)
          pcall(vim.treesitter.start, args.buf)
        end,
      })

      -- LSP (neovim 0.11+ native API, configs from nvim-lspconfig registry)
      vim.lsp.config('*', {
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
      })
      vim.lsp.enable({ 'lua_ls', 'pyright', 'ts_ls', 'gopls', 'nil_ls', 'rust_analyzer' })

      vim.api.nvim_create_autocmd('LspAttach', {
        callback = function(event)
          local map = function(keys, func, desc)
            vim.keymap.set('n', keys, func, { buffer = event.buf, desc = desc })
          end
          map('gd', vim.lsp.buf.definition, 'Go to definition')
          map('gD', vim.lsp.buf.declaration, 'Go to declaration')
          map('gr', vim.lsp.buf.references, 'Go to references')
          map('gi', vim.lsp.buf.implementation, 'Go to implementation')
          map('K', vim.lsp.buf.hover, 'Hover documentation')
          map('<leader>ca', vim.lsp.buf.code_action, 'Code action')
          map('<leader>rn', vim.lsp.buf.rename, 'Rename')
          map('<leader>D', vim.lsp.buf.type_definition, 'Type definition')
          map('[d', vim.diagnostic.goto_prev, 'Previous diagnostic')
          map(']d', vim.diagnostic.goto_next, 'Next diagnostic')
          map('<leader>e', vim.diagnostic.open_float, 'Show diagnostic')
        end,
      })

      -- Completion
      local cmp = require('cmp')
      local luasnip = require('luasnip')
      require('luasnip.loaders.from_vscode').lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ['<C-b>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<C-Space>'] = cmp.mapping.complete(),
          ['<C-e>'] = cmp.mapping.abort(),
          ['<CR>'] = cmp.mapping.confirm({ select = true }),
          ['<Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { 'i', 's' }),
          ['<S-Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { 'i', 's' }),
        }),
        sources = cmp.config.sources({
          { name = 'copilot' },
          { name = 'nvim_lsp' },
          { name = 'luasnip' },
        }, {
          { name = 'buffer' },
          { name = 'path' },
        }),
      })

      -- Telescope
      local telescope = require('telescope')
      telescope.setup({})
      telescope.load_extension('fzf')

      local builtin = require('telescope.builtin')
      vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = 'Find files' })
      vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Live grep' })
      vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Buffers' })
      vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = 'Help tags' })
      vim.keymap.set('n', '<leader>fr', builtin.oldfiles, { desc = 'Recent files' })

      -- File explorer
      require('nvim-tree').setup({
        view = {
          side = 'left',
          adaptive_size = true,
        },
        renderer = {
          icons = {
            show = { git = false },
          },
        },
      })

      -- Statusline
      require('lualine').setup({
        options = {
          theme = 'auto',
          component_separators = '|',
          section_separators = "",
        },
      })

      -- Bufferline
      require('bufferline').setup({})

      -- Git signs
      require('gitsigns').setup()

      -- Autopairs
      require('nvim-autopairs').setup()

      -- Comment (gcc to comment line, gc in visual mode)
      require('Comment').setup()

      -- Which-key
      require('which-key').setup()

      -- Terminal (C-\ to toggle floating terminal)
      require('toggleterm').setup({
        open_mapping = [[<C-\>]],
        direction = 'float',
      })

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

      -- Indent guides
      require('ibl').setup()

      -- Copilot
      require('copilot').setup({
        suggestion = {
          auto_trigger = true,
          keymap = {
            accept = '<C-l>',
            next = '<C-j>',
            prev = '<C-k>',
            dismiss = '<C-h>',
          },
        },
        panel = { enabled = false },
      })

      require('copilot_cmp').setup()

      vim.keymap.set('n', '<C-s>', function()
        require('copilot.suggestion').toggle_auto_trigger()
      end, { silent = true, desc = 'Toggle Copilot auto-trigger' })

      -- CopilotChat
      require('CopilotChat').setup({})

      vim.keymap.set('v', '<leader>ccq', function()
        local input = vim.fn.input('Quick Chat: ')
        if input ~= "" then
          require('CopilotChat').ask(input, { selection = require('CopilotChat.select').buffer })
        end
      end, { desc = 'Copilot Quick Chat' })
    '';
  };
}
