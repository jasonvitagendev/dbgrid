-- Report over the recordings of a notebook (`:Dbgrid recordings report`):
-- what `-- @record` cells wrote, summarised as markdown. Per recording the
-- minimum, average, maximum and last value of every numeric column with a
-- sparkline of the run; when marks were set (`:Dbgrid mark`), the same
-- averages per phase between them; alerts and marks as a timeline on top.
local record = require("dbgrid.record")

local M = {}

local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

---Series shown per recording; the ones with the fewest rows are left out.
M.MAX_SERIES = 8

---@param ts string  2026-11-10T09:15:05
---@return integer? epoch
local function epoch(ts)
  local y, mo, d, h, mi, s = ts:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
end

---@param secs number
---@return string
local function duration(secs)
  secs = math.floor(secs + 0.5)
  if secs < 60 then
    return secs .. "s"
  elseif secs < 3600 then
    return string.format("%dm %02ds", math.floor(secs / 60), secs % 60)
  end
  return string.format("%dh %02dm", math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end

---@param n number
---@return string
function M.fmt(n)
  local text
  if n == math.floor(n) then
    text = string.format("%d", n)
  elseif math.abs(n) >= 100 then
    text = string.format("%.1f", n)
  else
    text = string.format("%.2f", n)
  end
  local sign, int, frac = text:match("^(%-?)(%d+)(.*)$")
  if #int > 4 then
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  end
  return sign .. int .. frac
end

---Text sparkline of a series, averaged down to `width` buckets.
---@param values number[]
---@param width? integer
---@return string
function M.spark(values, width)
  width = width or 40
  if #values == 0 then
    return ""
  end
  local buckets = {}
  if #values <= width then
    buckets = values
  else
    for b = 1, width do
      local from = math.floor((b - 1) * #values / width) + 1
      local to = math.max(from, math.floor(b * #values / width))
      local sum = 0
      for i = from, to do
        sum = sum + values[i]
      end
      buckets[b] = sum / (to - from + 1)
    end
  end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(buckets) do
    lo, hi = math.min(lo, v), math.max(hi, v)
  end
  local out = {}
  for i, v in ipairs(buckets) do
    out[i] = hi == lo and BARS[1] or BARS[math.max(1, math.min(8, math.floor((v - lo) / (hi - lo) * 7 + 1.5)))]
  end
  return table.concat(out)
end

---@param v string?
---@return string
local function cell(v)
  return ((v or ""):gsub("|", "\\|"):gsub("\r?\n", " "))
end

---@param values number[]
---@return table? stats  { n, min, max, avg, last }
local function stats(values)
  if #values == 0 then
    return nil
  end
  local lo, hi, sum = math.huge, -math.huge, 0
  for _, v in ipairs(values) do
    lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
  end
  return { n = #values, min = lo, max = hi, avg = sum / #values, last = values[#values] }
end

---Split a recording into its series and classify the columns.
---@param data { columns: string[], rows: string[][] }
---@return table analysis
function M.analyze(data)
  local columns = data.columns
  local per_ts, order = {}, {}
  for _, r in ipairs(data.rows) do
    local ts = r[1]
    if ts and ts ~= "" then
      if not per_ts[ts] then
        per_ts[ts] = 0
        order[#order + 1] = ts
      end
      if #r > 1 then
        per_ts[ts] = per_ts[ts] + 1
      end
    end
  end
  local keyed = false
  for _, n in pairs(per_ts) do
    if n > 1 then
      keyed = true
      break
    end
  end
  -- a run with several rows is several series, told apart by the first column after the time
  local key_col = keyed and #columns >= 2 and 2 or nil
  local series, names = {}, {}
  for _, r in ipairs(data.rows) do
    if r[1] and r[1] ~= "" and #r > 1 then
      local key = key_col and (r[key_col] or "") or ""
      if not series[key] then
        series[key] = {}
        names[#names + 1] = key
      end
      table.insert(series[key], r)
    end
  end
  table.sort(names, function(a, b)
    if #series[a] ~= #series[b] then
      return #series[a] > #series[b]
    end
    return a < b
  end)
  -- numeric: every value present is a number, in every series
  local numeric = {}
  for c = 2, #columns do
    if c ~= key_col then
      local any, all = false, true
      for _, r in ipairs(data.rows) do
        local v = r[c]
        if v ~= nil and v ~= "" then
          any = true
          if not tonumber(v) then
            all = false
            break
          end
        end
      end
      numeric[c] = any and all
    end
  end
  local gaps = {}
  for i = 2, #order do
    local a, b = epoch(order[i - 1]), epoch(order[i])
    if a and b then
      gaps[#gaps + 1] = b - a
    end
  end
  table.sort(gaps)
  return {
    columns = columns,
    key_col = key_col,
    series = series,
    names = names,
    numeric = numeric,
    runs = #order,
    first = order[1],
    last = order[#order],
    interval = gaps[math.floor(#gaps / 2) + 1],
  }
end

---Numeric values of a column within a series, optionally between two times.
---@param rows string[][]
---@param c integer
---@param from? string
---@param to? string   exclusive
---@return number[]
local function column_values(rows, c, from, to)
  local out = {}
  for _, r in ipairs(rows) do
    local v = tonumber(r[c])
    if v and (not from or r[1] >= from) and (not to or r[1] < to) then
      out[#out + 1] = v
    end
  end
  return out
end

---@param out string[]
---@param a table        analysis
---@param rows string[][]
---@param phases { name: string, from?: string, to?: string }[]
local function series_lines(out, a, rows, phases)
  local shown = false
  for c = 2, #a.columns do
    if a.numeric[c] then
      local values = column_values(rows, c)
      local st = stats(values)
      if st then
        if not shown then
          out[#out + 1] = "| column | min | avg | max | last | trend |"
          out[#out + 1] = "|---|---:|---:|---:|---:|---|"
          shown = true
        end
        out[#out + 1] = string.format(
          "| %s | %s | %s | %s | %s | %s |",
          cell(a.columns[c]),
          M.fmt(st.min),
          M.fmt(st.avg),
          M.fmt(st.max),
          M.fmt(st.last),
          M.spark(values)
        )
      end
    end
  end
  if shown then
    out[#out + 1] = ""
  end
  -- text columns that take few values are states: say how often each was seen
  local states = {}
  for c = 2, #a.columns do
    if c ~= a.key_col and a.numeric[c] == false then
      local counts, seen = {}, {}
      for _, r in ipairs(rows) do
        local v = r[c]
        if v ~= nil and v ~= "" then
          if not counts[v] then
            counts[v] = 0
            seen[#seen + 1] = v
          end
          counts[v] = counts[v] + 1
        end
      end
      if #seen > 0 and #seen <= 6 then
        local parts = {}
        for _, v in ipairs(seen) do
          parts[#parts + 1] = cell(v) .. " ×" .. counts[v]
        end
        states[#states + 1] = "`" .. a.columns[c] .. "` " .. table.concat(parts, ", ")
      end
    end
  end
  if #states > 0 then
    out[#out + 1] = "States: " .. table.concat(states, " · ")
    out[#out + 1] = ""
  end
  if #phases > 1 and shown then
    local used = {}
    for _, p in ipairs(phases) do
      for _, r in ipairs(rows) do
        if (not p.from or r[1] >= p.from) and (not p.to or r[1] < p.to) then
          used[#used + 1] = p
          break
        end
      end
    end
    if #used > 1 then
      local head, rule = { "| column |" }, { "|---|" }
      for _, p in ipairs(used) do
        head[#head + 1] = " " .. cell(p.name) .. " |"
        rule[#rule + 1] = "---:|"
      end
      out[#out + 1] = "By phase, average (maximum):"
      out[#out + 1] = ""
      out[#out + 1] = table.concat(head)
      out[#out + 1] = table.concat(rule)
      for c = 2, #a.columns do
        if a.numeric[c] then
          local line = { "| " .. cell(a.columns[c]) .. " |" }
          for _, p in ipairs(used) do
            local st = stats(column_values(rows, c, p.from, p.to))
            line[#line + 1] = " " .. (st and (M.fmt(st.avg) .. " (" .. M.fmt(st.max) .. ")") or "") .. " |"
          end
          out[#out + 1] = table.concat(line)
        end
      end
      out[#out + 1] = ""
    end
  end
end

---The report as markdown, nil when the notebook has no recordings.
---@param nb dbgrid.Notebook
---@return string?
function M.markdown(nb)
  local recs = record.list(nb)
  if #recs == 0 then
    return nil
  end
  table.sort(recs, function(a, b)
    return a.name < b.name
  end)
  local marks = record.marks(nb)
  local phases = { { name = "start" } }
  local n_marks, n_alerts = 0, 0
  for _, m in ipairs(marks) do
    if m.kind == "mark" then
      n_marks = n_marks + 1
      phases[#phases].to = m.ts
      phases[#phases + 1] = { name = m.text, from = m.ts }
    else
      n_alerts = n_alerts + 1
    end
  end
  local analyses, first, last = {}, nil, nil
  for _, rec in ipairs(recs) do
    local data = record.read(rec.path)
    if data and data.columns and #data.rows > 0 then
      local a = M.analyze(data)
      a.name = rec.name
      analyses[#analyses + 1] = a
      if a.first and (not first or a.first < first) then
        first = a.first
      end
      if a.last and (not last or a.last > last) then
        last = a.last
      end
    end
  end
  local same_day = first and last and first:sub(1, 10) == last:sub(1, 10)
  local function when(ts)
    return same_day and ts:sub(12) or (ts:gsub("T", " "))
  end
  local out = { "# Recordings · " .. ((nb.meta and nb.meta.title) or nb.name), "" }
  local summary = {}
  if first and last then
    local a, b = epoch(first), epoch(last)
    summary[#summary + 1] = first:gsub("T", " ")
      .. " → "
      .. when(last)
      .. (a and b and (" (" .. duration(b - a) .. ")") or "")
  end
  summary[#summary + 1] = #analyses .. " recording" .. (#analyses == 1 and "" or "s")
  if n_marks > 0 then
    summary[#summary + 1] = n_marks .. " mark" .. (n_marks == 1 and "" or "s")
  end
  if n_alerts > 0 then
    summary[#summary + 1] = n_alerts .. " alert event" .. (n_alerts == 1 and "" or "s")
  end
  out[#out + 1] = table.concat(summary, " · ")
  out[#out + 1] = ""
  if #marks > 0 then
    out[#out + 1] = "## Timeline"
    out[#out + 1] = ""
    out[#out + 1] = "| time | | event |"
    out[#out + 1] = "|---|---|---|"
    for _, m in ipairs(marks) do
      out[#out + 1] = string.format("| %s | %s | %s |", when(m.ts), cell(m.kind), cell(m.text))
    end
    out[#out + 1] = ""
  end
  for _, a in ipairs(analyses) do
    out[#out + 1] = "## " .. a.name
    out[#out + 1] = ""
    local line = { a.runs .. " run" .. (a.runs == 1 and "" or "s") }
    if a.first then
      line[#line + 1] = when(a.first) .. " → " .. when(a.last)
    end
    if a.interval and a.interval > 0 then
      line[#line + 1] = "every ~" .. duration(a.interval)
    end
    out[#out + 1] = table.concat(line, " · ")
    out[#out + 1] = ""
    if #a.names == 0 then
      out[#out + 1] = "No rows in any run."
      out[#out + 1] = ""
    end
    for i, key in ipairs(a.names) do
      if i > M.MAX_SERIES then
        out[#out + 1] = string.format(
          "%d more `%s` values with fewer rows are left out.",
          #a.names - M.MAX_SERIES,
          a.columns[a.key_col]
        )
        out[#out + 1] = ""
        break
      end
      if a.key_col then
        out[#out + 1] = string.format("### %s = %s (%d rows)", a.columns[a.key_col], cell(key), #a.series[key])
        out[#out + 1] = ""
      end
      series_lines(out, a, a.series[key], phases)
    end
  end
  return table.concat(out, "\n") .. "\n"
end

return M
