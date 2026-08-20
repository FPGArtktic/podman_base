-- ===========================================================================
--  podman-wrk :: offline guards
--
--  LazyVim's language extras declare `ensure_installed` lists for mason and
--  nvim-treesitter. That is exactly what we want while the image is being
--  built (WRK_BUILD=1) - and exactly what we do NOT want afterwards, because
--  on an air-gapped machine every missing entry turns into a failed download
--  and a wall of error notifications on startup.
--
--  So: honour the lists during the build, clear them at runtime.
-- ===========================================================================

local building = vim.env.WRK_BUILD == "1"

-- `optional = true` means the spec is only applied if the plugin is already
-- part of the resolved spec, so listing something LazyVim does not use is
-- harmless.
--
-- Only the current mason.nvim names (mason-org/*) are listed here. lazy.nvim
-- normalises the old williamboman/* names onto these, and naming the old ones
-- explicitly makes it print a "was renamed to" notice on every startup.
local function no_ensure(name)
  return {
    name,
    optional = true,
    opts = function(_, opts)
      if not building then
        opts.ensure_installed = {}
        opts.automatic_installation = false
      end
    end,
  }
end

return {
  no_ensure("mason-org/mason.nvim"),
  no_ensure("mason-org/mason-lspconfig.nvim"),
  no_ensure("WhoIsSethDaniel/mason-tool-installer.nvim"),
  no_ensure("jay-babu/mason-nvim-dap.nvim"),

  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if building then
        opts.ensure_installed = opts.ensure_installed or {}
        -- Keep in step with DEFAULT_TS_LANGS in nvim-bootstrap.lua. Only names
        -- the installed nvim-treesitter actually knows: "jsonc" for instance
        -- is rejected by the main branch and just prints a warning.
        vim.list_extend(opts.ensure_installed, {
          "bash", "c", "cpp", "css", "diff", "dockerfile", "git_config",
          "gitcommit", "gitignore", "go", "html", "javascript", "json",
          "lua", "luadoc", "make", "markdown", "markdown_inline", "printf",
          "python", "query", "regex", "rust", "sql", "toml", "tsx",
          "typescript", "vim", "vimdoc", "xml", "yaml",
        })
      else
        -- Runtime: use whatever was compiled into the image, fetch nothing.
        opts.ensure_installed = {}
        opts.auto_install = false
      end
      return opts
    end,
  },

  -- Mason binaries must be on PATH for the LSP servers baked into the image.
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = { PATH = "prepend" },
  },
}
