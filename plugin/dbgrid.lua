if vim.g.loaded_dbgrid then
  return
end
vim.g.loaded_dbgrid = true

vim.api.nvim_create_user_command("Dbgrid", function(opts)
  require("dbgrid.commands").run(opts)
end, {
  nargs = "*",
  desc = "dbgrid: SQL notebooks",
  complete = function(arglead, cmdline)
    return require("dbgrid.commands").complete(arglead, cmdline)
  end,
})

-- Attach to notebook files opened by hand (:edit, file explorer, ...).
vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("dbgrid_attach", { clear = true }),
  pattern = "*.sql",
  callback = function(ev)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then
        pcall(require("dbgrid").attach, ev.buf)
      end
    end)
  end,
})

require("dbgrid.highlights").setup()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("dbgrid_highlights", { clear = true }),
  callback = function()
    require("dbgrid.highlights").setup()
  end,
})
