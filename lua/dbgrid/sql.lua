-- SQL text utilities: a tolerant tokenizer, statement splitter, statement
-- classification, LIMIT injection and table-reference extraction.
--
-- This is deliberately not a parser. It understands just enough of the lexical
-- structure of SQL (strings, quoted identifiers, dollar quotes, nested block
-- comments, parentheses) to make decisions safely.
local M = {}

---@class dbgrid.Token
---@field type "word"|"number"|"string"|"ident"|"op"|"punct"|"param"
---@field value string   raw text (words are lower-cased in `lower`)
---@field lower string
---@field s integer      1-based byte start
---@field e integer      1-based byte end (inclusive)
---@field line integer   1-based line in the input
---@field col integer    1-based byte column in that line
---@field depth integer  parenthesis depth at the token

---@class dbgrid.Statement
---@field sql string
---@field s integer            byte offset of the first token in the original text
---@field e integer
---@field line integer         1-based line of the first token in the original text
---@field col integer
---@field tokens dbgrid.Token[]
---@field kind string          first keyword (lower-cased), e.g. "select"
---@field class "read"|"write"|"ddl"|"tx"|"other"

local function is_ident_start(c)
  return c:match("[%a_]") ~= nil
end

local function is_ident_char(c)
  return c:match("[%w_$]") ~= nil
end

---Tokenize SQL. Comments and whitespace are skipped.
---@param text string
---@return dbgrid.Token[]
function M.tokenize(text)
  local tokens = {}
  local i, n = 1, #text
  local line, line_start = 1, 1
  local depth = 0

  local function advance_lines(from, to)
    for k = from, to do
      if text:byte(k) == 10 then
        line = line + 1
        line_start = k + 1
      end
    end
  end

  local function push(ttype, s, e, extra_depth)
    local value = text:sub(s, e)
    tokens[#tokens + 1] = {
      type = ttype,
      value = value,
      lower = value:lower(),
      s = s,
      e = e,
      line = line,
      col = s - line_start + 1,
      depth = extra_depth or depth,
    }
  end

  while i <= n do
    local c = text:sub(i, i)
    local two = text:sub(i, i + 1)
    if c == "\n" then
      line = line + 1
      line_start = i + 1
      i = i + 1
    elseif c:match("%s") then
      i = i + 1
    elseif two == "--" then
      local e = text:find("\n", i, true) or (n + 1)
      i = e -- newline handled on next iteration
    elseif two == "/*" then
      local d = 1
      local j = i + 2
      while j <= n and d > 0 do
        local t2 = text:sub(j, j + 1)
        if t2 == "/*" then
          d = d + 1
          j = j + 2
        elseif t2 == "*/" then
          d = d - 1
          j = j + 2
        else
          j = j + 1
        end
      end
      advance_lines(i, j - 1)
      i = j
    elseif
      c == "'"
      or (
        (c == "E" or c == "e")
        and text:sub(i + 1, i + 1) == "'"
        and (i == 1 or not is_ident_char(text:sub(i - 1, i - 1)))
      )
    then
      local escape = c ~= "'"
      local s = i
      local j = escape and i + 2 or i + 1
      while j <= n do
        local ch = text:sub(j, j)
        if escape and ch == "\\" then
          j = j + 2
        elseif ch == "'" then
          if text:sub(j + 1, j + 1) == "'" then
            j = j + 2
          else
            break
          end
        else
          j = j + 1
        end
      end
      j = math.min(j, n)
      push("string", s, j)
      advance_lines(s, j)
      i = j + 1
    elseif c == '"' then
      local s = i
      local j = i + 1
      while j <= n do
        local ch = text:sub(j, j)
        if ch == '"' then
          if text:sub(j + 1, j + 1) == '"' then
            j = j + 2
          else
            break
          end
        else
          j = j + 1
        end
      end
      j = math.min(j, n)
      push("ident", s, j)
      advance_lines(s, j)
      i = j + 1
    elseif c == "$" then
      local tag = text:match("^%$([%a_][%w_]*)%$", i) or (two == "$$" and "" or nil)
      if tag then
        local open = "$" .. tag .. "$"
        local s = i
        local close_s, close_e = text:find(open, i + #open, true)
        local j = close_e or n
        push("string", s, j)
        advance_lines(s, j)
        i = j + 1
      else
        local num = text:match("^%$(%d+)", i)
        if num then
          push("param", i, i + #num)
          i = i + #num + 1
        else
          push("op", i, i)
          i = i + 1
        end
      end
    elseif c == "(" then
      push("punct", i, i)
      depth = depth + 1
      i = i + 1
    elseif c == ")" then
      depth = math.max(0, depth - 1)
      push("punct", i, i)
      i = i + 1
    elseif c == "," or c == ";" or c == "[" or c == "]" then
      push("punct", i, i)
      i = i + 1
    elseif c:match("%d") or (c == "." and text:sub(i + 1, i + 1):match("%d")) then
      local e = i
      while e < n and text:sub(e + 1, e + 1):match("[%w%.]") do
        e = e + 1
      end
      push("number", i, e)
      i = e + 1
    elseif is_ident_start(c) then
      local e = i
      while e < n and is_ident_char(text:sub(e + 1, e + 1)) do
        e = e + 1
      end
      push("word", i, e)
      i = e + 1
    elseif c == "." then
      push("punct", i, i)
      i = i + 1
    else
      local e = i
      while e < n and text:sub(e + 1, e + 1):match("[%+%-%*/<>=~!@#%%%^&|`%?:]") do
        e = e + 1
      end
      -- make sure we do not swallow the start of a comment
      local chunk = text:sub(i, e)
      local cut = chunk:find("%-%-") or chunk:find("/%*")
      if cut and cut > 1 then
        e = i + cut - 2
      elseif cut == 1 then
        e = i
      end
      push("op", i, e)
      i = e + 1
    end
  end
  return tokens
end

local READ = { select = true, values = true, table = true, show = true, explain = true, with = true }
local WRITE = { insert = true, update = true, delete = true, merge = true, copy = true, ["do"] = true, call = true }
local DDL = {
  create = true,
  alter = true,
  drop = true,
  truncate = true,
  grant = true,
  revoke = true,
  comment = true,
  reindex = true,
  cluster = true,
  refresh = true,
  security = true,
  import = true,
}
local TX = {
  begin = true,
  start = true,
  commit = true,
  ["end"] = true,
  rollback = true,
  savepoint = true,
  release = true,
  abort = true,
  prepare = true,
}

---Work out the statement's leading keyword and class.
---@param tokens dbgrid.Token[]
---@return string kind, string class
function M.classify(tokens)
  local first = tokens[1]
  if not first then
    return "", "other"
  end
  local kind = first.lower
  if first.type == "punct" and first.value == "(" then
    -- "(select ...) union ..." : look for the first word at depth 1
    for _, t in ipairs(tokens) do
      if t.type == "word" then
        kind = t.lower
        break
      end
    end
  end
  if kind == "with" then
    -- CTE: a data-modifying CTE body ("as (delete ...)") or a top-level DML
    -- keyword after the CTE list makes the whole statement a write.
    local DML = { insert = true, update = true, delete = true, merge = true }
    local seen_as = false
    for idx = 2, #tokens do
      local t = tokens[idx]
      local prev = tokens[idx - 1]
      if t.type == "word" and DML[t.lower] and t.depth == 1 and prev.type == "punct" and prev.value == "(" then
        return "with", "write"
      end
      if t.depth == 0 and t.type == "word" then
        if t.lower == "as" then
          seen_as = true
        elseif seen_as and (DML[t.lower] or t.lower == "select" or t.lower == "values" or t.lower == "table") then
          if DML[t.lower] then
            return "with", "write"
          end
          -- keep scanning: a later CTE-less statement cannot follow, so this is the main clause
          local rest_write = false
          for j = idx + 1, #tokens do
            local r = tokens[j]
            local rp = tokens[j - 1]
            if r.type == "word" and DML[r.lower] and r.depth == 1 and rp.type == "punct" and rp.value == "(" then
              rest_write = true
            end
          end
          return "with", rest_write and "write" or "read"
        end
      end
    end
    return "with", "read"
  end
  if kind == "select" then
    -- SELECT ... INTO creates a table
    for _, t in ipairs(tokens) do
      if t.depth == 0 and t.type == "word" and t.lower == "into" then
        return "select", "write"
      end
      if t.depth == 0 and t.type == "word" and t.lower == "from" then
        break
      end
    end
    return "select", "read"
  end
  if kind == "explain" then
    for idx = 2, #tokens do
      local t = tokens[idx]
      if t.depth == 0 and t.type == "word" and t.lower == "analyze" then
        return "explain", "explain_analyze"
      end
      if t.depth == 0 and t.type == "word" and t.lower ~= "verbose" then
        break
      end
    end
    return "explain", "read"
  end
  if kind == "prepare" then
    return "prepare", "other"
  end
  if READ[kind] then
    return kind, "read"
  elseif WRITE[kind] then
    return kind, "write"
  elseif DDL[kind] then
    return kind, "ddl"
  elseif TX[kind] then
    return kind, "tx"
  end
  return kind, "other"
end

---Split SQL text into statements at top-level semicolons.
---@param text string
---@return dbgrid.Statement[]
function M.split(text)
  local tokens = M.tokenize(text)
  local statements = {}
  local current = {}
  local function flush()
    if #current > 0 then
      local first, last = current[1], current[#current]
      local kind, class = M.classify(current)
      statements[#statements + 1] = {
        sql = text:sub(first.s, last.e),
        s = first.s,
        e = last.e,
        line = first.line,
        col = first.col,
        tokens = current,
        kind = kind,
        class = class,
      }
      current = {}
    end
  end
  for _, t in ipairs(tokens) do
    if t.type == "punct" and t.value == ";" and t.depth == 0 then
      flush()
    else
      current[#current + 1] = t
    end
  end
  flush()
  return statements
end

---True when the text contains at least one statement.
---@param text string
function M.has_statements(text)
  return #M.tokenize(text) > 0
end

---@param stmt dbgrid.Statement
---@param words table<string,boolean>
---@return dbgrid.Token?
function M.first_top_level_word(stmt, words)
  for _, t in ipairs(stmt.tokens) do
    if t.depth == 0 and t.type == "word" and words[t.lower] then
      return t
    end
  end
end

local LIMITABLE = { select = true, with = true, values = true, table = true }

---Append `LIMIT n` to read-only statements that lack one.
---@param stmt dbgrid.Statement
---@param n integer
---@return string sql, boolean applied
function M.ensure_limit(stmt, n)
  if not n or n <= 0 or stmt.class ~= "read" or not LIMITABLE[stmt.kind] then
    return stmt.sql, false
  end
  if M.first_top_level_word(stmt, { limit = true, fetch = true }) then
    return stmt.sql, false
  end
  local locking = M.first_top_level_word(stmt, { ["for"] = true })
  if locking then
    local rel = locking.s - stmt.s + 1
    return stmt.sql:sub(1, rel - 1) .. "\nLIMIT " .. n .. "\n" .. stmt.sql:sub(rel), true
  end
  return stmt.sql .. "\nLIMIT " .. n, true
end

---Describe why a write statement looks dangerous, or nil.
---@param stmt dbgrid.Statement
---@return string?
function M.danger(stmt)
  if stmt.kind == "update" or stmt.kind == "delete" then
    if not M.first_top_level_word(stmt, { where = true }) then
      return stmt.kind:upper() .. " without a WHERE clause touches every row"
    end
  elseif stmt.kind == "truncate" then
    return "TRUNCATE removes every row"
  elseif stmt.kind == "drop" then
    return "DROP is irreversible"
  end
end

local EXPLAINABLE = {
  select = true,
  with = true,
  values = true,
  table = true,
  insert = true,
  update = true,
  delete = true,
  merge = true,
}

---@param stmt dbgrid.Statement
function M.is_explainable(stmt)
  return EXPLAINABLE[stmt.kind] == true and stmt.class ~= "other"
end

local CLAUSE_WORDS = {
  where = true,
  on = true,
  join = true,
  left = true,
  right = true,
  inner = true,
  outer = true,
  full = true,
  cross = true,
  natural = true,
  set = true,
  group = true,
  order = true,
  limit = true,
  offset = true,
  fetch = true,
  using = true,
  values = true,
  select = true,
  having = true,
  window = true,
  union = true,
  except = true,
  intersect = true,
  returning = true,
  ["for"] = true,
  lateral = true,
  only = true,
  as = true,
  with = true,
  when = true,
  ["then"] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["in"] = true,
  from = true,
  into = true,
  tablesample = true,
  insert = true,
  update = true,
  delete = true,
  ["do"] = true,
  ["end"] = true,
}

---Tables referenced by FROM / JOIN / UPDATE / INSERT INTO / DELETE FROM, with aliases.
---@param text string
---@return {name:string, alias?:string}[]
function M.referenced_tables(text)
  local tokens = M.tokenize(text)
  local refs = {}
  local FROM_END = {
    where = true,
    group = true,
    order = true,
    having = true,
    window = true,
    limit = true,
    offset = true,
    fetch = true,
    ["for"] = true,
    union = true,
    except = true,
    intersect = true,
    returning = true,
    set = true,
    select = true,
    values = true,
  }

  local function name_at(k)
    local t = tokens[k]
    if not t or (t.type ~= "word" and t.type ~= "ident") or (t.type == "word" and CLAUSE_WORDS[t.lower]) then
      return nil, k
    end
    local parts = { t.value }
    local j = k + 1
    while tokens[j] and tokens[j].type == "punct" and tokens[j].value == "." do
      local nxt = tokens[j + 1]
      if nxt and (nxt.type == "word" or nxt.type == "ident") then
        parts[#parts + 1] = nxt.value
        j = j + 2
      else
        break
      end
    end
    return table.concat(parts, "."), j
  end

  ---Parse one table reference starting at token k. Returns the next token index.
  local function table_ref(k, introducer)
    if tokens[k] and tokens[k].type == "word" and (tokens[k].lower == "only" or tokens[k].lower == "lateral") then
      k = k + 1
    end
    if tokens[k] and tokens[k].type == "punct" and tokens[k].value == "(" then
      return k -- subquery
    end
    local name, nk = name_at(k)
    if not name then
      return k
    end
    local alias
    local a = tokens[nk]
    local ak = nk
    if a and a.type == "word" and a.lower == "as" then
      a = tokens[nk + 1]
      ak = nk + 1
    end
    if a and (a.type == "word" or a.type == "ident") and not CLAUSE_WORDS[a.lower] then
      local following = tokens[ak + 1]
      -- "insert into t (cols)" has no alias
      if not (introducer == "into" and following and following.type == "punct" and following.value == "(") then
        alias = a.value
        nk = ak + 1
      end
    end
    refs[#refs + 1] = { name = name, alias = alias }
    return nk
  end

  local i = 1
  local from_depth -- depth of the FROM list we are inside, if any
  while i <= #tokens do
    local t = tokens[i]
    if
      t.type == "word"
      and (t.lower == "from" or t.lower == "join" or t.lower == "update" or t.lower == "into" or t.lower == "table")
    then
      if t.lower == "from" then
        from_depth = t.depth
      end
      i = table_ref(i + 1, t.lower)
    elseif from_depth and t.depth == from_depth and t.type == "punct" and t.value == "," then
      i = table_ref(i + 1, ",")
    elseif from_depth and t.depth == from_depth and t.type == "word" and FROM_END[t.lower] then
      from_depth = nil
      i = i + 1
    elseif from_depth and t.depth < from_depth then
      from_depth = nil
      i = i + 1
    else
      i = i + 1
    end
  end
  return refs
end

local KNOWN_OTHER = {
  set = true,
  reset = true,
  show = true,
  vacuum = true,
  analyze = true,
  listen = true,
  notify = true,
  lock = true,
  execute = true,
  deallocate = true,
  discard = true,
  checkpoint = true,
  declare = true,
  fetch = true,
  close = true,
  move = true,
  ["do"] = true,
  call = true,
  load = true,
  unlisten = true,
}

---Does the statement start like SQL (and not like prose)?
---@param stmt dbgrid.Statement
function M.looks_like_sql(stmt)
  if stmt.class ~= "other" then
    return true
  end
  return KNOWN_OTHER[stmt.kind] == true
end

---Strip a trailing semicolon and whitespace.
---@param s string
function M.strip_semicolon(s)
  return (s:gsub("%s*;%s*$", ""))
end

---Qualified name (`schema.table`, quoted parts kept as written) starting at token k, or nil.
---@param tokens dbgrid.Token[]
---@param k integer
---@return string? name, integer next
local function qualified_name(tokens, k)
  local t = tokens[k]
  if not t or (t.type ~= "word" and t.type ~= "ident") or (t.type == "word" and CLAUSE_WORDS[t.lower]) then
    return nil, k
  end
  local parts = { t.value }
  local j = k + 1
  while tokens[j] and tokens[j].type == "punct" and tokens[j].value == "." do
    local nxt = tokens[j + 1]
    if nxt and (nxt.type == "word" or nxt.type == "ident") then
      parts[#parts + 1] = nxt.value
      j = j + 2
    else
      break
    end
  end
  return table.concat(parts, "."), j
end

---@param s string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Byte ranges of `:name` parameter references, in order of appearance. A
---reference is a colon directly followed by an identifier; `::` casts, array
---slices (`a[1:3]`, `a[i:j]`) and anything inside strings, comments or quoted
---identifiers do not count. The colon may share an op token with what comes
---before it (`a=:a`, `b>:b`).
---@param text string
---@return { name: string, s: integer, e: integer }[]
local function param_refs(text)
  local tokens = M.tokenize(text)
  local refs = {}
  for i, t in ipairs(tokens) do
    local nxt = tokens[i + 1]
    if
      t.type == "op"
      and t.value:sub(-1) == ":"
      and t.value:sub(-2) ~= "::"
      and nxt
      and nxt.type == "word"
      and nxt.s == t.e + 1
    then
      -- the colon of a slice directly follows an identifier or a closing bracket
      local before = t.e > 1 and text:sub(t.e - 1, t.e - 1) or ""
      if not before:match("[%w_%]%)]") then
        refs[#refs + 1] = { name = nxt.value, s = t.e, e = nxt.e }
      end
    end
  end
  return refs
end

---Named parameters (`:name`) in the text, unique and in first-occurrence order.
---@param text string
---@return string[]
function M.params(text)
  local out, seen = {}, {}
  for _, r in ipairs(param_refs(text)) do
    if not seen[r.name] then
      seen[r.name] = true
      out[#out + 1] = r.name
    end
  end
  return out
end

---Replace `:name` references (colon included) with `values[name]` verbatim,
---without quoting. Names without a value stay in place and come back in
---`missing`, unique and ordered.
---@param text string
---@param values table<string, any>
---@return string new_text, string[] missing
function M.substitute_params(text, values)
  values = values or {}
  local refs = param_refs(text)
  local missing, seen = {}, {}
  for _, r in ipairs(refs) do
    if values[r.name] == nil and not seen[r.name] then
      seen[r.name] = true
      missing[#missing + 1] = r.name
    end
  end
  local out = text
  -- right to left so earlier byte offsets stay valid
  for i = #refs, 1, -1 do
    local r = refs[i]
    local v = values[r.name]
    if v ~= nil then
      if type(v) == "userdata" then
        v = "NULL" -- vim.NIL
      end
      out = out:sub(1, r.s - 1) .. tostring(v) .. out:sub(r.e + 1)
    end
  end
  return out, missing
end

---Index of the first top-level word token from `words` at or after `from`, or nil.
---@param stmt dbgrid.Statement
---@param words table<string, boolean>
---@param from? integer
---@return integer?
local function top_level_index(stmt, words, from)
  for i = from or 1, #stmt.tokens do
    local t = stmt.tokens[i]
    if t.depth == 0 and t.type == "word" and words[t.lower] then
      return i
    end
  end
end

---`SELECT count(*) ...` over the rows an UPDATE / DELETE with a WHERE clause
---would touch, or nil when the statement is not one (or too unusual to be sure).
---@param stmt dbgrid.Statement
---@return string?
function M.preview_count(stmt)
  if stmt.kind ~= "update" and stmt.kind ~= "delete" then
    return nil
  end
  local tokens = stmt.tokens
  local where_idx = top_level_index(stmt, { where = true })
  if not where_idx then
    return nil
  end
  local where = tokens[where_idx]
  local after = tokens[where_idx + 1]
  -- WHERE CURRENT OF cursor cannot be counted
  if not after or (after.type == "word" and after.lower == "current") then
    return nil
  end
  local target = M.referenced_tables(stmt.sql)[1]
  if not target then
    return nil
  end
  local from = target.name .. (target.alias and (" " .. target.alias) or "")
  -- DELETE ... USING <list> / UPDATE ... FROM <list>: the list joins the count
  local extra = ""
  local list_word = stmt.kind == "delete" and "using" or "from"
  local list_idx
  for i = 2, where_idx - 1 do
    local t = tokens[i]
    if t.depth == 0 and t.type == "word" and t.lower == list_word then
      list_idx = i
    end
  end
  if list_idx then
    local first = tokens[list_idx + 1]
    if not first or first == where then
      return nil
    end
    extra = ", " .. trim(stmt.sql:sub(first.s - stmt.s + 1, where.s - stmt.s))
  end
  -- WHERE ... up to the end of the statement, minus a trailing RETURNING clause
  local end_rel = tokens[#tokens].e - stmt.s + 1
  local returning_idx = top_level_index(stmt, { returning = true }, where_idx + 1)
  if returning_idx then
    end_rel = tokens[returning_idx].s - stmt.s
  end
  local where_text = trim(stmt.sql:sub(where.s - stmt.s + 1, end_rel))
  return string.format("SELECT count(*) FROM %s%s %s", from, extra, where_text)
end

local RETURNING_KINDS = { insert = true, update = true, delete = true, merge = true }

---Append `RETURNING *` to a write statement that has no RETURNING clause.
---@param stmt dbgrid.Statement
---@return string sql, boolean applied
function M.ensure_returning(stmt)
  if stmt.class ~= "write" or not RETURNING_KINDS[stmt.kind] then
    return stmt.sql, false
  end
  if M.first_top_level_word(stmt, { returning = true }) then
    return stmt.sql, false
  end
  return stmt.sql .. "\nRETURNING *", true
end

---@class dbgrid.DdlWarningOpts
---@field table_rows? fun(name: string): integer|nil   row count from the schema cache, nil when unknown
---@field min_rows? integer   tables below this size get no index-build warning (default 10000)
---@field lock_timeout? boolean   false when the connection sets no lock_timeout

local TABLE_PREFIX = { only = true, ["if"] = true, ["not"] = true, exists = true, table = true }
local ADD_CONSTRAINT = {
  constraint = true,
  foreign = true,
  check = true,
  primary = true,
  unique = true,
  exclude = true,
}

---Plain-sentence warnings about the locks and rewrites a DDL statement implies
---(also VACUUM FULL, CLUSTER and REINDEX). Empty for anything else.
---@param stmt dbgrid.Statement
---@param opts? dbgrid.DdlWarningOpts
---@return string[]
function M.ddl_warnings(stmt, opts)
  opts = opts or {}
  local min_rows = opts.min_rows or 10000
  local kind = stmt.kind
  local out = {}
  if stmt.class ~= "ddl" and kind ~= "vacuum" and kind ~= "cluster" and kind ~= "reindex" then
    return out
  end
  local tokens = stmt.tokens

  local function add(msg)
    out[#out + 1] = msg
  end
  local function word_at(k)
    local t = tokens[k]
    return t and t.type == "word" and t.lower or nil
  end
  local function skip(k, words)
    while tokens[k] and tokens[k].type == "word" and words[tokens[k].lower] do
      k = k + 1
    end
    return k
  end
  local function is_paren(k, value)
    return tokens[k] ~= nil and tokens[k].type == "punct" and tokens[k].value == value
  end
  ---" (~N rows)" for a table, plus whether it is known to be small.
  local function rows_note(tbl)
    local rows = tbl and opts.table_rows and opts.table_rows(tbl) or nil
    if rows and rows < min_rows then
      return "", true
    end
    return rows and (" (~" .. require("dbgrid.util").fmt_int(rows) .. " rows)") or "", false
  end
  local waits = false -- does the statement wait for a lock on an existing relation?

  local object = word_at(skip(2, { ["or"] = true, replace = true, unique = true }))
  if kind == "create" and object == "index" then
    waits = true
    local on = top_level_index(stmt, { on = true })
    local tbl = on and qualified_name(tokens, skip(on + 1, { only = true })) or nil
    if tbl and not M.first_top_level_word(stmt, { concurrently = true }) then
      local note, small = rows_note(tbl)
      if not small then
        add(
          string.format(
            "CREATE INDEX without CONCURRENTLY locks writes on %s%s for the whole build; use CREATE INDEX CONCURRENTLY",
            tbl,
            note
          )
        )
      end
    end
  elseif kind == "create" and object == "trigger" then
    waits = true
  elseif kind == "drop" then
    waits = true
    if word_at(2) == "index" then
      local name = qualified_name(tokens, skip(3, { concurrently = true, ["if"] = true, exists = true }))
      if word_at(3) ~= "concurrently" then
        add(
          string.format(
            "DROP INDEX without CONCURRENTLY takes an ACCESS EXCLUSIVE lock on the table of %s; "
              .. "use DROP INDEX CONCURRENTLY",
            name or "the index"
          )
        )
      end
    end
  elseif kind == "alter" then
    waits = true
    if word_at(2) == "table" then
      local k = skip(3, TABLE_PREFIX)
      local tbl = qualified_name(tokens, k) or "the table"
      add(
        string.format(
          "ALTER TABLE takes an ACCESS EXCLUSIVE lock on %s; every query on it waits behind this statement",
          tbl
        )
      )
      local seen = {}
      local function once(msg)
        if not seen[msg] then
          seen[msg] = true
          add(msg)
        end
      end
      local i = k
      while i <= #tokens do
        local t = tokens[i]
        local w = t.depth == 0 and t.type == "word" and t.lower or nil
        if w == "type" then
          once("changing a column type rewrites the whole table")
        elseif w == "set" and word_at(i + 1) == "not" and word_at(i + 2) == "null" then
          once("SET NOT NULL scans the whole table unless a matching CHECK constraint exists")
        elseif w == "add" then
          -- one ADD action runs up to the next top-level comma
          local is_constraint = ADD_CONSTRAINT[word_at(i + 1) or ""] == true
          local needs_validate, not_valid, volatile = false, false, false
          local j = i + 1
          while tokens[j] and not (tokens[j].depth == 0 and tokens[j].type == "punct" and tokens[j].value == ",") do
            local wj = tokens[j].depth == 0 and tokens[j].type == "word" and tokens[j].lower or nil
            if is_constraint and (wj == "foreign" or wj == "check") then
              needs_validate = true
            elseif wj == "not" and word_at(j + 1) == "valid" then
              not_valid = true
            elseif not is_constraint and wj == "default" then
              local d = tokens[j + 1]
              if d and d.type == "word" and is_paren(j + 2, "(") then
                volatile = true
              end
            end
            j = j + 1
          end
          if needs_validate and not not_valid then
            once("validate the constraint separately: ADD CONSTRAINT ... NOT VALID, then VALIDATE CONSTRAINT")
          end
          if volatile then
            once("a volatile default rewrites the table; add the column first, then backfill")
          end
          i = j - 1
        end
        i = i + 1
      end
    end
  elseif kind == "truncate" then
    waits = true
    local tbl = qualified_name(tokens, skip(2, TABLE_PREFIX))
    add(string.format("TRUNCATE takes an ACCESS EXCLUSIVE lock on %s and cannot be undone", tbl or "the table"))
  elseif kind == "vacuum" then
    local full = word_at(2) == "full"
    local k
    if is_paren(2, "(") then
      -- option list: VACUUM (FULL, ANALYZE) t
      k = 3
      while tokens[k] and not is_paren(k, ")") do
        if tokens[k].type == "word" and tokens[k].lower == "full" then
          local v = tokens[k + 1]
          full = not (v and (v.lower == "false" or v.lower == "off" or v.value == "0"))
        end
        k = k + 1
      end
      k = k + 1
    else
      k = skip(2, { full = true, freeze = true, verbose = true, analyze = true })
    end
    if full then
      local tbl = qualified_name(tokens, k)
      add(
        tbl and string.format("VACUUM FULL rewrites %s and locks the table for the whole run", tbl)
          or "VACUUM FULL rewrites every table and locks each one for the whole run"
      )
    end
  elseif kind == "cluster" then
    waits = true
    local tbl = qualified_name(tokens, skip(2, { verbose = true }))
    add(
      tbl and string.format("CLUSTER rewrites %s and locks the table for the whole run", tbl)
        or "CLUSTER rewrites every clustered table and locks each one for the whole run"
    )
  elseif kind == "reindex" then
    waits = true
    local k = 2
    if is_paren(2, "(") then
      while tokens[k] and not is_paren(k, ")") do
        k = k + 1
      end
      k = k + 1
    end
    local what = word_at(k) or "index"
    local concurrently = word_at(k + 1) == "concurrently"
    local name = qualified_name(tokens, skip(k + 1, { concurrently = true }))
    if not concurrently then
      add(
        string.format(
          "REINDEX without CONCURRENTLY locks %s %s for the whole run; use REINDEX %s CONCURRENTLY",
          what,
          name or "",
          what:upper()
        )
      )
    end
  end
  if opts.lock_timeout == false and stmt.class == "ddl" and waits then
    add(
      "no lock_timeout is set on this connection; if this DDL waits for a lock, everything behind it waits too "
        .. "(set lock_timeout_ms on the connection)"
    )
  end
  return out
end

return M
