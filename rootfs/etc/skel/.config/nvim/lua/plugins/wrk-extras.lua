-- ===========================================================================
--  podman-wrk :: LazyVim "extras" selection
--
--  Importing a module that does not exist in the installed LazyVim version is
--  a hard startup error, and on the very first run LazyVim is not on disk yet.
--  So instead of a static list we probe the installed LazyVim tree and only
--  import what is actually there. The Containerfile runs `Lazy! sync` twice for
--  exactly this reason: pass 1 installs LazyVim, pass 2 picks up these extras.
-- ===========================================================================

local wanted = {
  -- languages -------------------------------------------------------------
  "lang.json",
  "lang.yaml",
  "lang.toml",
  "lang.markdown",
  "lang.python",
  "lang.typescript",
  "lang.go",
  "lang.clangd",
  "lang.docker",
  "lang.git",
  "lang.sql",
  -- editing / UI ----------------------------------------------------------
  "coding.mini-surround",
  "editor.telescope",
  "editor.inc-rename",
  "util.mini-hipatterns",
  "formatting.prettier",
  -- debugging -------------------------------------------------------------
  "dap.core",
}

local root = vim.fn.stdpath("data") .. "/lazy/LazyVim/lua/lazyvim/plugins/extras/"
local uv = vim.uv or vim.loop
local spec = {}

for _, mod in ipairs(wanted) do
  local path = root .. mod:gsub("%.", "/") .. ".lua"
  if uv.fs_stat(path) then
    spec[#spec + 1] = { import = "lazyvim.plugins.extras." .. mod }
  end
end

return spec
