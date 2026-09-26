-- Highlight groups, linked to standard groups so any colorscheme works.
local M = {}

local groups = {
  DbgridCellHeader = { link = "Title" },
  DbgridCellHeaderActive = { link = "Function" },
  DbgridCellRule = { link = "NonText" },
  DbgridCellId = { link = "Comment" },
  DbgridActiveBar = { link = "CursorLineNr" },
  DbgridStatusOk = { link = "DiagnosticOk" },
  DbgridStatusError = { link = "DiagnosticError" },
  DbgridStatusWarn = { link = "DiagnosticWarn" },
  DbgridStatusRunning = { link = "DiagnosticInfo" },
  DbgridStatusStale = { link = "DiagnosticHint" },
  DbgridStatusIdle = { link = "Comment" },
  DbgridStatusDim = { link = "Comment" },
  DbgridColumnHeader = { link = "Title" },
  DbgridSeparator = { link = "NonText" },
  DbgridRule = { link = "NonText" },
  DbgridNull = { link = "Comment" },
  DbgridNumber = { link = "Number" },
  DbgridBool = { link = "Boolean" },
  DbgridCurrentColumn = { link = "CursorColumn" },
  DbgridNotice = { link = "DiagnosticInfo" },
  DbgridWarn = { link = "DiagnosticWarn" },
  DbgridError = { link = "DiagnosticError" },
  DbgridTag = { link = "Special" },
  DbgridFooter = { link = "Comment" },
  DbgridSetTitle = { link = "Title" },
  DbgridKey = { link = "Special" },
  DbgridWinbar = { link = "WinBar" },
  DbgridWinbarConn = { link = "Function" },
  DbgridWinbarTag = { link = "Special" },
  DbgridWinbarTitle = { link = "Title" },
  DbgridWinbarDim = { link = "Comment" },
  DbgridWinbarOk = { link = "DiagnosticOk" },
  DbgridWinbarError = { link = "DiagnosticError" },
  DbgridWinbarWarn = { link = "DiagnosticWarn" },
  DbgridWinbarAgent = { link = "Special" },
  DbgridSchemaTable = { link = "Title" },
  DbgridSchemaColumn = { link = "Identifier" },
  DbgridSchemaType = { link = "Type" },
  DbgridSchemaIndex = { link = "Special" },
  DbgridSchemaDim = { link = "Comment" },
  DbgridFindingWarn = { link = "DiagnosticWarn" },
  DbgridFindingInfo = { link = "DiagnosticInfo" },
}

function M.setup()
  for name, spec in pairs(groups) do
    local s = vim.deepcopy(spec)
    s.default = true
    vim.api.nvim_set_hl(0, name, s)
  end
end

return M
