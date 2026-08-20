-- ===========================================================================
--  podman-wrk :: lazy.nvim bootstrap
--  Based on the LazyVim starter, hardened for a machine with NO INTERNET.
--  Everything is downloaded once at image build time; at runtime lazy.nvim
--  must never reach for the network.
-- ===========================================================================

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local out = vim.fn.system({
    "git", "clone", "--filter=blob:none", "--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazypath,
  })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "podman-wrk: lazy.nvim is missing and cannot be cloned offline.\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nRebuild the image on a machine with internet access.", "" },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end

vim.opt.rtp:prepend(lazypath)

-- WRK_BUILD=1 is exported only by the Containerfile's headless bootstrap runs.
local building = vim.env.WRK_BUILD == "1"

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "plugins" },
  },
  defaults = { lazy = false, version = false },
  install = {
    -- At build time: pull everything. At runtime: never try to fetch.
    missing = building,
    colorscheme = { "catppuccin", "tokyonight", "habamax" },
  },
  checker = { enabled = false },                   -- no update checks offline
  change_detection = { enabled = false, notify = false },
  rocks = { enabled = false, hererocks = false },  -- luarocks needs the network
  pkg = { enabled = true, sources = { "lazy" } },  -- no rockspec resolution
  ui = { border = "rounded" },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin", "netrwPlugin",
      },
    },
  },
})
