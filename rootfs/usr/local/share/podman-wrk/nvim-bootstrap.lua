-- ===========================================================================
--  podman-wrk :: build-time Neovim bootstrap
--
--  Run as:
--    WRK_BUILD=1 nvim --headless -c "luafile /usr/local/share/podman-wrk/nvim-bootstrap.lua"
--
--  Note the invocation: `nvim -l script.lua` does NOT source init.lua, so
--  lazy.nvim never runs and neither :Lazy nor mason exist. `-c luafile` runs
--  after a normal startup, which is what we need. The script quits by itself,
--  so do not append a `-c qa` - that is precisely the race described below.
--
--  Installs every Mason package and tree-sitter parser the environment needs
--  and, crucially, WAITS for them. `nvim --headless -c "MasonInstall ..." -c qa`
--  does not: it fires the installs and then quits, and mason kills them on the
--  way out ("Neovim is exiting while packages are still installing"). The
--  result looks like a successful build but produces an image with no language
--  servers - which defeats the entire point of an offline image.
--
--  Exits non-zero when nothing could be installed, so the build fails loudly
--  instead of silently shipping a crippled image.
-- ===========================================================================

local TIMEOUT_MS = tonumber(vim.env.WRK_BOOTSTRAP_TIMEOUT or "") or (30 * 60 * 1000)

local function out(fmt, ...)
  io.stdout:write(string.format(fmt, ...) .. "\n")
  io.stdout:flush()
end

-- ---------------------------------------------------------------------------
--  Force the lazy-loaded plugins to load now: their user commands and Lua
--  modules do not exist until they do.
-- ---------------------------------------------------------------------------
local function load(plugin)
  pcall(vim.cmd, "Lazy! load " .. plugin)
end

load("mason.nvim")
load("mason-lspconfig.nvim")
load("nvim-treesitter")

-- ---------------------------------------------------------------------------
--  Mason
-- ---------------------------------------------------------------------------
local function install_mason()
  local ok, registry = pcall(require, "mason-registry")
  if not ok then
    out("mason: registry unavailable - skipping")
    return 0
  end

  pcall(function() registry.refresh() end)

  local wanted = {}
  for name in (vim.env.WRK_NVIM_LSP or ""):gmatch("%S+") do
    wanted[#wanted + 1] = name
  end

  local pending, failed = 0, {}

  for _, name in ipairs(wanted) do
    local got, pkg = pcall(registry.get_package, name)
    if not got then
      out("mason: unknown package %q - skipping", name)
      failed[#failed + 1] = name
    elseif pkg:is_installed() then
      out("mason: %s already installed", name)
    else
      pending = pending + 1
      out("mason: installing %s ...", name)
      local handle = pkg:install()
      handle:once("closed", function()
        pending = pending - 1
        if pkg:is_installed() then
          out("mason: %s done", name)
        else
          out("mason: %s FAILED", name)
          failed[#failed + 1] = name
        end
      end)
    end
  end

  -- LazyVim's language extras queue their own installs through
  -- ensure_installed the moment mason loads; those are exactly the ones that
  -- get killed by a premature exit, so wait for them as well.
  local function still_installing()
    local got, list = pcall(registry.get_installing_packages)
    if got and type(list) == "table" then return #list > 0 end
    return false
  end

  vim.wait(TIMEOUT_MS, function()
    return pending == 0 and not still_installing()
  end, 500)

  local installed = {}
  pcall(function() installed = registry.get_installed_package_names() or {} end)
  out("mason: %d package(s) installed", #installed)
  if #failed > 0 then
    out("mason: %d failure(s): %s", #failed, table.concat(failed, " "))
  end
  return #installed
end

-- ---------------------------------------------------------------------------
--  Tree-sitter
--
--  Two incompatible generations are in the wild and LazyVim has moved between
--  them, so handle both:
--    * main branch   - require("nvim-treesitter").install(langs) returns an
--                      awaitable object with :wait(timeout)
--    * master branch - the :TSUpdateSync / :TSInstallSync commands
--  Either way we block until the parsers are actually on disk. Without that
--  the image ships a treesitter with nothing to highlight with.
-- ---------------------------------------------------------------------------
local DEFAULT_TS_LANGS = {
  "bash", "c", "cpp", "css", "diff", "dockerfile", "git_config", "gitcommit",
  "gitignore", "go", "html", "javascript", "json", "lua", "luadoc", "make",
  "markdown", "markdown_inline", "printf", "python", "query", "regex", "rust",
  "sql", "toml", "tsx", "typescript", "vim", "vimdoc", "xml", "yaml",
}

local function parser_count()
  local seen = {}
  for _, dir in ipairs(vim.api.nvim_get_runtime_file("parser", true)) do
    local ok, iter = pcall(vim.fs.dir, dir)
    if ok then
      for name in iter do
        seen[name] = true
      end
    end
  end
  return vim.tbl_count(seen)
end

local function install_treesitter()
  local langs = {}
  for l in (vim.env.WRK_NVIM_TS or ""):gmatch("%S+") do
    langs[#langs + 1] = l
  end
  if #langs == 0 then langs = DEFAULT_TS_LANGS end

  local ok, nts = pcall(require, "nvim-treesitter")

  if ok and type(nts.install) == "function" then
    out("treesitter: installing %d language(s) via the main-branch API ...", #langs)
    local started, handle = pcall(nts.install, langs)
    if started and type(handle) == "table" and type(handle.wait) == "function" then
      -- pwait is the non-throwing variant where available.
      local waiter = type(handle.pwait) == "function" and handle.pwait or handle.wait
      pcall(waiter, handle, TIMEOUT_MS)
    else
      -- Could not await it explicitly; fall back to polling the parser dir.
      local target = parser_count()
      vim.wait(TIMEOUT_MS, function()
        local now = parser_count()
        if now > target then target = now end
        return false
      end, 1000)
    end
  elseif vim.fn.exists(":TSUpdateSync") == 2 then
    out("treesitter: running TSUpdateSync ...")
    pcall(vim.cmd, "TSUpdateSync")
  elseif vim.fn.exists(":TSInstallSync") == 2 then
    out("treesitter: running TSInstallSync ...")
    pcall(vim.cmd, "TSInstallSync " .. table.concat(langs, " "))
  else
    out("treesitter: no way to install parsers found")
  end

  local n = parser_count()
  if ok and type(nts.get_installed) == "function" then
    local got, list = pcall(nts.get_installed)
    if got and type(list) == "table" then
      out("treesitter: %d language(s) registered as installed", #list)
    end
  end
  out("treesitter: %d parser file(s) on disk", n)
  return n
end

-- ---------------------------------------------------------------------------
local mason_count = install_mason()
local parser_count = install_treesitter()

out("bootstrap: mason=%d parsers=%d", mason_count, parser_count)

if mason_count == 0 and parser_count == 0 then
  out("bootstrap: nothing was installed - refusing to produce a broken image")
  vim.cmd("cquit 1")
end

vim.cmd("qa!")
