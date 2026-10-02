-- Completion items from the schema cache, aware of the statement around the cursor.
local cells = require("dbgrid.cells")
local sqlmod = require("dbgrid.sql")
local schema = require("dbgrid.schema")
local state_mod = require("dbgrid.state")
local config = require("dbgrid.config")

local M = {}

M.KIND = { column = 5, table = 7, keyword = 14, ["function"] = 3, schema = 9, alias = 6, enum = 13 }

---@class dbgrid.CompletionItem
---@field label string
---@field kind integer      LSP CompletionItemKind
---@field kind_name string
---@field detail string?
---@field documentation string?
---@field insert string?
---@field sort string
---@field filter string?

---Context at a buffer position.
---@param buf integer
---@param row integer 1-based
---@param col integer 0-based byte column
function M.context(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)
  local qualifier, word = before:match('([%w_"%.]+)%.([%w_"]*)$')
  if not qualifier then
    word = before:match('([%w_"]*)$') or ""
  end
  -- "{{name" completes cell references and parameters, ":name" parameters
  local in_ref = before:match("{{%s*[%w_%-]*$") ~= nil
  local in_param = not in_ref and before:match("[^:]:[%w_]*$") ~= nil and not before:match("::[%w_]*$")
  if in_ref then
    word = before:match("([%w_%-]*)$") or ""
    qualifier = nil
  end
  local cell = cells.cell_at(buf, row)
  local sql_text = cell and cells.body_text(cell) or ""
  local refs = sqlmod.referenced_tables(sql_text)
  return {
    qualifier = qualifier,
    word = word or "",
    start_col = col - #(word or ""),
    refs = refs,
    cell = cell,
    in_ref = in_ref,
    in_param = in_param,
    after_keyword = before:lower():match('([%a_]+)%s+[%w_"%.]*$'),
  }
end

---Adapter of the buffer's connection (keywords, functions), Postgres by default.
---@param buf integer
---@return dbgrid.Adapter?
local function adapter_for(buf)
  local s = state_mod.get(buf)
  local conn = s and s.nb.meta.connection and require("dbgrid.connections").get(s.nb.meta.connection)
  local a = conn and require("dbgrid.adapters").for_connection(conn)
  return a or require("dbgrid.adapters").get("postgres")
end

---Cell references and parameters of the notebook as completion items.
---@param buf integer
---@param ctx table
---@param add fun(item: dbgrid.CompletionItem)
local function notebook_items(buf, ctx, add)
  local s = state_mod.get(buf)
  local list = cells.parse(buf)
  if ctx.in_ref then
    for _, c in ipairs(list) do
      if not ctx.cell or c.id ~= ctx.cell.id then
        local name = cells.ref_name(c)
        add({
          label = name,
          kind = M.KIND.alias,
          kind_name = "cell",
          detail = "cell " .. cells.label(c, 40),
          documentation = cells.body_text(c),
          insert = name .. "}}",
          sort = "0" .. name,
        })
      end
    end
  end
  if s then
    for _, p in ipairs(require("dbgrid.expand").notebook_params(s)) do
      add({
        label = p.name,
        kind = M.KIND.enum,
        kind_name = "parameter",
        detail = p.value and ("= " .. p.value) or "no value yet",
        insert = ctx.in_ref and (p.name .. "}}") or p.name,
        sort = "0" .. p.name,
      })
    end
  end
end

---@param buf integer
---@return dbgrid.SchemaData?
local function schema_for(buf)
  local s = state_mod.get(buf)
  if not s or not s.nb.meta.connection then
    return nil
  end
  local conn = require("dbgrid.connections").get(s.nb.meta.connection)
  if not conn then
    return nil
  end
  local loaded = schema.loaded(conn)
  if not loaded then
    schema.get(conn, function() end)
  end
  return loaded
end

---@param buf integer
---@param row integer
---@param col integer
---@return dbgrid.CompletionItem[], table ctx
function M.items(buf, row, col)
  local ctx = M.context(buf, row, col)
  local sch = schema_for(buf)
  local items = {}
  local seen = {}
  local function add(item)
    local key = item.kind_name .. ":" .. item.label
    if seen[key] then
      return
    end
    seen[key] = true
    items[#items + 1] = item
  end
  local function column_items(tbl, prefix_sort, via)
    for _, c in ipairs(tbl.columns or {}) do
      add({
        label = c.name,
        kind = M.KIND.column,
        kind_name = "column",
        detail = c.type .. (via and ("  " .. via) or ""),
        documentation = string.format(
          "%s.%s %s%s%s",
          schema.display_name(tbl),
          c.name,
          c.type,
          c.notnull and " not null" or "",
          c.default and (" default " .. c.default) or ""
        ),
        sort = prefix_sort .. c.name,
      })
    end
  end
  if ctx.in_ref or ctx.in_param then
    notebook_items(buf, ctx, add)
    return items, ctx
  end
  if ctx.qualifier then
    if not sch then
      return items, ctx
    end
    local q = ctx.qualifier:gsub('"', "")
    -- alias?
    for _, r in ipairs(ctx.refs) do
      if r.alias and r.alias:lower() == q:lower() then
        local t = schema.find_table(sch, r.name)
        if t then
          column_items(t, "0", schema.display_name(t))
        end
      end
    end
    local t = schema.find_table(sch, q)
    if t then
      column_items(t, "0", nil)
    end
    -- schema name → tables
    for _, tbl in ipairs(sch.tables) do
      if tbl.schema:lower() == q:lower() then
        add({
          label = tbl.name,
          kind = M.KIND.table,
          kind_name = "table",
          detail = string.format("~%d rows", tbl.rows or 0),
          sort = "1" .. tbl.name,
        })
      end
    end
    return items, ctx
  end
  if sch then
    -- columns of referenced tables first
    for _, r in ipairs(ctx.refs) do
      local t = schema.find_table(sch, r.name)
      if t then
        column_items(t, "0", (r.alias and (r.alias .. " = ") or "") .. schema.display_name(t))
        if r.alias then
          add({
            label = r.alias,
            kind = M.KIND.alias,
            kind_name = "alias",
            detail = schema.display_name(t),
            sort = "0" .. r.alias,
          })
        end
      end
    end
    for _, tbl in ipairs(sch.tables) do
      add({
        label = schema.display_name(tbl),
        kind = M.KIND.table,
        kind_name = "table",
        detail = string.format(
          "%s · ~%d rows · %d cols",
          ({ r = "table", v = "view", m = "matview", p = "partitioned", f = "foreign" })[tbl.kind] or tbl.kind,
          tbl.rows or 0,
          #(tbl.columns or {})
        ),
        documentation = table.concat(schema.describe_lines(tbl, sch), "\n"),
        sort = "1" .. tbl.name,
      })
    end
    for _, sname in ipairs(sch.schemas) do
      add({ label = sname, kind = M.KIND.schema, kind_name = "schema", sort = "3" .. sname })
    end
    -- all other columns, lower priority
    if #ctx.refs == 0 then
      for _, tbl in ipairs(sch.tables) do
        for _, c in ipairs(tbl.columns or {}) do
          add({
            label = c.name,
            kind = M.KIND.column,
            kind_name = "column",
            detail = c.type .. "  " .. schema.display_name(tbl),
            sort = "2" .. c.name,
          })
        end
      end
    end
  end
  if config.get().completion.keywords then
    local adapter = adapter_for(buf)
    for _, k in ipairs(adapter and adapter.keywords or {}) do
      add({
        label = k,
        kind = M.KIND.keyword,
        kind_name = "keyword",
        sort = "4" .. k,
        insert = ctx.word:match("^%u") and k:upper() or k,
      })
    end
    for _, f in ipairs(adapter and adapter.functions or {}) do
      add({ label = f, kind = M.KIND["function"], kind_name = "function", sort = "5" .. f, insert = f .. "(" })
    end
  end
  return items, ctx
end

return M
