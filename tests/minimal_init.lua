-- Minimal runtime for headless tests: only this plugin on the runtimepath.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
