-- ===========================================================================
--  podman-wrk :: Neovim options (loaded by LazyVim before plugins)
-- ===========================================================================

local opt = vim.opt

opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.wrap = false
opt.signcolumn = "yes"
opt.termguicolors = true

opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.softtabstop = 4
opt.smartindent = true

opt.ignorecase = true
opt.smartcase = true
opt.inccommand = "split"

opt.splitright = true
opt.splitbelow = true

opt.updatetime = 200
opt.timeoutlen = 400
opt.confirm = true

-- Persistent undo lives in $HOME, which is part of the container's writable
-- layer, so undo history survives across `wrk shell` sessions.
opt.undofile = true
opt.undolevels = 10000
opt.swapfile = false

-- Shares the system clipboard with the host through wl-clipboard / xclip when
-- the socket is forwarded; harmless otherwise.
opt.clipboard = "unnamedplus"

-- Grep through ripgrep, which is installed in the image.
opt.grepprg = "rg --vimgrep --smart-case"
opt.grepformat = "%f:%l:%c:%m"

-- LazyVim reads these globals.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.g.lazyvim_picker = "auto"
vim.g.autoformat = true
