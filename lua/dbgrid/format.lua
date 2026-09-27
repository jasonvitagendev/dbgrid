-- SQL formatting for notebook cells. Cell headers, `-- ?` prompts and `-- @`
-- directives are never touched: only the SQL under them is reformatted, one
-- statement at a time.
--
-- Formatters, in the order "auto" tries them: conform.nvim (when it has a
-- formatter for the sql filetype), the first of `format.commands` on PATH,
-- and the built-in formatter.
local config = require("dbgrid.config")
local util = require("dbgrid.util")
local cells = require("dbgrid.cells")
local sqlmod = require("dbgrid.sql")

local M = {}

-- Keywords that start a new line at the current depth.
local CLAUSE = {
  select = true,
  from = true,
  where = true,
  group = true,
  having = true,
  order = true,
  limit = true,
  offset = true,
  fetch = true,
  union = true,
  intersect = true,
  except = true,
  returning = true,
  values = true,
  set = true,
  window = true,
  insert = true,
  update = true,
  delete = true,
  with = true,
  ["for"] = true,
  on_conflict = true,
}
local JOIN_START = { join = true, left = true, right = true, inner = true, full = true, cross = true, natural = true }
-- Words that are part of a clause keyword sequence ("group by", "left outer join").
local FOLLOWS = {
  by = true,
  outer = true,
  join = true,
  all = true,
  distinct = true,
  into = true,
  first = true,
  next = true,
  update = true,
  share = true,
  recursive = true,
  lateral = true,
  only = true,
  conflict = true,
  nothing = true,
}
-- Keywords for case normalisation (a superset of the clause words).
local KEYWORDS = {}
for _, k in ipairs({
  "select",
  "from",
  "where",
  "and",
  "or",
  "not",
  "in",
  "is",
  "null",
  "as",
  "on",
  "join",
  "left",
  "right",
  "inner",
  "outer",
  "full",
  "cross",
  "natural",
  "lateral",
  "group",
  "by",
  "order",
  "having",
  "limit",
  "offset",
  "fetch",
  "first",
  "next",
  "rows",
  "row",
  "only",
  "union",
  "all",
  "except",
  "intersect",
  "distinct",
  "case",
  "when",
  "then",
  "else",
  "end",
  "insert",
  "into",
  "values",
  "update",
  "set",
  "delete",
  "returning",
  "with",
  "recursive",
  "create",
  "table",
  "index",
  "view",
  "materialized",
  "alter",
  "drop",
  "truncate",
  "begin",
  "commit",
  "rollback",
  "explain",
  "analyze",
  "exists",
  "between",
  "like",
  "ilike",
  "similar",
  "any",
  "some",
  "asc",
  "desc",
  "nulls",
  "over",
  "partition",
  "window",
  "filter",
  "within",
  "true",
  "false",
  "cast",
  "interval",
  "using",
  "default",
  "primary",
  "key",
  "references",
  "unique",
  "check",
  "constraint",
  "temporary",
  "temp",
  "if",
  "cascade",
  "restrict",
  "merge",
  "matched",
  "conflict",
  "do",
  "nothing",
  "excluded",
  "for",
  "share",
  "skip",
  "locked",
  "nowait",
  "collate",
  "coalesce",
  "nullif",
  "extract",
  "escape",
  "asymmetric",
  "symmetric",
  "isnull",
  "notnull",
  "of",
  "to",
  "type",
  "sequence",
  "function",
  "trigger",
  "procedure",
  "language",
  "return",
  "returns",
  "declare",
  "loop",
  "while",
  "grant",
  "revoke",
  "column",
  "add",
  "rename",
  "owner",
  "schema",
  "database",
  "extension",
  "comment",
  "concurrently",
  "replace",
  "unlogged",
  "tablesample",
  "grouping",
  "sets",
  "cube",
  "rollup",
  "limit",
  "top",
  "vacuum",
  "cluster",
  "reindex",
  "listen",
  "notify",
  "show",
  "reset",
  "current",
  "last",
  "ties",
}) do
  KEYWORDS[k] = true
end
-- Keywords that take a space before an opening parenthesis ("in (", "values (");
-- every other word is treated as a function call ("count(", "coalesce(").
local PAREN_SPACE = {}
for _, k in ipairs({
  "in",
  "exists",
  "values",
  "on",
  "as",
  "and",
  "or",
  "not",
  "from",
  "join",
  "where",
  "having",
  "select",
  "when",
  "then",
  "else",
  "over",
  "filter",
  "within",
  "using",
  "partition",
  "by",
  "distinct",
  "all",
  "any",
  "some",
  "between",
  "is",
  "like",
  "ilike",
  "similar",
  "returning",
  "set",
  "into",
  "key",
  "references",
  "check",
  "unique",
  "primary",
  "index",
  "with",
  "union",
  "except",
  "intersect",
  "conflict",
  "do",
  "update",
  "insert",
  "delete",
  "group",
  "order",
  "table",
  "view",
  "add",
  "constraint",
  "for",
  "of",
  "to",
  "if",
  "case",
  "end",
  "escape",
  "lateral",
  "only",
  "matched",
  "excluded",
  "return",
  "returns",
  "language",
  "default",
  "type",
  "row",
  "rows",
  "ties",
}) do
  PAREN_SPACE[k] = true
end

---@param word string
---@param mode "upper"|"lower"|"keep"
local function case_word(word, mode)
  if mode == "upper" then
    return word:upper()
  elseif mode == "lower" then
    return word:lower()
  end
  return word
end

---Built-in formatter for one statement (no trailing semicolon).
---@param text string
---@param opts? { keyword_case?: "upper"|"lower"|"keep", width?: integer, indent?: integer }
---@return string
function M.builtin(text, opts)
  opts = opts or {}
  local kcase = opts.keyword_case or "keep"
  local width = opts.width or 100
  local indent_unit = string.rep(" ", opts.indent or 2)
  local tokens = sqlmod.tokenize(text, { comments = true })
  if #tokens == 0 then
    return util.trim(text)
  end
  -- glue placeholders (":name", "{{name}}") into single tokens
  local refs = sqlmod.placeholders(text)
  local ref_at = {}
  for _, r in ipairs(refs) do
    ref_at[r.s] = r
  end
  local merged = {}
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    local r = ref_at[t.s] or (t.type == "op" and ref_at[t.e]) -- "=:" glues the colon to an operator
    if r and r.s == t.e and t.value ~= ":" then
      -- operator with a trailing colon: split it
      merged[#merged + 1] = vim.tbl_extend("force", t, { value = t.value:sub(1, -2), e = t.e - 1 })
    end
    if r then
      local j = i
      while tokens[j] and tokens[j].e < r.e do
        j = j + 1
      end
      merged[#merged + 1] =
        { type = "ref", value = text:sub(r.s, r.e), s = r.s, e = r.e, depth = t.depth, line = t.line }
      i = j + 1
    else
      merged[#merged + 1] = t
      i = i + 1
    end
  end
  tokens = merged

  local lines = {}
  local cur = {} -- pieces of the current line
  local depth_indent = {} -- depth -> indent string for lines inside that paren
  local sub_open = {} -- depth -> true when the paren opened a subquery/CTE body
  local indent = ""
  local extra = "" -- extra indent for AND/OR continuation
  local function flush()
    local line = table.concat(cur):gsub("%s+$", "")
    if line:match("%S") then
      lines[#lines + 1] = line
    end
    cur = {}
  end
  local function newline(ind)
    flush()
    cur[1] = ind or indent
  end
  local function cur_text()
    return table.concat(cur)
  end
  local function last_char()
    local s = cur_text()
    return s:sub(-1)
  end
  local function needs_space(prev, t)
    if not prev then
      return false
    end
    if last_char() == " " or last_char() == "" then
      return false
    end
    if
      t.type == "punct" and (t.value == "," or t.value == ")" or t.value == "." or t.value == "]" or t.value == ";")
    then
      return false
    end
    if prev.type == "punct" and (prev.value == "(" or prev.value == "." or prev.value == "[") then
      return false
    end
    if t.type == "op" and t.value == "::" then
      return false
    end
    if prev.type == "op" and prev.value == "::" then
      return false
    end
    if t.type == "punct" and t.value == "(" then
      -- function call: "count(" ; keyword: "in (", "values (", "as ("
      if prev.type == "word" and prev.prev and prev.prev.type == "word" and prev.prev.lower == "into" then
        return true -- "insert into t (cols)"
      end
      if prev.type == "word" and not PAREN_SPACE[prev.lower] then
        return false
      end
      if prev.type == "ident" or prev.type == "ref" then
        return false
      end
    end
    if t.type == "punct" and t.value == "[" then
      return false
    end
    if prev.type == "op" and (prev.value == "-" or prev.value == "+") then
      -- unary sign: "- 1" only when it follows an operand
      local pp = prev.prev
      if
        not pp
        or pp.type == "op"
        or (pp.type == "punct" and pp.value ~= ")")
        or (pp.type == "word" and KEYWORDS[pp.lower] and pp.lower ~= "end" and pp.lower ~= "null")
      then
        return false
      end
    end
    return true
  end

  local select_depth = {} -- depth -> "list" when we are in a select list
  local prev
  local n = #tokens
  local k = 1
  local last_line_no = tokens[1].line
  while k <= n do
    local t = tokens[k]
    t.prev = prev
    local nxt = tokens[k + 1]
    local d = t.depth
    if t.type == "comment" then
      if t.value:sub(1, 2) == "--" then
        if t.line == last_line_no and cur_text():match("%S") then
          cur[#cur + 1] = "  " .. t.value
        else
          newline()
          cur[#cur + 1] = t.value
        end
        flush()
        cur[1] = indent
      else
        if needs_space(prev, t) then
          cur[#cur + 1] = " "
        end
        cur[#cur + 1] = t.value
      end
    elseif t.type == "punct" and t.value == "(" then
      local after = nxt
      local opens_sub = after
        and after.type == "word"
        and (
          after.lower == "select"
          or after.lower == "with"
          or after.lower == "values" and prev and prev.type == "word" and prev.lower ~= "values"
        )
      if needs_space(prev, t) then
        cur[#cur + 1] = " "
      end
      cur[#cur + 1] = "("
      depth_indent[d + 1] = indent
      if opens_sub then
        sub_open[d + 1] = true
        indent = indent .. indent_unit
        extra = ""
        newline()
      end
    elseif t.type == "punct" and t.value == ")" then
      if sub_open[d + 1] then
        sub_open[d + 1] = nil
        indent = depth_indent[d + 1] or ""
        extra = ""
        newline()
        cur[#cur + 1] = ")"
      else
        cur[#cur + 1] = ")"
      end
    elseif t.type == "punct" and t.value == "," then
      cur[#cur + 1] = ","
      if select_depth[d] == "multiline" then
        newline(indent .. indent_unit)
      end
    elseif
      t.type == "word"
      and (CLAUSE[t.lower] or JOIN_START[t.lower] or (t.lower == "on" and nxt and nxt.type == "word" and nxt.lower == "conflict"))
      and (d == 0 or sub_open[d])
      and not (prev and prev.type == "word" and (prev.lower == "as" or prev.lower == "is" or prev.lower == "in" or prev.lower == "not" or prev.lower == "case" or prev.lower == "distinct" or prev.lower == "insert" or prev.lower == "delete" or prev.lower == "update" or prev.lower == "on"))
      and not (prev and prev.type == "op" and prev.value == "=")
      and not (t.lower == "set" and prev and prev.type == "word" and prev.lower == "on")
      and not (t.lower == "for" and prev and prev.type == "word" and prev.lower == "check")
    then
      -- a new clause: own line, at the current indent
      local word = case_word(t.value, kcase)
      if t.lower == "select" and prev and prev.type == "punct" and prev.value == "(" and not sub_open[d] then
        cur[#cur + 1] = word
      elseif prev == nil or (prev.type == "punct" and prev.value == "(" and sub_open[d]) then
        cur[#cur + 1] = word
      else
        extra = ""
        newline()
        cur[#cur + 1] = word
      end
      -- clause word sequences ("group by", "left outer join", "order by", "for update")
      while tokens[k + 1] and tokens[k + 1].type == "word" and FOLLOWS[tokens[k + 1].lower] do
        k = k + 1
        tokens[k].prev = tokens[k - 1]
        cur[#cur + 1] = " " .. case_word(tokens[k].value, kcase)
      end
      if t.lower == "select" or t.lower == "set" or t.lower == "returning" then
        -- decide select-list layout: one line when it fits, else one item per line
        local items, j, dd = 1, k + 1, d
        local len = 0
        local terminators = {
          from = true,
          where = true,
          union = true,
          values = true,
          returning = true,
          limit = true,
          order = true,
          group = true,
          having = true,
          on = true,
        }
        while tokens[j] and not (tokens[j].depth == dd and tokens[j].type == "word" and terminators[tokens[j].lower]) do
          if tokens[j].type == "comment" then
            items = items + 1
            len = width -- force multi-line when comments live in the list
          end
          if tokens[j].depth == dd and tokens[j].type == "punct" and tokens[j].value == "," then
            items = items + 1
          end
          if tokens[j].depth < dd then
            break
          end
          len = len + #tokens[j].value + 1
          j = j + 1
        end
        if items > 1 and #indent + #word + 1 + len > width then
          select_depth[d] = "multiline"
          newline(indent .. indent_unit)
        else
          select_depth[d] = "line"
        end
      elseif t.lower ~= "select" then
        select_depth[d] = nil
      end
      t.prev = prev
    elseif
      t.type == "word"
      and (t.lower == "and" or t.lower == "or")
      and (d == 0 or sub_open[d])
      and not (prev and prev.type == "word" and prev.lower == "between")
      and not (prev and prev.prev and prev.prev.type == "word" and prev.prev.lower == "between")
      and select_depth[d] ~= "multiline"
      and select_depth[d] ~= "line"
    then
      newline(indent .. indent_unit)
      cur[#cur + 1] = case_word(t.value, kcase)
    elseif
      t.type == "word"
      and (t.lower == "when" or t.lower == "else")
      and prev
      and not (prev.type == "word" and prev.lower == "case")
    then
      -- case arms on their own lines when the CASE is long; keep short ones inline
      if needs_space(prev, t) then
        cur[#cur + 1] = " "
      end
      cur[#cur + 1] = case_word(t.value, kcase)
    else
      if needs_space(prev, t) then
        cur[#cur + 1] = " "
      end
      if t.type == "word" then
        cur[#cur + 1] = KEYWORDS[t.lower] and case_word(t.value, kcase) or t.value
      else
        cur[#cur + 1] = t.value
      end
    end
    if t.type ~= "comment" then
      prev = tokens[k] -- the last token consumed (clause words may have advanced k)
    end
    last_line_no = tokens[k].line
    k = k + 1
  end
  flush()
  return table.concat(lines, "\n")
end

---Split a cell body into the comment lines kept on top (prompts, directives,
---plain comments before the SQL) and the SQL text.
---@param cell dbgrid.Cell
---@return string[] head, string sql, integer sql_first  (1-based index into cell.lines of the first SQL line)
function M.split_body(cell)
  local head = {}
  local first = #cell.lines + 1
  for i, l in ipairs(cell.lines) do
    if l:match(cells.PROMPT) or l:match(cells.DIRECTIVE) or l:match("^%s*%-%-") or not l:match("%S") then
      head[#head + 1] = l
    else
      first = i
      break
    end
  end
  local sql = table.concat(vim.list_slice(cell.lines, first, #cell.lines), "\n")
  return head, sql, first
end

---Resolve which formatter to use.
---@param adapter_name? string
---@return { kind: "conform"|"cmd"|"builtin", cmd?: string[], name: string }
function M.resolve(adapter_name)
  local cfg = config.get().format or {}
  local choice = cfg.formatter or "auto"
  local function cmd_for(name)
    local spec = (cfg.commands or {})[name]
    if not spec then
      return nil
    end
    if type(spec) == "function" then
      spec = spec(adapter_name)
    end
    if type(spec) ~= "table" or not spec[1] then
      return nil
    end
    local dialect = ({ postgres = "postgresql", sqlite = "sqlite" })[adapter_name or "postgres"] or adapter_name
    local argv = {}
    for i, a in ipairs(spec) do
      argv[i] = (a:gsub("{dialect}", dialect))
    end
    return argv
  end
  local function conform_available()
    local ok, conform = pcall(require, "conform")
    if not ok then
      return false
    end
    local ok2, list = pcall(conform.list_formatters_for_buffer, vim.api.nvim_get_current_buf())
    if ok2 and type(list) == "table" and #list > 0 then
      return true
    end
    local fts = conform.formatters_by_ft or {}
    return type(fts.sql) == "table" and #fts.sql > 0
  end
  if type(choice) == "table" then
    return { kind = "cmd", cmd = choice.cmd or choice, name = (choice.cmd or choice)[1] }
  end
  if choice == "conform" then
    return { kind = "conform", name = "conform" }
  end
  if choice == "builtin" then
    return { kind = "builtin", name = "builtin" }
  end
  if choice ~= "auto" then
    local argv = cmd_for(choice)
    if argv then
      return { kind = "cmd", cmd = argv, name = choice }
    end
    return { kind = "builtin", name = "builtin" }
  end
  if conform_available() then
    return { kind = "conform", name = "conform" }
  end
  for _, name in ipairs(cfg.order or { "pg_format", "sql-formatter", "sqlfluff", "sqlformat" }) do
    local argv = cmd_for(name)
    if argv and vim.fn.executable(argv[1]) == 1 then
      return { kind = "cmd", cmd = argv, name = name }
    end
  end
  return { kind = "builtin", name = "builtin" }
end

---Protect `{{name}}` references from external formatters.
local function protect(sql)
  local map = {}
  local refs = sqlmod.placeholders(sql)
  local out = sqlmod.substitute(sql, refs, function(r)
    if r.style ~= "{{" then
      return nil
    end
    local key = "dbgrid_ref_" .. util.hash(r.name)
    map[key] = sql:sub(r.s, r.e)
    return key
  end)
  return out, map
end

local function unprotect(sql, map)
  for key, original in pairs(map) do
    sql = sql:gsub(key, function()
      return original
    end)
  end
  return sql
end

---Format SQL text (one or more statements) with the resolved formatter.
---@param sql string
---@param adapter_name? string
---@return string? formatted, string? err
function M.format_sql(sql, adapter_name)
  local cfg = config.get().format or {}
  local which = M.resolve(adapter_name)
  if util.trim(sql) == "" then
    return sql
  end
  local out
  if which.kind == "builtin" then
    local stmts = sqlmod.split(sql)
    if #stmts == 0 then
      return sql
    end
    local parts = {}
    for i, st in ipairs(stmts) do
      local piece = sql:sub(st.s, st.e)
      -- comments between statements stay with the statement that follows them
      local prev_end = i > 1 and stmts[i - 1].e or 0
      local between = sql:sub(prev_end + 1, st.s - 1):gsub("^%s*;", "")
      local prefix = between:match("%S") and (util.trim(between) .. "\n") or ""
      parts[#parts + 1] = prefix
        .. M.builtin(piece, { keyword_case = cfg.keyword_case, width = cfg.width, indent = cfg.indent })
        .. ((#stmts > 1 or sql:match(";%s*$")) and ";" or "")
    end
    local trailing = sql:sub(stmts[#stmts].e + 1):gsub("^%s*;", "")
    if trailing:match("%S") then
      parts[#parts + 1] = util.trim(trailing)
    end
    out = table.concat(parts, "\n\n")
  elseif which.kind == "conform" then
    local ok, conform = pcall(require, "conform")
    if not ok then
      return nil, "conform.nvim is not installed"
    end
    local protected, map = protect(sql)
    local tmp = vim.api.nvim_create_buf(false, true)
    vim.bo[tmp].filetype = "sql"
    vim.api.nvim_buf_set_lines(tmp, 0, -1, false, util.lines(protected))
    local ok2, res = pcall(
      conform.format,
      { bufnr = tmp, async = false, quiet = true, lsp_format = "never", timeout_ms = cfg.timeout_ms or 5000 }
    )
    local formatted = table.concat(vim.api.nvim_buf_get_lines(tmp, 0, -1, false), "\n")
    pcall(vim.api.nvim_buf_delete, tmp, { force = true })
    if not ok2 or res == false then
      return nil, "conform could not format the cell"
    end
    out = unprotect(formatted, map)
  else
    local protected, map = protect(sql)
    local res = vim.system(which.cmd, { stdin = protected, text = true, timeout = cfg.timeout_ms or 5000 }):wait()
    if res.code ~= 0 then
      return nil, which.name .. " failed: " .. util.trim(res.stderr or "")
    end
    out = unprotect(res.stdout or "", map)
  end
  out = out:gsub("\r\n", "\n"):gsub("%s+$", "")
  if util.trim(out) == "" then
    return nil, which.name .. " returned nothing"
  end
  -- safety: the statement must still be the same statement
  if sqlmod.normalize(out) ~= sqlmod.normalize(sql) then
    return nil, which.name .. " changed the meaning of the SQL; cell left as is"
  end
  return out
end

---Format one cell in place. Returns true when the buffer changed.
---@param s dbgrid.State
---@param cell dbgrid.Cell
---@param opts? { notify?: boolean }
---@return boolean changed, string? err
function M.cell(s, cell, opts)
  opts = opts or {}
  local head, sql, first = M.split_body(cell)
  if util.trim(sql) == "" then
    return false
  end
  local adapter_name
  local conn_name = cells.directives(cell).conn
  local conn = require("dbgrid.connections").get(type(conn_name) == "string" and conn_name or s.nb.meta.connection)
  if conn then
    local a = require("dbgrid.adapters").for_connection(conn)
    adapter_name = a and a.name or nil
  end
  local formatted, err = M.format_sql(sql, adapter_name)
  if not formatted then
    if opts.notify ~= false then
      util.warn("format: " .. tostring(err))
    end
    return false, err
  end
  local new_lines = util.lines(formatted)
  -- keep one trailing blank line when the cell had one
  if cell.lines[#cell.lines] == "" then
    new_lines[#new_lines + 1] = ""
  end
  local old_lines = vim.list_slice(cell.lines, first, #cell.lines)
  if vim.deep_equal(old_lines, new_lines) then
    return false
  end
  local start = cell.first + first - 2 -- 0-based line of the first SQL line
  vim.api.nvim_buf_set_lines(s.buf, start, cell.last, false, new_lines)
  vim.b[s.buf].dbgrid_cells_cache = nil
  return true
end

---Format every cell (bottom-up so line numbers stay valid). Returns how many changed.
---@param s dbgrid.State
---@param opts? { notify?: boolean }
---@return integer changed
function M.buffer(s, opts)
  local list = cells.parse(s.buf)
  local changed = 0
  for i = #list, 1, -1 do
    local ok, did = pcall(M.cell, s, list[i], opts)
    if ok and did then
      changed = changed + 1
    end
  end
  return changed
end

return M
