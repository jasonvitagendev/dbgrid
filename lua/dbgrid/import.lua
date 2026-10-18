-- `:Dbgrid import <file> [table]`: load a CSV (or TSV) into a table. The
-- header names the columns, which must exist in the table; a table that does
-- not exist can be created from the header (every column text). PostgreSQL
-- uses psql's `\copy` (the file stays on this machine), SQLite the shell's
-- `.import` through a temporary table.
local util = require("dbgrid.util")

local M = {}

local DELIMITERS = { ",", "\t", ";", "|" }

---Split one delimited line, honouring double quotes.
---@param line string
---@param delim string
---@return string[]
function M.split_line(line, delim)
  local out, field, quoted, i = {}, {}, false, 1
  local n = #line
  while i <= n do
    local ch = line:sub(i, i)
    if quoted then
      if ch == '"' then
        if line:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          quoted = false
        end
      else
        field[#field + 1] = ch
      end
    elseif ch == '"' then
      quoted = true
    elseif ch == delim then
      out[#out + 1] = table.concat(field)
      field = {}
    else
      field[#field + 1] = ch
    end
    i = i + 1
  end
  out[#out + 1] = table.concat(field)
  return out
end

---Peek at a delimited file: the columns of its header, the delimiter, its
---size and (when `wc` is around) its line count.
---@param path string
---@return { columns: string[], delimiter: string, size: integer, lines?: integer, sample?: string }?, string? err
function M.inspect(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path
  end
  local head = f:read(65536) or ""
  local size = f:seek("end") or #head
  f:close()
  head = head:gsub("^\239\187\191", "") -- UTF-8 BOM
  local header, rest = head:match("^([^\r\n]*)\r?\n?(.*)$")
  if not header or header == "" then
    return nil, "the file is empty"
  end
  local best, best_count = ",", -1
  for _, d in ipairs(DELIMITERS) do
    local _, count = header:gsub(d == "|" and "%|" or d, "")
    if count > best_count then
      best, best_count = d, count
    end
  end
  local columns = {}
  for _, c in ipairs(M.split_line(header, best)) do
    columns[#columns + 1] = util.trim(c)
  end
  local sample = rest and rest:match("^([^\r\n]*)") or nil
  local lines
  if vim.fn.executable("wc") == 1 then
    local out = vim.system({ "wc", "-l", path }, { text = true }):wait()
    if out.code == 0 then
      lines = tonumber((out.stdout or ""):match("(%d+)"))
      if lines and not head:match("\n$") and size <= #head then
        lines = lines + 1 -- no trailing newline: wc counts one less
      end
    end
  end
  return { columns = columns, delimiter = best, size = size, lines = lines, sample = sample }
end

---`CREATE TABLE t ("a" text, "b" text)` for a header.
---@param table_ref string   already quoted
---@param columns string[]
---@return string
function M.create_sql(table_ref, columns)
  local cols = {}
  for _, c in ipairs(columns) do
    cols[#cols + 1] = "  " .. util.sql_ident(c) .. " text"
  end
  return "CREATE TABLE " .. table_ref .. " (\n" .. table.concat(cols, ",\n") .. "\n);"
end

---Match the header's columns against a table's: the table's spelling of each,
---and the names the table does not have.
---@param header string[]
---@param tbl dbgrid.SchemaTable
---@return string[] matched, string[] missing
function M.match_columns(header, tbl)
  local by_lower = {}
  for _, c in ipairs(tbl.columns or {}) do
    by_lower[c.name:lower()] = c.name
  end
  local matched, missing = {}, {}
  for _, h in ipairs(header) do
    local name = by_lower[h:lower()]
    if name then
      matched[#matched + 1] = name
    else
      missing[#missing + 1] = h
    end
  end
  return matched, missing
end

local function fmt_delim(d)
  return ({ [","] = "comma", ["\t"] = "tab", [";"] = "semicolon", ["|"] = "pipe" })[d] or ("'" .. d .. "'")
end

---Resolve a connection: the notebook's, or one picked when no notebook is open.
---@param state dbgrid.State?
---@param cb fun(conn: dbgrid.Connection)
local function with_connection(state, cb)
  if state then
    return require("dbgrid.runner").with_connection(state, nil, cb)
  end
  require("dbgrid.ui.picker").connection(function(conn)
    if not conn then
      return
    end
    require("dbgrid.connections").resolve(conn, function(eff, err)
      if not eff then
        return util.error("connection " .. conn.name .. ": " .. tostring(err))
      end
      cb(eff)
    end)
  end)
end

---Import a file interactively: pick the table when none is given, check the
---columns, confirm, run, then show the table when a notebook is open.
---@param opts { path: string, table?: string, state?: dbgrid.State, confirm?: boolean }
---@param cb? fun(ok: boolean, message: string, rows?: integer)
function M.run(opts, cb)
  cb = cb or function() end
  local path = vim.fn.fnamemodify(vim.fn.expand(opts.path), ":p")
  local info, err = M.inspect(path)
  if not info then
    util.error("import: " .. err)
    return cb(false, err)
  end
  local state = opts.state
  with_connection(state, function(conn)
    local adapters = require("dbgrid.adapters")
    local adapter = adapters.for_connection(conn)
    if not adapter or not adapter.import then
      local msg = "import is not supported for " .. (adapter and adapter.name or "this connection")
      util.error(msg)
      return cb(false, msg)
    end
    local schemamod = require("dbgrid.schema")
    local follow = require("dbgrid.follow")
    schemamod.get(conn, function(sch, serr)
      if not sch then
        util.error("schema: " .. tostring(serr))
        return cb(false, tostring(serr))
      end
      local function proceed(tbl, name)
        local columns, create_sql, table_ref
        if tbl then
          table_ref = follow.table_ref(tbl)
          local missing
          columns, missing = M.match_columns(info.columns, tbl)
          if #missing > 0 then
            local msg = schemamod.display_name(tbl)
              .. " has no column "
              .. table.concat(missing, ", ")
              .. " (the header names the columns to load)"
            util.error("import: " .. msg)
            return cb(false, msg)
          end
          name = schemamod.display_name(tbl)
        else
          table_ref = util.sql_ident(name)
          columns = info.columns
          create_sql = M.create_sql(table_ref, columns)
        end
        local rows_text = info.lines and (util.fmt_int(math.max(0, info.lines - 1)) .. " rows") or "the rows"
        local lines = {
          string.format("Import %s of %s", rows_text, vim.fn.fnamemodify(path, ":~")),
          string.format("into %s%s", name, tbl and "" or " (new table, every column text)"),
          "",
          "columns: " .. table.concat(columns, ", "),
          "delimiter: " .. fmt_delim(info.delimiter) .. ", first line is the header",
        }
        if info.sample then
          lines[#lines + 1] = "first row: " .. util.truncate(info.sample, 80)
        end
        if conn.readonly then
          lines[#lines + 1] = ""
          lines[#lines + 1] = "connection " .. conn.name .. " is read-only; this will fail"
        end
        if opts.confirm ~= false then
          local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Import\n&Cancel", 2, "Question")
          if choice ~= 1 then
            return cb(false, "cancelled")
          end
        end
        util.notify("importing " .. vim.fn.fnamemodify(path, ":t") .. " into " .. name .. "…")
        adapter.import(conn, {
          path = path,
          table = table_ref,
          columns = columns,
          delimiter = info.delimiter,
          header = true,
          create_sql = create_sql,
        }, function(ok, message, count)
          if not ok then
            util.error("import: " .. message)
            return cb(false, message)
          end
          util.notify(
            string.format("imported %s %s into %s", util.fmt_int(count or 0), count == 1 and "row" or "rows", name)
          )
          if create_sql then
            schemamod.refresh(conn, function() end)
          end
          if state and vim.api.nvim_buf_is_valid(state.buf) then
            require("dbgrid.runner").run_sql(
              state,
              "SELECT *\nFROM " .. table_ref,
              { title = "imported into " .. name, id = "__import" },
              function(result)
                if result then
                  require("dbgrid.ui.results").show_result(state, "__import", result)
                end
              end
            )
          end
          cb(true, message, count)
        end)
      end
      if opts.table then
        local tbl = schemamod.find_table(sch, opts.table)
        if tbl then
          return proceed(tbl, opts.table)
        end
        if opts.confirm ~= false then
          local choice = vim.fn.confirm(
            "No table named " .. opts.table .. ". Create it from the header (every column text)?",
            "&Create\n&Cancel",
            2,
            "Question"
          )
          if choice ~= 1 then
            return cb(false, "cancelled")
          end
        end
        return proceed(nil, opts.table)
      end
      local items = {}
      local base = vim.fn.fnamemodify(path, ":t:r"):gsub("[^%w_]+", "_"):lower()
      items[#items + 1] = { text = "+ new table " .. base, data = { create = base } }
      for _, t in ipairs(sch.tables or {}) do
        if t.kind == "r" or t.kind == "p" then
          local names = vim.tbl_map(function(c)
            return c.name
          end, t.columns or {})
          items[#items + 1] = {
            text = schemamod.display_name(t) .. "  (" .. #names .. " columns)",
            preview = schemamod.describe_lines(t, sch),
            data = { table = t },
          }
        end
      end
      require("dbgrid.ui.picker").pick(items, {
        prompt = "Import " .. vim.fn.fnamemodify(path, ":t") .. " into",
        on_select = function(item)
          if not item then
            return cb(false, "cancelled")
          end
          if item.data.create then
            return proceed(nil, item.data.create)
          end
          proceed(item.data.table, schemamod.display_name(item.data.table))
        end,
      })
    end)
  end)
end

return M
