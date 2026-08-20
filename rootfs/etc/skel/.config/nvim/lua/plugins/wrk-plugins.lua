-- ===========================================================================
--  podman-wrk :: curated additions on top of LazyVim
-- ===========================================================================

return {
  -- --- colours -------------------------------------------------------------
  { "catppuccin/nvim", name = "catppuccin", priority = 1000, opts = { flavour = "mocha" } },
  { "LazyVim/LazyVim", opts = { colorscheme = "catppuccin" } },

  -- --- git -----------------------------------------------------------------
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview: working tree" },
      { "<leader>gV", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
    },
    opts = {},
  },

  -- lazygit is installed as a real binary, so wire it to the terminal helper.
  {
    "folke/snacks.nvim",
    optional = true,
    keys = {
      {
        "<leader>gg",
        function() Snacks.lazygit({ cwd = LazyVim.root.git() }) end,
        desc = "Lazygit (repo root)",
      },
      { "<leader>gG", function() Snacks.lazygit() end, desc = "Lazygit (cwd)" },
    },
  },

  -- --- navigation ----------------------------------------------------------
  {
    "stevearc/oil.nvim",
    cmd = "Oil",
    keys = { { "-", "<cmd>Oil<cr>", desc = "Open parent directory (oil)" } },
    opts = { view_options = { show_hidden = true } },
  },

  -- --- diagnostics / todo --------------------------------------------------
  { "folke/trouble.nvim", optional = true },
  { "folke/todo-comments.nvim", optional = true },

  -- --- LSP: servers we bake in with Mason at build time --------------------
  {
    "neovim/nvim-lspconfig",
    opts = {
      diagnostics = {
        virtual_text = { spacing = 4, prefix = "\u{25cf}" },
        severity_sort = true,
      },
      servers = {
        bashls = {},
        lua_ls = {
          settings = {
            Lua = {
              workspace = { checkThirdParty = false },
              telemetry = { enable = false },
              hint = { enable = true },
            },
          },
        },
      },
    },
  },

  -- --- formatting ----------------------------------------------------------
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters_by_ft = {
        sh = { "shfmt" },
        bash = { "shfmt" },
        zsh = { "shfmt" },
        lua = { "stylua" },
      },
    },
  },

  -- --- linting -------------------------------------------------------------
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = {
      -- shellcheck is a real pacman package in the image; do not reference
      -- linters that are not installed - nvim-lint errors out on those.
      linters_by_ft = {
        sh = { "shellcheck" },
        bash = { "shellcheck" },
      },
    },
  },
}
