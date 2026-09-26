-- Runs every tests/*_spec.lua file. Usage: nvim --headless -u tests/minimal_init.lua -l tests/run.lua [filter]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = root .. "/tests/?.lua;" .. package.path
local filter = _G.arg and _G.arg[1] or nil
local H = require("harness")
_G.H = H
local files = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(files)
for _, f in ipairs(files) do
  if not filter or f:find(filter, 1, true) then
    io.write("\n" .. vim.fn.fnamemodify(f, ":t") .. "\n")
    dofile(f)
  end
end
H.finish()
